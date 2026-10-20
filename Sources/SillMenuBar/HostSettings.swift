import Foundation
import Observation
import SillHostCore

/// The app's settings: the host's knobs (`config`) and a few facts the UI remembers, all in
/// UserDefaults (the bundle's domain, me.saffer.sill.mac; the bare SillMenuBar binary's is
/// "SillMenuBar"). Main actor, like everything that shows or changes them.
///
/// One path to the host: the menu, the Settings panes and connected devices (through
/// the coordinator's `onDeviceSettingsChange`, which the model points here) all assign `config`.
/// Its didSet saves what changed and calls `onChange`, which the model points at
/// `StreamCoordinator.setTarget`, synchronously, so the host's target and `config` never disagree
/// between two main-actor turns. No sliders anywhere: one change is one apply and at most one
/// restart.
///
/// Defaults are registered from `HostConfig.standard`, so a fresh install streams exactly like the
/// CLI, and launch arguments override for one run without being saved (`-maxFPS 60`), because a
/// save writes only the keys a change touched. Launch at login is not stored here: SMAppService
/// is its source of truth (LoginItem.swift).
///
/// Remote Access and its port are the Mac's alone: they come from here (the menu, the Remote Access
/// pane), never from a device. The trust list and the keys never live here: any process of the same
/// user can write these defaults (KeychainIdentityStore).
///
/// Away from home (docs/remote-bundle-plan.md §5): the away quality is saved under its own keys,
/// `awayBitrate` and `awayCaptureScale`, never over `bitrate` and `captureScale`; a device away sets
/// it, and so does Settings › Streaming's "Away from home" section. Until the first change the keys do
/// not exist (`defaults read … awayBitrate` says so), which is how Low · Standard reads.
@MainActor @Observable
final class HostSettings {
    enum Key {
        static let maxFPS = "maxFPS", captureScale = "captureScale", bitrate = "bitrate"
        static let awayBitrate = "awayBitrate", awayCaptureScale = "awayCaptureScale"
        static let prioritizeSpeed = "prioritizeSpeed", virtualDisplay = "virtualDisplay"
        static let remoteAccess = "remoteAccess", remotePort = "remotePort"
        static let remoteDevicesSeen = "remoteDevicesSeen"
        static let settingsTab = "settingsTab", permissionsOnboardingDismissed = "permissionsOnboardingDismissed"
        static let askedScreenRecording = "askedScreenRecording", askedAccessibility = "askedAccessibility"
        static let logShowsStats = "logShowsStats"
        static let shareClipboard = "shareClipboard"
    }

    var config: HostConfig {
        didSet {
            guard config != oldValue else { return }
            save(changedFrom: oldValue)
            onChange?()
        }
    }
    /// Called after `config` changed and was saved, on the main actor, before the assignment returns.
    @ObservationIgnored var onChange: (@MainActor () -> Void)?

