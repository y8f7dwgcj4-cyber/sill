import Foundation
import AppKit
import CoreGraphics
import StreamProtocol
import SillHostCore

// Line-buffer stdout so the log reads live when piped or redirected (Swift's print is fully
// buffered off a terminal, which hides the stats line until exit).
setvbuf(stdout, nil, _IOLBF, 0)

// Knobs for the spike: maxFPS, captureScale, bitrate (per 60 fps), prioritizeSpeed. They live in
// Sources/SillHost/HostConfig.swift now (`HostConfig.standard`), which is also where the menu bar
// app's Settings start. Change, rebuild, measure.
var config = HostConfig.standard

// Optional. Streams the first window whose app name or title matches, before any client asks.
// Normally left off: the client picks a window from its bar.
let preselect = CommandLine.arguments.dropFirst().first { !$0.hasPrefix("--") }

// `SillHost --synthetic`: the Desktop source streams a moving test pattern instead of the screen,
// so the encoder, its software fallback and the network can be checked without Screen Recording.
let synthetic = CommandLine.arguments.contains("--synthetic")

// `SillHost --virtual-display`: a picked window is moved onto its own HiDPI virtual display and
// that display is captured, so the window keeps repainting whatever covers its old spot on the
// Mac. Off by default until Noah has tried it. Needs the AppKit event loop below: without it this
// process never sees the display's modes (VirtualDisplay.swift, "Event loop").
let virtualDisplay = CommandLine.arguments.contains("--virtual-display")
config.virtualDisplay = virtualDisplay

// `SillHost --no-clipboard`: share nothing of the clipboard with devices for this run (kind 32,
// docs/clipboard-plan.md). On by default, as in Sill.app: a device whose Share Clipboard is on is
// sent the text copied on this Mac while it is connected, and its own text becomes this Mac's.
// A --synthetic host shares a pasteboard of its own, never this Mac's clipboard.
config.shareClipboard = !CommandLine.arguments.contains("--no-clipboard")

// The door is always on (TLS 1.3, paired devices only), on the Tailscale address in
// tailscale.conf and on the file's port, else 7455. `--remote=PORT` sets another port, and
// `--remote` alone any free port. A new in-memory identity and trust list every run. A pairing
// window is always open (a fresh one after each use or expiry); its code and link are printed
// here, to this process's stdout only. TEST ONLY: SILL_TEST_REMOTE_DIR=<dir> keeps the identity
// and pairings in a 0700 directory, on a --synthetic host only.
config.remoteAccess = true
let remoteFlag = CommandLine.arguments.first { $0 == "--remote" || $0.hasPrefix("--remote=") }
if let remoteFlag {
    if remoteFlag.hasPrefix("--remote=") {
        guard let p = Int(remoteFlag.dropFirst("--remote=".count)), (1024...65535).contains(p) else {
            print("--remote=PORT takes a port from 1024 to 65535.")
            exit(2)
        }
        config.remotePort = p
    } else {
        config.remotePort = 0
    }
}

// `SillHost --tailnet-config=PATH`: the Tailscale address file to read instead of
// ~/Library/Application Support/Sill/tailscale.conf (docs/tailscale.conf.example). The door binds
// only to the address in that file. Without a usable file it does not listen.
let tailnetConfigPath = CommandLine.arguments.first { $0.hasPrefix("--tailnet-config=") }
    .map { String($0.dropFirst("--tailnet-config=".count)) }

// `SillHost --print-tailnet`: the Tailscale address file, the address and port it names, and
// whether a tunnel interface holds that address now; then exits. Read-only: no listener opens.
if CommandLine.arguments.contains("--print-tailnet") {
    let url = tailnetConfigPath.map { URL(fileURLWithPath: $0) } ?? TailnetConfig.defaultURL
    for line in TailnetReport.lines(url: url) { print(line) }
    exit(0)
}

// `SillHost --encoder-selftest`: no capture, no network. Pushes synthetic frames through the real
// HEVCEncoder (hardware, then software) and reports what came back, so the watchdog and the
// fallback can be exercised without Screen Recording. Exits when done.
if CommandLine.arguments.contains("--encoder-selftest") {
    EncoderSelfTest.run()
}

