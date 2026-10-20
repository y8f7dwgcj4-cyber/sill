import AppKit
import Observation
import Security
import SillHostCore
import StreamProtocol

/// Owns the host for the app: the settings, the coordinator, remote access and the small models
/// the menu and the windows bind to. Works out what the status item says (`presentation`)
/// whenever any of it changes, and holds the App Nap and sleep guard. Main actor.
@MainActor @Observable
final class AppModel {
    let settings: HostSettings
    let permissions: PermissionsModel
    let loginItem = LoginItemModel()
    /// `--synthetic`: the Desktop streams a test pattern, exactly as with the CLI's flag. No onboarding in this mode.
    let synthetic = CommandLine.arguments.contains("--synthetic")
    private(set) var coordinator: StreamCoordinator?
    /// The coordinator could not be created (the listener refused its parameters). Shown in the
    /// menu; the app keeps running so the user can read it and quit.
    private(set) var startupError: String?
    /// What the status item, its card and the menu show.
    private(set) var presentation: StatusPresentation
    /// The Settings tab on screen, nil while Settings is closed: the panes that poll run only
    /// while theirs is visible.
    var visibleSettingsTab: SettingsTab?
    /// Sill.app itself, not the bare SillMenuBar binary: an app bundle's executable, which runs with
    /// Sill's Screen Recording and Accessibility grants. It honours no TEST ONLY variable or `-Sill…After`
    /// hook that bears on who gets in or what pairing needs (docs/home-pairing-plan.md §4.3, §6.6):
    /// any process of this user can start it with an environment and arguments.
    nonisolated static let bundled = Bundle.main.bundleURL.pathExtension == "app"

    /// Wired by the app delegate: the status item's glyph and tooltip, and the windows.
    @ObservationIgnored var onPresentation: ((StatusPresentation) -> Void)?
    @ObservationIgnored var showSettings: ((SettingsTab?) -> Void)?
    @ObservationIgnored var showLog: (() -> Void)?
    /// Shows the pairing window with this offer (or brings it forward with the same code).
    @ObservationIgnored var showPairing: ((RemoteAccess.PairingOffer) -> Void)?
    /// The pairing window, if it shows a code, brought forward and key; false when it shows none.
    @ObservationIgnored var bringPairingForward: (() -> Bool)?
    /// Closes the pairing window as its Cancel does; false when it was not on screen.
    @ObservationIgnored var closePairingWindow: (() -> Bool)?
    /// TEST ONLY (-SillSettingsAfter): the Settings window's controller, once it has been made.
    @ObservationIgnored var settingsWindowForTests: (() -> SettingsWindowController?)?

    @ObservationIgnored private var loggedStatus: String?
    @ObservationIgnored private var napActivity: NSObjectProtocol?
    @ObservationIgnored private var napHold = NapHold.none

    init() {
        let settings = HostSettings()
        self.settings = settings
        permissions = PermissionsModel(settings: settings)
        presentation = StatusText.present(snapshot: HostStatusSnapshot(),
                                          permissions: PermissionState(screenRecording: true, accessibility: true),
                                          startupError: nil, hasCoordinator: false)
    }

    static var version: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev" }
    static var build: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unbundled" }

    /// Starts the host: the same coordinator as the CLI, under the AppKit loop that is already
    /// running, asking for no permission at launch. Never exits on an error.
    func start() {
        observePresentation()
        Task { @MainActor in
            do {
                // The identity before the coordinator: the door speaks TLS with it. A keychain
                // failure leaves remote access unavailable, not the app.
                let remote = makeRemoteAccess()
                // The window lists carry this Sill's version, when it has one (the bare binary's
                // "dev" does not parse): later devices can tell which Mac to update.
                let c = try StreamCoordinator(config: settings.config, synthetic: synthetic, appKitLoop: true, remote: remote,
                                              testHooks: !Self.bundled,
                                              hostVersion: SillVersion(Self.version) != nil ? Self.version : nil)
                coordinator = c
                // One path from the controls to the host, synchronous: the host's target equals
                // settings.config at every main-actor turn, so a device's change and a menu click
                // never undo each other.
                settings.onChange = { [settings, weak c] in c?.setTarget(settings.config) }
                // A device's change goes through HostSettings like a menu click: saved (only the keys
                // it changed) and shown live in Settings and the menu. Laid over settings.config, never
                // over the host's value: over the away quality for a device away from home, which
                // never changes the home one (docs/remote-bundle-plan.md §5). No validated(): the host
                // accepted only menu values, and validating here would rewrite unrelated hand-set
                // keys (which save(changedFrom:) would then write).
                c.onDeviceSettingsChange = { [settings] change, away in
                    settings.config = away ? settings.config.applyingAway(change) : settings.config.applying(change)
                    return settings.config
                }
                await c.start(preselect: nil, promptForPermissions: false)
                Stats.shared.startPrinting()
                print("Sill \(Self.version) (\(Self.build)) running from \(Bundle.main.bundlePath); log file \(HostLog.shared.fileURL?.path ?? "none")")
                onboardIfNeeded()
            } catch {
                startupError = "\(error)"
                print("Sill couldn’t start: \(error)")
            }
        }
    }

