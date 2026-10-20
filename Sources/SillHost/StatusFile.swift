import Foundation

/// A small health file for the command line: `~/Library/Application Support/Sill/status.json`.
///
/// `cat` it, or `plutil -p` it, to see whether the host listens, on which address and port, and
/// how many devices are connected. The host writes it when its status changes, at most once a
/// second, and again every 30 s with a new `updatedAt`. An `updatedAt` older than about a minute
/// means that the host is not running, or is stuck.
///
/// The file holds no secret: no pairing code, no key and no device name. It is written
/// atomically, with mode 0600, in a directory with mode 0700.
package final class StatusFile: @unchecked Sendable {
    /// What the file says. Every field is plain text or a number, so that `grep` can read it too.
    package struct Health: Codable, Equatable, Sendable {
        /// The host's process ID.
        var pid: Int32
        /// ISO 8601, in UTC.
        var updatedAt: String
        /// "listening", "waiting for address", "not configured", "port in use", "failed", "off".
        var listener: String
        /// Why the door does not listen, when it does not.
        var problem: String?
        /// The Tailscale address in the configuration.
        var address: String?
        /// The bound port while it listens.
        var port: Int?
        var remoteAccess: Bool
        var pairedDevices: Int
        var connectedDevices: Int
        var streaming: Bool
        /// "hardware" or "software".
        var encoder: String
    }

    package static var defaultURL: URL {
        TailnetConfig.defaultURL.deletingLastPathComponent().appendingPathComponent("status.json")
    }

    static let heartbeat: TimeInterval = 30
    static let minimumSpacing: TimeInterval = 1

    private let url: URL
    private let queue = DispatchQueue(label: "sill.statusfile", qos: .utility)
    // On `queue`.
    private var current: Health?
    private var written: Health?
    private var lastWrite: CFAbsoluteTime = 0
    private var pending = false
    private var timer: DispatchSourceTimer?

    package init(url: URL = defaultURL) {
        self.url = url
    }

    /// Records `health` and writes it soon. Thread-safe.
    func update(_ health: Health) {
        queue.async { [self] in
            current = health
            startHeartbeat()
            scheduleWrite()
        }
    }

    private func scheduleWrite() {
        guard !pending else { return }
        let wait = max(0, Self.minimumSpacing - (CFAbsoluteTimeGetCurrent() - lastWrite))
        pending = true
        queue.asyncAfter(deadline: .now() + wait) { [self] in
            pending = false
            writeNow(force: false)
        }
    }

    private func startHeartbeat() {
        guard timer == nil else { return }
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + Self.heartbeat, repeating: Self.heartbeat)
        t.setEventHandler { [weak self] in self?.writeNow(force: true) }
        t.resume()
        timer = t
    }

    /// Writes the current health, unless nothing but the time changed and `force` is false.
    private func writeNow(force: Bool) {
        guard var health = current else { return }
        health.updatedAt = Self.timestamp()
        var unchanged = written
        unchanged?.updatedAt = health.updatedAt
        if !force, unchanged == health { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(health) else { return }
        let dir = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        do {
            try FileIdentityStore.writePrivate(data, to: url)
            written = health
            lastWrite = CFAbsoluteTimeGetCurrent()
        } catch {
            // Said in the log for a change, not for each heartbeat.
            if !force { print("Status file: could not write \(url.path) (\(error)).") }
        }
    }

    static func timestamp(_ date: Date = Date()) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: date)
    }
}

extension StatusFile.Health {
    /// The health from the host's snapshot. Main actor, where the snapshot lives.
    @MainActor
    init(_ s: HostStatusSnapshot) {
        let r = s.remote
        var listener = "off", problem: String?, port: Int?
        switch r?.listener ?? .off {
        case .off: listener = "off"
        case .listening(let p): listener = "listening"; port = p
        case .portInUse(let p): listener = "port in use"; problem = "port \(p) is in use"
        case .failed(let e): listener = "failed"; problem = e
        case .notConfigured(let why): listener = "not configured"; problem = why
        case .waitingForAddress(let a): listener = "waiting for address"; problem = "\(a) is not on a Tailscale interface"
        }
        if let identity = r?.identityProblem { listener = "not configured"; problem = "keychain: \(identity)" }
        self.init(pid: getpid(), updatedAt: StatusFile.timestamp(), listener: listener, problem: problem,
                  address: r?.addresses.first?.host, port: port, remoteAccess: r?.remoteAccess ?? false,
                  pairedDevices: r?.paired.count ?? 0, connectedDevices: s.devices.count,
                  streaming: s.stream != nil, encoder: s.softwareEncoder ? "software" : "hardware")
    }
}
