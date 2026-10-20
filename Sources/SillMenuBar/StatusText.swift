import Foundation
import SillHostCore
import StreamProtocol

/// Everything the status item, its card and its menu say, as plain values. Made by
/// `StatusText.present` from the host's snapshot, so the same words appear in the menu, the
/// tooltip, the log's "Status:" lines and the previews.
struct StatusPresentation: Equatable {
    /// A line with a symbol: the stream's source, or one device.
    struct Row: Equatable, Identifiable {
        var id: String
        var symbol: String
        var title: String
        var detail: String?
    }

    /// Something that needs the user, shown in the menu with an orange warning.
    struct Attention: Equatable, Identifiable {
        enum Action: Equatable {
            case allowScreenRecording, allowAccessibility, showRemoteAccess, showDevices
            case none
        }
        var title: String
        var subtitle: String
        var action: Action
        var id: String { title }
    }

    var glyph: StatusGlyph.State
    var header: String
    var subtitle: String?
    var source: Row?
    var devices: [Row]
    var attention: [Attention]
    /// Under the menu's Virtual Display item.
    var virtualDisplayNote: String
    var tooltip: String
    var accessibilityLabel: String
    /// Under the menu's Remote Access… item: "Off", "On · Tailscale"… Nil on a host without
    /// remote access (no item then).
    var remoteAccessNote: String?
    /// Pair iPhone or iPad… can open a pairing window (the Mac has an identity).
    var canPair = false
    /// Every connected device is away from home, so the away quality is the target: the menu's
    /// Quality subtitle says so (docs/remote-bundle-plan.md §5.7).
    var away = false
}

/// Whether Sill holds its two permissions, as last read.
struct PermissionState: Equatable {
    var screenRecording: Bool
    var accessibility: Bool
}

/// The status copy. Title case in menus, sentence case in explanations, typographic quotes.
enum StatusText {
    /// `now`: kept for the previews' fixed clock; no item lasts a while on this host.
    static func present(snapshot s: HostStatusSnapshot, permissions: PermissionState,
                        startupError: String?, hasCoordinator: Bool, now: Date = Date()) -> StatusPresentation {
        let (header, subtitle) = headline(s, permissions, startupError, hasCoordinator)

        var attention: [StatusPresentation.Attention] = []
        if !permissions.screenRecording {
            attention.append(.init(title: "Allow Screen Recording…", subtitle: "Needed to show your windows on your devices.",
                                   action: .allowScreenRecording))
        }
        if !permissions.accessibility {
            attention.append(.init(title: "Allow Accessibility…", subtitle: "Devices can watch but not click or type.",
                                   action: .allowAccessibility))
        }
        // Kept to one line no wider than the rest of the menu: a menu item's subtitle does not wrap.
        if s.softwareEncoder, s.hardwareEncoderStuck {
            attention.append(.init(title: "Hardware Encoder Stuck",
                                   subtitle: "Streaming with the software encoder, up to 60 fps. Restarting the Mac fixes this.",
                                   action: .none))
        } else if s.softwareEncoder {
            attention.append(.init(title: "Hardware Encoder Busy",
                                   subtitle: "Streaming with the software encoder, up to 60 fps, until it is free again.",
                                   action: .none))
        }
        let remotePortTaken = remotePortInUse(s.remote)
        if let port = remotePortTaken {
            attention.append(.init(title: "Remote Access Can’t Start", subtitle: "Port \(port) is in use by another app.",
                                   action: .showRemoteAccess))
        }
        let doorClosed = s.remote?.identityProblem != nil
        if doorClosed {
            attention.append(.init(title: "Devices Can’t Connect", subtitle: "Sill couldn’t use its key in your keychain.",
                                   action: .showDevices))
        }

        // The attention glyph means "Sill needs you". The test pattern needs no permission. A
        // closed door needs the user too.
        let glyph: StatusGlyph.State
        if startupError != nil || listenerFailed(s.remote) || remotePortTaken != nil || doorClosed
            || (!s.synthetic && !(permissions.screenRecording && permissions.accessibility)) {
            glyph = .attention
        } else if s.stream != nil {
            glyph = .streaming
        } else if !s.devices.isEmpty {
            glyph = .connected
        } else {
            glyph = .idle
        }

        return StatusPresentation(glyph: glyph, header: header, subtitle: subtitle,
                                  source: sourceRow(s), devices: s.devices.map(deviceRow), attention: attention,
                                  virtualDisplayNote: virtualDisplayNote(s),
                                  tooltip: "Sill — \(header)", accessibilityLabel: "Sill, \(header)",
                                  remoteAccessNote: remoteAccessNote(s.remote),
                                  canPair: s.remote.map { $0.identityProblem == nil } ?? false, away: s.away)
    }