    // MARK: Pairing and remote access

    /// The Mac's identity and trust list: a keychain in Sill.app,
    /// picked by IdentityStorePlan (docs/keychain-plan.md). An entitled Developer ID build (a
    /// provisioning profile embedded, so it holds a `keychain-access-groups` entitlement) uses the
    /// data-protection keychain, which no other process can pre-create or read; any other real
    /// Sill.app — a development build, or a release with no profile — uses the legacy login keychain.
    /// A test never touches a keychain: `--synthetic` keeps them in memory, and so does the bare
    /// SillMenuBar binary, whose ad hoc signature changes with every build. TEST ONLY: the bare
    /// binary with `--synthetic` (a test host) keeps them in SILL_TEST_REMOTE_DIR (a 0700 directory)
    /// instead; a real Sill.app ignores it with a line (a caller could hand it a trust list of its
    /// own).
    private func makeRemoteAccess() -> RemoteAccess {
        let store = makeIdentityStore()
        let remote = RemoteAccess(store: store)
        if let problem = remote.identityProblem { print("Remote access unavailable: \(problem)") }
        remote.restoreSeen(settings.remoteDevicesSeen())
        remote.onSeen = { [weak self, weak remote] prefix, at, route in
            let keep = Set(remote?.pairedPrefixes ?? [])
            self?.settings.rememberRemoteDevice(prefix, at: at, route: route, keep: keep)
        }
        remote.onPairingOffer = { [weak self] offer in self?.pairingOffered(offer) }
        return remote
    }

    /// The identity store IdentityStorePlan names for this launch (docs/keychain-plan.md), and one
    /// log line saying which keychain the identity is in and why. SILL_TEST_REMOTE_DIR is honoured
    /// only for a test host and otherwise ignored with a line, as before.
    private func makeIdentityStore() -> IdentityStore {
        let dir = ProcessInfo.processInfo.environment["SILL_TEST_REMOTE_DIR"].flatMap { $0.isEmpty ? nil : $0 }
        let choice = IdentityStorePlan.choose(bundled: Self.bundled, synthetic: synthetic,
                                              entitledAccessGroup: Self.entitledKeychainAccessGroup(), testRemoteDir: dir)
        if dir != nil, case .testDirectory = choice {} else if dir != nil {
            print("SILL_TEST_REMOTE_DIR ignored: only a test host takes it (one that does not advertise and is not Sill.app itself).")
        }
        switch choice {
        case .dataProtection(let group):
            // The strong keychain: no other process can pre-create or read these items. Logged so a
            // release build can be confirmed hardened (and Noah's on-device pass can read it back).
            print("Remote access: the identity is in the data-protection keychain (access group \(group)).")
            return KeychainIdentityStore(accessGroup: group)
        case .legacy:
            // No keychain-access-groups entitlement (a development build, or a release with no
            // embedded provisioning profile): the login keychain, the profile-free fallback. Said in
            // the log so a build that should have hardened but did not is visible.
            print("Remote access: the identity is in the login keychain (no keychain-access-groups entitlement — a development build, or a release with no embedded provisioning profile; docs/keychain-plan.md).")
            return KeychainIdentityStore()
        case .memory:
            return MemoryIdentityStore()
        case .testDirectory(let path):
            do { return try FileIdentityStore(directory: URL(fileURLWithPath: path)) }
            catch { print("SILL_TEST_REMOTE_DIR=\(path) ignored: \(error)"); return MemoryIdentityStore() }
        }
    }

    /// The `keychain-access-groups` entitlement the running binary actually holds, from its own
    /// signature — the first group ending in the app's suffix, else the first. Nil for any build
    /// without an embedded provisioning profile (every development and ad hoc build reads its own
    /// entitlement as nil, measured 2026-09-27), which is exactly the signal to use the legacy store.
    /// This reads only this process's own entitlements; it authenticates nothing about other apps.
    private static func entitledKeychainAccessGroup() -> String? {
        guard let task = SecTaskCreateFromSelf(nil),
              let value = SecTaskCopyValueForEntitlement(task, "keychain-access-groups" as CFString, nil) else { return nil }
        if let groups = value as? [String], !groups.isEmpty {
            return groups.first { $0.hasSuffix(".me.saffer.sill.mac") } ?? groups.first
        }
        if let group = value as? String, !group.isEmpty { return group }
        return nil
    }

    /// The host's remote access, once the coordinator is up.
    var remote: RemoteAccess? { coordinator?.remote }

    /// Pair iPhone or iPad… (the menu, the panes): opens a pairing window, or brings the open one
    /// forward with its code.
    func pairDevice() {
        // A window up already comes forward at once; the offer made again follows.
        _ = bringPairingForward?()
        remote?.openPairing(requestedBy: nil)
    }