    /// The Settings tab shown last, reopened next time.
    var settingsTab: SettingsTab { didSet { defaults.set(settingsTab.rawValue, forKey: Key.settingsTab) } }
    /// The user closed the onboarding Settings window while a permission was still missing: later
    /// launches (a login item, say) only mark the status item. Cleared once both are allowed.
    var permissionsOnboardingDismissed: Bool { didSet { defaults.set(permissionsOnboardingDismissed, forKey: Key.permissionsOnboardingDismissed) } }
    /// The system's permission alerts appear once per app; after that, Allow… opens System Settings.
    var askedScreenRecording: Bool { didSet { defaults.set(askedScreenRecording, forKey: Key.askedScreenRecording) } }
    var askedAccessibility: Bool { didSet { defaults.set(askedAccessibility, forKey: Key.askedAccessibility) } }
    /// The Log window shows the once-a-second stats and client lines.
    var logShowsStats: Bool { didSet { defaults.set(logShowsStats, forKey: Key.logShowsStats) } }
    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let standard = HostConfig.standard
        defaults.register(defaults: [
            Key.maxFPS: standard.maxFPS,
            Key.captureScale: Double(standard.captureScale),
            Key.bitrate: standard.bitrate,
            Key.awayBitrate: standard.awayBitrate,
            Key.awayCaptureScale: Double(standard.awayCaptureScale),
            Key.prioritizeSpeed: standard.prioritizeSpeed,
            Key.virtualDisplay: standard.virtualDisplay,
            // Off: only the Mac's own user widens exposure.
            Key.remoteAccess: standard.remoteAccess,
            Key.remotePort: standard.remotePort,
            // On, like the CLI: each device has its own switch, and a password manager's copies never go.
            Key.shareClipboard: standard.shareClipboard,
        ])
        config = HostConfig(maxFPS: defaults.integer(forKey: Key.maxFPS),
                            captureScale: CGFloat(defaults.double(forKey: Key.captureScale)),
                            bitrate: defaults.integer(forKey: Key.bitrate),
                            awayBitrate: defaults.integer(forKey: Key.awayBitrate),
                            awayCaptureScale: CGFloat(defaults.double(forKey: Key.awayCaptureScale)),
                            prioritizeSpeed: defaults.bool(forKey: Key.prioritizeSpeed),
                            virtualDisplay: defaults.bool(forKey: Key.virtualDisplay),
                            remoteAccess: defaults.bool(forKey: Key.remoteAccess),
                            remotePort: defaults.integer(forKey: Key.remotePort),
                            shareClipboard: defaults.bool(forKey: Key.shareClipboard)).validated()
        settingsTab = defaults.string(forKey: Key.settingsTab).flatMap(SettingsTab.init(rawValue:)) ?? .general
        permissionsOnboardingDismissed = defaults.bool(forKey: Key.permissionsOnboardingDismissed)
        askedScreenRecording = defaults.bool(forKey: Key.askedScreenRecording)
        askedAccessibility = defaults.bool(forKey: Key.askedAccessibility)
        logShowsStats = defaults.bool(forKey: Key.logShowsStats)
    }

    /// Writes only the keys that changed, so a launch-argument override of another key is not
    /// made permanent by an unrelated change.
    private func save(changedFrom old: HostConfig) {
        if config.maxFPS != old.maxFPS { defaults.set(config.maxFPS, forKey: Key.maxFPS) }
        if config.captureScale != old.captureScale { defaults.set(Double(config.captureScale), forKey: Key.captureScale) }
        if config.bitrate != old.bitrate { defaults.set(config.bitrate, forKey: Key.bitrate) }
        if config.awayBitrate != old.awayBitrate { defaults.set(config.awayBitrate, forKey: Key.awayBitrate) }
        if config.awayCaptureScale != old.awayCaptureScale { defaults.set(Double(config.awayCaptureScale), forKey: Key.awayCaptureScale) }
        if config.prioritizeSpeed != old.prioritizeSpeed { defaults.set(config.prioritizeSpeed, forKey: Key.prioritizeSpeed) }
        if config.virtualDisplay != old.virtualDisplay { defaults.set(config.virtualDisplay, forKey: Key.virtualDisplay) }
        if config.remoteAccess != old.remoteAccess { defaults.set(config.remoteAccess, forKey: Key.remoteAccess) }
        if config.remotePort != old.remotePort { defaults.set(config.remotePort, forKey: Key.remotePort) }
        if config.shareClipboard != old.shareClipboard { defaults.set(config.shareClipboard, forKey: Key.shareClipboard) }
    }

    // MARK: Remote devices seen (display only)

    /// When each paired device last connected from away and how, by its key prefix: the Remote
    /// Access pane's "last connected", kept across launches. Display only, never trust.
    func remoteDevicesSeen() -> [String: (at: Date, route: String)] {
        guard let raw = defaults.dictionary(forKey: Key.remoteDevicesSeen) else { return [:] }
        var out: [String: (at: Date, route: String)] = [:]
        for (prefix, value) in raw {
            guard let entry = value as? [String: Any], let at = entry["at"] as? Double, let route = entry["route"] as? String else { continue }
            out[prefix] = (Date(timeIntervalSince1970: at), route)
        }
        return out
    }

    /// Saves one device's record, at most once a minute per device (a device that reconnects every
    /// few seconds must not write defaults every few seconds), and keeps only `keep` (the paired
    /// devices' prefixes).
    func rememberRemoteDevice(_ prefix: String, at: Date, route: String, keep: Set<String>) {
        var raw = defaults.dictionary(forKey: Key.remoteDevicesSeen) ?? [:]
        if let entry = raw[prefix] as? [String: Any], let last = entry["at"] as? Double,
           at.timeIntervalSince1970 - last < 60, entry["route"] as? String == route { return }
        raw[prefix] = ["at": at.timeIntervalSince1970, "route": route]
        raw = raw.filter { keep.contains($0.key) }
        defaults.set(raw, forKey: Key.remoteDevicesSeen)
    }

    /// Drops the record of a device that was removed.
    func forgetRemoteDevice(_ prefix: String) {
        guard var raw = defaults.dictionary(forKey: Key.remoteDevicesSeen), raw[prefix] != nil else { return }
        raw[prefix] = nil
        defaults.set(raw, forKey: Key.remoteDevicesSeen)
    }
}
