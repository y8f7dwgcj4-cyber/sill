import CoreGraphics

/// The host's knobs, as one value. The CLI streams with `standard` (plus its --virtual-display
/// flag); the menu bar app starts from the same values and lets Settings change
/// them while it runs. Change `standard`, rebuild, measure: both pick it up.
///
/// The coordinator takes a new value only between pipelines (inside `select`), so one pipeline
/// never mixes two settings. See `StreamCoordinator.setTarget`.
package struct HostConfig: Equatable, Sendable {
    /// Ceiling for the stream rate; each device asks for its own panel's rate (60 until it does).
    package var maxFPS: Int
    /// 2 = Retina capture, 1 = points (much cheaper).
    package var captureScale: CGFloat
    /// Bits per second per 60 fps; a faster stream gets proportionally more.
    package var bitrate: Int
    /// The away quality (docs/remote-bundle-plan.md §5): what streams while every connected device is
    /// away from home (through a VPN or over the internet). Per 60 fps and 2/1, like `bitrate` and
    /// `captureScale`, which are the home quality: what the Mac's menu sets and what runs while any
    /// device is at home. A device away sets these, never the home pair (`applyingAway`).
    package var awayBitrate: Int
    package var awayCaptureScale: CGFloat
    /// Apple: trades quality for encode speed; try after the baseline.
    package var prioritizeSpeed: Bool
    /// A picked window streams from its own HiDPI virtual display (see VirtualStage). Needs the
    /// AppKit event loop, so the CLI turns it on only with --virtual-display.
    package var virtualDisplay: Bool
    /// Remote access: the remote door runs (TLS 1.3, paired devices only; RemoteAccess). The Mac's
    /// alone: absent from StreamSettings, HostSettingsChange, DeviceSettings.accepted, `applying`
    /// and `restartNeeded`, so no device can widen who reaches the Mac.
    package var remoteAccess: Bool
    /// The remote door's port. 7455 in `standard`; 0 = any free port (SillHost --remote without a
    /// port). Never another port by itself: saved addresses depend on it.
    package var remotePort: Int
    /// Share clipboard with devices (docs/clipboard-plan.md, HostClipboard): a device that asks (kind
    /// 32) is sent the text copied on this Mac while it shares the clipboard, and its own text becomes
    /// this Mac's. The Mac's alone, like Remote Access: absent from StreamSettings,
    /// HostSettingsChange, DeviceSettings.accepted, `applying` and `restartNeeded`, so no device turns
    /// it on. Applied at once (`StreamCoordinator.setTarget`), not between pipelines.
    package var shareClipboard: Bool

    /// Every knob is required, so the compiler finds each place that builds one when a knob is added.
    package init(maxFPS: Int, captureScale: CGFloat, bitrate: Int, awayBitrate: Int, awayCaptureScale: CGFloat,
                 prioritizeSpeed: Bool, virtualDisplay: Bool, remoteAccess: Bool, remotePort: Int,
                 shareClipboard: Bool) {
        self.maxFPS = maxFPS
        self.captureScale = captureScale
        self.bitrate = bitrate
        self.awayBitrate = awayBitrate
        self.awayCaptureScale = awayCaptureScale
        self.prioritizeSpeed = prioritizeSpeed
        self.virtualDisplay = virtualDisplay
        self.remoteAccess = remoteAccess
        self.remotePort = remotePort
        self.shareClipboard = shareClipboard
    }

    /// The spike's knobs, formerly the `let`s at the top of the CLI's main.swift, and the app's
    /// defaults. Virtual display off in both. Remote access on: the door is the only way in, and it
    /// listens only on the Tailscale address in tailscale.conf (it fails closed without the file).
    /// 7455 is unassigned at IANA and below the ephemeral range. Away from home,
    /// Low · Standard: a slow connection never starts at the home quality. Share clipboard with
    /// devices on: each device has its own switch too, and a password manager's copies never go.
    package static let standard = HostConfig(maxFPS: 120, captureScale: 2, bitrate: 15_000_000,
                                             awayBitrate: 4_000_000, awayCaptureScale: 1,
                                             prioritizeSpeed: false, virtualDisplay: false,
                                             remoteAccess: true, remotePort: 7455, shareClipboard: true)

    /// The remote door's port when none is set.
    package static let defaultRemotePort = 7455

    /// Within what the pipeline supports: 24…120 fps, Retina or points, 1–200 Mbps per 60 fps
    /// (so up to 400 Mbps at 120 fps; the top preset, Extreme, is 150), the away pair within the
    /// same bounds, a remote port of 0 (any) or 1024…65535 (else 7455). A hand-edited default or a
    /// launch argument can hold anything; a device can set only a preset (`DeviceSettings`).
    package func validated() -> HostConfig {
        var c = self
        c.maxFPS = min(max(maxFPS, 24), 120)
        c.captureScale = captureScale >= 1.5 ? 2 : 1
        c.bitrate = min(max(bitrate, 1_000_000), 200_000_000)
        c.awayCaptureScale = awayCaptureScale >= 1.5 ? 2 : 1
        c.awayBitrate = min(max(awayBitrate, 1_000_000), 200_000_000)
        if remotePort != 0 && !(1024...65535).contains(remotePort) { c.remotePort = Self.defaultRemotePort }
        return c
    }

    /// What differs from `new`, for the log: "frame rate limit 120 → 60 fps, bitrate 15 → 8 Mbps
    /// per 60 fps, Retina → points, away bitrate 4 → 15 Mbps per 60 fps, away points → Retina, speed
    /// off → on, virtual display off → on, remote access off → on, remote port 7455 → 7460, share
    /// clipboard on → off".
    package func changes(to new: HostConfig) -> String {
        func onOff(_ b: Bool) -> String { b ? "on" : "off" }
        func scaleName(_ s: CGFloat) -> String { s >= 1.5 ? "Retina" : "points" }
        var parts: [String] = []
        if maxFPS != new.maxFPS { parts.append("frame rate limit \(maxFPS) → \(new.maxFPS) fps") }
        if bitrate != new.bitrate { parts.append("bitrate \(Self.mbps(bitrate)) → \(Self.mbps(new.bitrate)) Mbps per 60 fps") }
        if captureScale != new.captureScale { parts.append("\(scaleName(captureScale)) → \(scaleName(new.captureScale))") }
        if awayBitrate != new.awayBitrate { parts.append("away bitrate \(Self.mbps(awayBitrate)) → \(Self.mbps(new.awayBitrate)) Mbps per 60 fps") }
        if awayCaptureScale != new.awayCaptureScale { parts.append("away \(scaleName(awayCaptureScale)) → \(scaleName(new.awayCaptureScale))") }
        if prioritizeSpeed != new.prioritizeSpeed { parts.append("speed \(onOff(prioritizeSpeed)) → \(onOff(new.prioritizeSpeed))") }
        if virtualDisplay != new.virtualDisplay { parts.append("virtual display \(onOff(virtualDisplay)) → \(onOff(new.virtualDisplay))") }
        if remoteAccess != new.remoteAccess { parts.append("remote access \(onOff(remoteAccess)) → \(onOff(new.remoteAccess))") }
        if remotePort != new.remotePort { parts.append("remote port \(remotePort) → \(new.remotePort)") }
        if shareClipboard != new.shareClipboard { parts.append("share clipboard \(onOff(shareClipboard)) → \(onOff(new.shareClipboard))") }
        return parts.isEmpty ? "no change" : parts.joined(separator: ", ")
    }

    /// The quality the pipeline runs (docs/remote-bundle-plan.md §5.4): the away pair while every
    /// connected device is away (`away`), else the home one.
    package func effective(away: Bool) -> (bitrate: Int, captureScale: CGFloat) {
        away ? (awayBitrate, awayCaptureScale) : (bitrate, captureScale)
    }

    /// "15", or "8.5" for a bitrate that is not whole megabits.
    package static func mbps(_ bitsPerSecond: Int) -> String {
        bitsPerSecond % 1_000_000 == 0 ? "\(bitsPerSecond / 1_000_000)"
                                       : String(format: "%.1f", Double(bitsPerSecond) / 1_000_000)
    }
}