    /// The pairing window was closed, or its Cancel clicked: the code dies with it.
    func cancelPairing() {
        remote?.cancelPairing()
    }

    /// Remove in the pane. Nil when done; otherwise why the device is still
    /// paired (the keychain could not be written), and its "last connected" stays too.
    @discardableResult
    func removeDevice(_ id: String) -> String? {
        let prefix = coordinator?.status.snapshot.remote?.paired.first { $0.id == id }?.keyPrefix
        if let problem = remote?.remove(fingerprint: id) { return problem }
        if let prefix { settings.forgetRemoteDevice(prefix) }
        return nil
    }

    func renameDevice(_ id: String, to name: String) {
        remote?.rename(fingerprint: id, to: name)
    }

    /// The pairing window's Turn On Remote Access: the Mac user's click. A pairing never turns it
    /// on by itself.
    func turnOnRemoteAccess() {
        settings.config.remoteAccess = true
    }

    /// An offer from the host: the window shows it. TEST ONLY: with the file store (--synthetic
    /// and SILL_TEST_REMOTE_DIR) the link and the code are also left in its directory, mode 0600,
    /// for a test client to read. Never printed: the print shadow copies stdout into Sill.log.
    private func pairingOffered(_ offer: RemoteAccess.PairingOffer) {
        if let dir = remote?.testDirectory {
            try? FileIdentityStore.writePrivate(Data(offer.url.utf8), to: dir.appendingPathComponent("pairing.url"))
            try? FileIdentityStore.writePrivate(Data(offer.code.utf8), to: dir.appendingPathComponent("pairing.code"))
        }
        showPairing?(offer)
    }

    // MARK: Status

    /// Recomputes the presentation now and again after anything it read changes: the host's
    /// snapshot, the coordinator appearing, the permissions, a startup error. Observation fires
    /// once, before the change lands, so each change hops to the next main-actor turn, re-reads
    /// the permissions (a revoked one shows with the status change it causes) and re-arms.
    private func observePresentation() {
        let next = withObservationTracking {
            currentPresentation()
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.permissions.refresh()
                self?.observePresentation()
            }
        }
        publish(next)
    }

    private func currentPresentation() -> StatusPresentation {
        StatusText.present(snapshot: coordinator?.status.snapshot ?? HostStatusSnapshot(),
                           permissions: PermissionState(screenRecording: permissions.screenRecording,
                                                        accessibility: permissions.accessibility),
                           startupError: startupError, hasCoordinator: coordinator != nil, now: Date())
    }

    private func publish(_ next: StatusPresentation) {
        if next != presentation || loggedStatus == nil {
            presentation = next
            onPresentation?(next)
        }
        // One line per change of header or explanation; tests grep for "Status:".
        let line = next.subtitle.map { "\(next.header) — \($0)" } ?? next.header
        if line != loggedStatus {
            loggedStatus = line
            print("Status: \(line)")
        }
        let snapshot = coordinator?.status.snapshot
        holdAppNapOff(devices: snapshot?.devices.count ?? 0, remote: snapshot?.remoteDeviceCount ?? 0)
    }

    private enum NapHold { case none, connected, remote }

    /// App Nap would coalesce this windowless app's timers once it is in the background, among
    /// them the 30 ms link keepalive ticks that keep a device's Wi-Fi out of power save, and the
    /// 2026-09-22 stutter would be back. So while a device is connected Sill holds a
    /// latency-critical activity, which still lets the Mac sleep when idle: a device at home can
    /// wake it (Bonjour Sleep Proxy) or walk over. A device connected from away cannot, so while
    /// one is, the activity is `.userInitiated`, which also keeps the Mac from idle sleep (the
    /// display may still sleep; docs/remote-access-plan.md §6.5). Switching ends one activity and
    /// begins the other.
    private func holdAppNapOff(devices: Int, remote: Int) {
        let want: NapHold = remote > 0 ? .remote : (devices > 0 ? .connected : .none)
        guard want != napHold else { return }
        if let activity = napActivity {
            ProcessInfo.processInfo.endActivity(activity)
            napActivity = nil
        }
        napHold = want
        switch want {
        case .remote:
            napActivity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .latencyCritical],
                                                                reason: "Sill is serving a device connected from away")
        case .connected:
            napActivity = ProcessInfo.processInfo.beginActivity(options: [.userInitiatedAllowingIdleSystemSleep, .latencyCritical],
                                                                reason: "Sill is serving a connected device")
        case .none:
            break
        }
    }

    /// First launch, or any launch until the user closes Settings on it: when a permission is
    /// missing, Settings opens on Permissions. The test pattern needs none.
    private func onboardIfNeeded() {
        permissions.refresh()
        guard !synthetic, !permissions.allGranted, !settings.permissionsOnboardingDismissed else { return }
        showSettings?(.permissions)
    }
}