// `SillHost --menu-selftest[=APP]`: the menus a device would be sent for APP (a pid, or the start of
// a running app's name; the frontmost app without it), one level deep, with each read's time. Read-
// only: nothing is activated or pressed, though each menu read makes the app validate that menu.
// The "=" is needed: a bare argument is the window match above. Exits 0, or 1 when nothing was read.
if let app = MenuSelfTest.requested(in: CommandLine.arguments) {
    MenuSelfTest.run(app: app)
}

// ScreenCaptureKit talks to the window server through CoreGraphics, which must be
// initialized on the main thread before any other thread touches it. In a CLI tool
// nothing does that for us, so prime it here and keep stream setup on the main actor.
// Otherwise SCStream aborts with "Assertion failed: (did_initialize), CGS_REQUIRE_INIT".
_ = CGMainDisplayID()

// `SillHost --virtual-display-selftest`: creates one 1000×700 pt @2× virtual display, reports
// whether this process, CoreGraphics and ScreenCaptureKit see it, destroys it and exits. Needs
// no permission for the display itself (SCShareableContent needs Screen Recording; it says so).
// Runs under the AppKit loop like the real thing.
if CommandLine.arguments.contains("--virtual-display-selftest") {
    VirtualDisplaySelfTest.run()
}

// Lives as long as the process. A local inside the Task would be released when setup finished.
var coordinator: StreamCoordinator?

func startHost() {
    Task { @MainActor in
        do {
            let remote = makeRemoteAccess()
            let c = try StreamCoordinator(config: config, synthetic: synthetic, appKitLoop: virtualDisplay, remote: remote,
                                          testHooks: true)
            coordinator = c
            await c.start(preselect: preselect)
            remote.openPairing(requestedBy: nil)
            if synthetic { print("Synthetic mode: pick Desktop on the device (or from a test client) to stream a test pattern.") }
            if virtualDisplay { print("Virtual display mode: a picked window streams from its own HiDPI display; Ctrl-C puts it back.") }
            print("\(c.windowCount) windows on screen.")
            if c.active == .none { print("Nothing is streaming yet: pick a window from the iOS app. Ctrl-C to stop.") }
            Stats.shared.startPrinting()
        } catch {
            print("Error: \(error)")
            print("If this is a permissions error: System Settings › Privacy & Security › Screen Recording, enable Terminal, then run again.")
            exit(1)
        }
    }
}

/// --remote's identity and pairing: in memory (or, TEST ONLY on a --synthetic host, in
/// SILL_TEST_REMOTE_DIR), with the code printed here whenever a window opens or is asked for again.
@MainActor
func makeRemoteAccess() -> RemoteAccess {
    var store: IdentityStore = MemoryIdentityStore()
    if synthetic, let dir = ProcessInfo.processInfo.environment["SILL_TEST_REMOTE_DIR"], !dir.isEmpty {
        do { store = try FileIdentityStore(directory: URL(fileURLWithPath: dir)) } catch { print("SILL_TEST_REMOTE_DIR=\(dir) ignored: \(error)") }
    }
    let remote = RemoteAccess(store: store)
    if let problem = remote.identityProblem { print("Remote access unavailable: \(problem)") }
    if let tailnetConfigPath { remote.tailnetConfigURL = URL(fileURLWithPath: tailnetConfigPath) }
    remote.reopensPairing = true
    remote.logsPairingWindows = false
    var first = true
    remote.onPairingOffer = { offer in
        if first {
            first = false
            print("Remote access for this run on port \(offer.port) (TLS, paired devices only). Pair with \(offer.groupedCode) or \(offer.url)")
        } else {
            print("Pairing: \(offer.again ? "code" : "new code") \(offer.groupedCode) or \(offer.url)")
        }
    }
    return remote
}

if virtualDisplay {
    // The window server delivers display reconfiguration through the app's event port, which
    // dispatchMain() never drains; only under NSApplication.run() does this process learn the
    // virtual display's modes. The main dispatch queue (Task { @MainActor }, Stats' timer, the
    // signal sources) is serviced by the app's run loop, so nothing else changes.
    let app = NSApplication.shared
    app.setActivationPolicy(.prohibited)   // no Dock icon, no app switcher, can never be activated
    HostShutdown.install { coordinator }    // Ctrl-C / kill: put the window back before exiting
    startHost()
    app.run()
} else {
    // A signal ends the process as it always did, a device's keys let go first (HostShutdown).
    HostShutdown.installKeyRelease { coordinator }
    startHost()
    dispatchMain()   // today, byte for byte
}