    /// The remote door's port while Remote Access is on and another app holds that port.
    private static func remotePortInUse(_ r: RemoteStatus?) -> Int? {
        guard let r, r.remoteAccess, r.identityProblem == nil, case .portInUse(let port) = r.listener else { return nil }
        return port
    }

    /// The Remote Access… item's subtitle: "Off", "On · Tailscale", "On · no VPN on this Mac",
    /// "Port 7455 is in use" or "Unavailable: the keychain couldn’t be used".
    static func remoteAccessNote(_ r: RemoteStatus?) -> String? {
        guard let r else { return nil }
        if r.identityProblem != nil { return "Unavailable: the keychain couldn’t be used" }
        guard r.remoteAccess else { return "Off" }
        switch r.listener {
        case .portInUse(let port): return "Port \(port) is in use"
        case .failed: return "Couldn’t start; trying again"
        case .notConfigured: return "Not set up: no Tailscale address"
        case .waitingForAddress: return "Waiting for Tailscale"
        case .off, .listening: break
        }
        var ways: [String] = []
        for a in r.addresses where a.kind == MacAddress.vpn && !ways.contains(a.via) { ways.append(a.via) }
        guard let last = ways.last else { return "On · no VPN on this Mac" }
        return "On · " + (ways.count == 1 ? last : ways.dropLast().joined(separator: ", ") + " and " + last)
    }

    /// The header and its explanation; the first match wins.
    private static func headline(_ s: HostStatusSnapshot, _ permissions: PermissionState, _ startupError: String?,
                                 _ hasCoordinator: Bool) -> (String, String?) {
        if let startupError { return ("Sill Couldn’t Start", startupError) }
        if !hasCoordinator { return ("Starting…", nil) }
        // No listener at all (fail closed): no device can reach this Mac.
        guard let r = s.remote else { return ("Not Listening", "This host has no door for devices.") }
        if r.identityProblem != nil {
            return ("Not Listening",
                    "Sill couldn’t use its key in your keychain. Quit Sill and open it again, and choose Always Allow if the keychain asks.")
        }
        switch r.listener {
        case .failed(let error):
            return ("Not Listening", "\(error). Sill tries again.")
        case .portInUse(let port):
            return ("Not Listening", "Port \(port) is in use by another app.")
        case .notConfigured(let why):
            return ("Not Listening", "Sill has no Tailscale address to listen on: \(why).")
        case .waitingForAddress(let address):
            return ("Waiting for Tailscale", "Sill listens on \(address) when Tailscale is up on this Mac.")
        case .off:
            if !r.remoteAccess { return ("Remote Access Is Off", "Turn it on in Settings › Remote Access so paired devices can connect.") }
            return ("Starting…", nil)
        case .listening(let port):
            if s.synthetic { return ("Test Pattern Mode", "Test clients connect to port \(port).") }
        }
        if !permissions.screenRecording {
            return ("Screen Recording Is Off", "Devices can connect but can’t see any windows.")
        }
        let count = s.devices.count
        if count > 0 {
            let who = count == 1 ? (s.devices[0].name.map(shortName) ?? "a Device") : "\(count) Devices"
            if s.stream != nil { return ("Streaming to \(who)", nil) }
            let connected = count == 1 ? (s.devices[0].name.map(shortName) ?? "Device") : "\(count) Devices"
            return ("\(connected) Connected", "Pick a window on the device to start streaming.")
        }
        return ("Waiting for a Device", "Open Sill on your iPhone or iPad and connect through Tailscale.")
    }

    /// The door's listener failed, while Remote Access is on.
    private static func listenerFailed(_ r: RemoteStatus?) -> Bool {
        guard let r, r.remoteAccess else { return false }
        switch r.listener {
        case .failed, .notConfigured: return true
        case .off, .listening, .portInUse, .waitingForAddress: return false
        }
    }

    /// "iPad" from "iPad (iPad14,1)".
    static func shortName(_ device: String) -> String {
        let name = device.components(separatedBy: " (").first ?? device
        return name.isEmpty ? device : name
    }

