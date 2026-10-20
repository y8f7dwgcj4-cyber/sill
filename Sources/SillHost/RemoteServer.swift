import Foundation
import Network
import StreamProtocol

/// The remote door, the only door of this host: a TLS 1.3 listener bound to one Tailscale address
/// (TailnetConfig), for paired devices only. Both sides present self-signed P-256 certificates and
/// pin each other's key (RemoteTLS). No Bonjour, and never a wildcard address.
///
/// This type keeps the listener's life:
///
/// - It binds only to the configured address and port (`NWParameters.requiredLocalEndpoint`).
///   It never takes another address or another port by itself.
/// - It binds only while an up tunnel interface holds that address (TailnetBind.owner). While none
///   does, it waits and tries again.
/// - A failed bind, a port in use or a missing address is tried again after 2, 4, 8, 16, 32, then
///   every 60 s. A network change tries again at once.
/// - When the address leaves its interface (Tailscale stops, the Mac sleeps), the listener stops.
///   It binds again when the address comes back.
///
/// Admission is `Door`, with DoorPolicy's rules: paired keys while Remote Access is on, 8 sessions
/// at most, and pairing only while a window that the Mac's user opened is open.
///
/// Threading: everything here runs on StreamServer's network queue, which the listener, the
/// connections, their verify blocks and the timers share. Callbacks out are on that queue.
final class RemoteServer {
    /// How often the listener looks again that its address is still on its interface, in case no
    /// network change arrives.
    static let addressCheckInterval: TimeInterval = 30

    private let queue: DispatchQueue
    private unowned let server: StreamServer
    private let trust: TrustBox
    private let door: Door

    /// The listener's state, called back on the network queue.
    var onListener: ((RemoteStatus.Listener) -> Void)?
    /// A pairing attempt at this door; the reply may be called from any thread.
    var onPairAttempt: ((Door.PairAttempt, @escaping @Sendable (PairResult) -> Void) -> Void)? {
        get { door.onPairAttempt }
        set { door.onPairAttempt = newValue }
    }

    // On `queue`.
    private var listener: NWListener?
    private var wanted = false
    private var bind: TailnetBind.Target?
    private var retryItem: DispatchWorkItem?
    private var checkItem: DispatchWorkItem?
    /// Tries since the last successful bind: the retry's delay (TailnetBind.retryDelay).
    private var failures = 0
    /// The last state line printed, so that a retry prints nothing new.
    private var lastLine: String?

    init(server: StreamServer, identity: HostIdentity, trust: TrustBox) {
        self.server = server
        queue = server.queue
        self.trust = trust
        door = Door(queue: server.queue, identity: identity, trust: trust, testHost: server.isTestHost)
        door.server = server
    }

    // MARK: The listener

    /// Runs the door on `bind` while `wanted`. A nil `bind` (no usable configuration) stops it. A
    /// new address or port replaces the listener. Accepted connections are independent of it, so
    /// sessions carry on. Thread-safe.
    func set(wanted: Bool, bind: TailnetBind.Target?) {
        queue.async { [self] in
            let changed = bind != self.bind
            self.wanted = wanted
            self.bind = bind
            guard wanted, bind != nil else {
                stopListener()
                failures = 0
                if !wanted { onListener?(.off) }
                return
            }
            if listener != nil, !changed { return }
            stopListener()
            failures = 0
            startListener()
        }
    }

    /// A network change: binds at once when the door should run and does not, and stops the
    /// listener when its address has left its interface.
    func retryNow() {
        queue.async { [self] in
            InterfaceSnapshot.shared.invalidate()
            guard wanted, let bind else { return }
            if listener != nil {
                if TailnetBind.owner(of: bind.bytes, in: InterfaceSnapshot.read()) == nil { addressGone(bind) }
            } else {
                failures = 0
                startListener()
            }
        }
    }

    private func stopListener() {
        retryItem?.cancel(); retryItem = nil
        checkItem?.cancel(); checkItem = nil
        listener?.cancel()
        listener = nil
    }

    private func startListener() {
        retryItem?.cancel(); retryItem = nil
        guard let bind else { return }
        guard TailnetBind.owner(of: bind.bytes, in: InterfaceSnapshot.read()) != nil else {
            report(.waitingForAddress(bind.address),
                   line: "Remote access: \(bind.address) is not on a Tailscale interface yet; waiting.")
            scheduleRetry()
            return
        }
        guard let endpoint = TailnetBind.endpoint(bind) else { failed(.posix(.EINVAL)); return }
        let params = RemoteTLS.parameters(tls: door.tlsOptions(), dialing: false)
        params.requiredLocalEndpoint = endpoint
        let l: NWListener
        do {
            l = try NWListener(using: params)
        } catch {
            failed(error as? NWError ?? .posix(.EINVAL))
            return
        }
        listener = l
        l.newConnectionHandler = { [weak self, weak l] c in
            guard let self, let l, l === self.listener else { c.cancel(); return }
            self.door.accept(c)
        }
        l.stateUpdateHandler = { [weak self, weak l] state in
            guard let self, let l, l === self.listener else { return }
            switch state {
            case .ready:
                let bound = Int(l.port?.rawValue ?? 0)
                failures = 0
                report(.listening(bound), line: "Remote access: listening on \(bind.address) port \(bound) "
                       + "(TLS, paired devices only; \(trust.snapshot.paired.count) paired).")
                scheduleAddressCheck()
            case .failed(let e):
                l.cancel()
                listener = nil
                failed(e)
            case .waiting(let e):
                l.cancel()
                listener = nil
                failed(e)
            default:
                break
            }
        }
        l.start(queue: queue)
    }

    /// The address left its interface while the listener ran: stop it, and bind again when the
    /// address comes back.
    private func addressGone(_ bind: TailnetBind.Target) {
        stopListener()
        failures = 0
        report(.waitingForAddress(bind.address), line: "Remote access: \(bind.address) went away; stopped listening until it comes back.")
        scheduleRetry()
    }

    /// Never another address or port by itself: saved addresses depend on them. Tried again with
    /// backoff; the door never exits the process.
    private func failed(_ e: NWError) {
        guard let bind else { return }
        if case .posix(.EADDRINUSE) = e {
            report(.portInUse(bind.port), line: "Remote access: port \(bind.port) on \(bind.address) is in use by another app; trying again.")
        } else if case .posix(.EADDRNOTAVAIL) = e {
            report(.waitingForAddress(bind.address), line: "Remote access: \(bind.address) is not available yet; trying again.")
        } else {
            report(.failed("\(e)"), line: "Remote access could not start on \(bind.address) (\(e)); trying again.")
        }
        scheduleRetry()
    }

    private func scheduleRetry() {
        let delay = TailnetBind.retryDelay(failures: failures)
        failures += 1
        let item = DispatchWorkItem { [weak self] in
            guard let self, self.wanted, self.listener == nil else { return }
            self.startListener()
        }
        retryItem?.cancel()
        retryItem = item
        queue.asyncAfter(deadline: .now() + delay, execute: item)
    }

    private func scheduleAddressCheck() {
        let item = DispatchWorkItem { [weak self] in
            guard let self, self.listener != nil, let bind = self.bind else { return }
            InterfaceSnapshot.shared.invalidate()
            if TailnetBind.owner(of: bind.bytes, in: InterfaceSnapshot.read()) == nil {
                self.addressGone(bind)
            } else {
                self.scheduleAddressCheck()
            }
        }
        checkItem?.cancel()
        checkItem = item
        queue.asyncAfter(deadline: .now() + Self.addressCheckInterval, execute: item)
    }

    /// The state to the owner, and its line once (a retry with the same outcome prints nothing).
    private func report(_ state: RemoteStatus.Listener, line: String) {
        if line != lastLine { print(line); lastLine = line }
        onListener?(state)
    }

    // MARK: Closing sessions

    /// Every admitted remote session whose route matches gets goodbye `reason` and is closed; `line`
    /// names one (from its paired name and endpoint) for the log, and `done` gets how many there
    /// were. Thread-safe.
    func closeSessions(_ reason: String, matching: @escaping @Sendable (ClientRoute) -> Bool,
                       line: (@Sendable (String, String) -> String)? = nil, done: (@Sendable (Int) -> Void)? = nil) {
        server.closeSessions(reason, matching: matching, line: line, done: done)
    }
}