    /// What streams: "Safari — Apple Developer" over "3024×1898 · 118 of 120 fps · 30 Mbps" (a still
    /// picture: "120 fps, still"), and with one device, how it is connected: "… · through Tailscale".
    /// With two or more, each device's own row says it.
    private static func sourceRow(_ s: HostStatusSnapshot) -> StatusPresentation.Row? {
        guard let stream = s.stream else { return nil }
        let title: String, symbol: String
        switch stream.kind {
        case .window: title = middleTruncated(stream.title, to: 44); symbol = "macwindow"
        case .desktop: title = "Whole Desktop"; symbol = "menubar.dock.rectangle"
        case .testPattern: title = "Test Pattern"; symbol = "checkerboard.rectangle"
        }
        // The encoder only produces a frame when the picture changed (ScreenCaptureKit delivers
        // frames on repaint), so 0 means a still window, not a stalled stream. "120 fps, still" is
        // about as wide as a one-digit count ("5 of 120 fps"), so a row wraps the same still as
        // changing, unless the count's own digits tip it: the open menu resizes the card on every
        // change, and "nothing changing" with the route word made it jump a line each time a
        // window stopped or started changing.
        let rate = s.encodedFPS > 0 ? "\(min(s.encodedFPS, stream.fps)) of \(stream.fps) fps" : "\(stream.fps) fps, still"
        var detail = "\(stream.width)×\(stream.height) · \(rate) · \(stream.mbps) Mbps"
        if s.devices.count == 1, let route = routeWord(s.devices[0]) { detail += " · \(route)" }
        if stream.onVirtualDisplay {
            detail += " · virtual display"
        } else if s.virtualDisplayOn, stream.kind == .window {
            detail += " · real window (virtual display: \(s.lastStageFailure ?? s.virtualDisplayProblem ?? "unavailable"))"
        }
        if stream.softwareEncoder { detail += " · software encoder" }
        return StatusPresentation.Row(id: "source", symbol: symbol, title: title, detail: detail)
    }

    /// "iPad (iPad14,1)" over "118 fps · frame age 9 ms · RTT 7 ms · through Tailscale"; the address until the device's first report (within a second; a remote device
    /// shows its paired name), and until then the route alone. A second without a sample reads
    /// "–", as in the host's log line and the device's HUD: a still window sends no frames
    /// (ScreenCaptureKit delivers only repaints), and a second can pass without a pong. While its
    /// link does not keep up (docs/remote-bundle-plan.md §6.6) the numbers give way to it, the frame
    /// age dropping out to keep the row short: "3 fps, the link can’t carry Pro · RTT 531 ms ·
    /// through Tailscale", or "Nothing is getting through · through Tailscale".
    private static func deviceRow(_ d: HostStatusSnapshot.Device) -> StatusPresentation.Row {
        let name = d.name ?? d.endpoint
        let symbol = name.localizedCaseInsensitiveContains("iphone") ? "iphone" : "ipad"
        var parts: [String] = []
        if let link = d.link {
            parts.append(linkWords(link, fps: d.fps, rttMs: d.rttMs))
        } else if let fps = d.fps, let age = d.frameAgeMs, let rtt = d.rttMs {
            parts.append("\(fps) fps · frame age \(ms(age)) · RTT \(ms(rtt))")
        }
        if let route = routeWord(d) { parts.append(route) }
        return StatusPresentation.Row(id: String(describing: d.id), symbol: symbol, title: name,
                                      detail: parts.isEmpty ? nil : parts.joined(separator: " · "))
    }

    /// A device's link that does not keep up, as its row says it: behind, "3 fps, the link can’t carry
    /// Pro · RTT 531 ms" (the fps and the round trip when its stats have come); stalled, "Nothing is
    /// getting through".
    static func linkWords(_ link: HostStatusSnapshot.LinkStatus, fps: Int?, rttMs: Int?) -> String {
        switch link.state {
        case .stalled:
            return "Nothing is getting through"
        case .behind:
            let quality = QualityPreset.name(forBitrate: link.bitrate).replacingOccurrences(of: " ", with: "\u{00A0}")
            var words = (fps.map { "\($0) fps, " } ?? "") + "the link can’t carry \(quality)"
            if let rtt = rttMs { words += " · RTT \(ms(rtt))" }
            return fps == nil ? words.prefix(1).uppercased() + words.dropFirst() : words
        }
    }

    /// How a device reaches this Mac, the one place the card decides it (the device's row, and the
    /// source row while it is the only device): the door's label ("through Tailscale", "by
    /// address"). Its spaces are no-break ones, so a wrapped detail keeps it whole.
    private static func routeWord(_ d: HostStatusSnapshot.Device) -> String? {
        d.remoteRoute.map { $0.replacingOccurrences(of: " ", with: "\u{00A0}") }
    }

    /// One of a device's reported times. Negative is the client's "no sample this second" (-1),
    /// never a time.
    private static func ms(_ v: Int) -> String { v < 0 ? "–" : "\(v) ms" }

    private static func virtualDisplayNote(_ s: HostStatusSnapshot) -> String {
        if let problem = s.virtualDisplayProblem { return "Unavailable: \(problem)" }
        if s.virtualDisplayOn, s.stream?.onVirtualDisplay == true { return "The streamed window is on the virtual display" }
        return "Picked windows leave this screen while they stream"
    }

    /// "Safari — A very long window title that goes on" → "Safari — A very long…that goes on".
    static func middleTruncated(_ text: String, to limit: Int) -> String {
        guard text.count > limit, limit > 1 else { return text }
        let keep = limit - 1
        return String(text.prefix((keep + 1) / 2)) + "…" + String(text.suffix(keep / 2))
    }
}
