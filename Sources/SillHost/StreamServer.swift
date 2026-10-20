import Foundation
import Network
import StreamProtocol

/// The session hub: it pushes messages to every connected client and reads what each sends.
/// Slow clients drop delta frames rather than building a queue (that queue is latency).
///
/// It has no listener of its own. The remote door (RemoteServer) listens on the configured
/// Tailscale address only, admits each connection through its Door (TLS 1.3, both keys pinned,
/// paired devices only), and hands each admitted session to `serve`. There is no Bonjour
/// registration, no peer-to-peer Wi-Fi and no plain TCP door.
///
/// The device gate (DeviceGate, `gate`): with the floor above "0", a ready session is held
/// unregistered until its first message, which must be a hello the floor admits. Any other
/// device gets kind 22 "update" and is closed, never registered. The gate runs in the Door once
/// the key is admitted. With the floor at "0" (every build so far) nothing waits.
///
/// Remote clients get their own eviction (silence, a longer drain backstop) and pacing, by the
/// bytes their connection has not taken (`paceRemote`), because a slow uplink is normal there.
///
/// TEST ONLY, on a test host (DoorPolicy.isTestHost): `SILL_TEST_MIN_DEVICE_VERSION=1.2` raises
/// the device floor from "0", and `SILL_TEST_GOODBYE='<JSON>'` makes its refusals send that kind 22
/// payload instead.
final class StreamServer {
    private final class Client {
        let connection: NWConnection
        var inflight = 0          // every message still unacknowledged (backpressure for delta drops)
        var inflightFrames = 0    // video frames only
        var oldestUnackedFrameAt: TimeInterval?   // last time a frame was drained, or queued from 0 (dead-peer detection)
        /// When it was admitted (registered), which is when the dead-peer grace starts.
        var connectedAt = Date().timeIntervalSince1970
        var needsKeyframe = true
        var lastStatsPrint = 0.0  // CFAbsoluteTime of the last clientStats line, to rate-limit the log
        /// The worst frame age and rtt reported since that line, -1 for none. The next line prints
        /// them, so a report the rate limit skips still shows its spike. Only newer clients send maxima.
        var worstFrameAgeSincePrint = -1
        var worstRttSincePrint = -1
        /// From where the remote door admitted it, with its key.
        let route: ClientRoute
        /// The device's own name from its last ClientStats, cleaned (SafeText), for its stats line
        /// and the line that says why it was disconnected; nil until its first report.
        var device: String?
        /// The last header received from it (remote clients: silence eviction).
        var lastHeardAt = Date().timeIntervalSince1970
        /// No keyframe has reached it since it was admitted or the stream changed: a remote client's
        /// next one goes out whatever its queue holds, and no client's skipped frames count against
        /// its link meanwhile (LinkJudge: that wait is the connect or a restart, not the link).
        var awaitingFirstKeyframe = true
        /// Remote clients: a frame was dropped for it and a keyframe should be asked for, when
        /// `remoteKeyframeDue` (at most every 2 s across all remote clients, later beside a home one).
        var keyframeWanted = false
        /// When a message was last handed to it (TLS clients skip a tick right after one).
        var lastSentAt: TimeInterval = 0
        /// Its connection is TLS: every session is.
        var encrypted = true
        /// Bytes handed to the connection that it has not taken yet (`.contentProcessed`), every
        /// message `inflight` counts: every client's, which its link judge reads (the home branch of
        /// `broadcast` never does); and, remote clients only, the keyframes among them it is still
        /// taking (sequence number and size, oldest first), with their bytes. Usually none or one;
        /// two when a keyframe comes while another is still being taken: a restarted stream's first
        /// (a pick, a rotation, a settings change), or the next one on a link that takes a keyframe
        /// longer than the time between two.
        var pendingBytes = 0
        var keyframesInFlight: [(seq: Int, bytes: Int)] = []
        var keyframeBytesInFlight = 0
        var keyframeSeq = 0
        /// Remote clients: the smallest backlog since the keyframes it was taking were all taken,
        /// which starts at what they left behind them (the frames that queued while they were).
        var backlogFloor = 0
        /// Its link (docs/remote-bundle-plan.md §6): this second's frames sent and withheld (not
        /// those before its first keyframe) and the bytes its connection took, closed by the sweep
        /// each second into the judge.
        var sentThisSecond = 0
        var withheldThisSecond = 0
        var takenThisSecond = 0
        var judge = LinkJudge()
        /// A hello (kind 23) came on this connection: only the first counts.
        var helloSeen = false
        /// The input messages (kind 8) read from it. Every kind 26 sent to it carries the count, so the
        /// device can drop one the host built before it read that device's latest input
        /// (docs/pointer-visibility-plan.md §3.3).
        var inputsRead = 0
        /// The last kind 26 sent to it; nil also while it drives the pointer, so the next one goes out
        /// whatever it says.
        var lastPointer: MacPointer?
        init(_ c: NWConnection, route: ClientRoute) { connection = c; self.route = route }
    }

    /// The network queue: the remote door, its connections, the verify blocks and the timers.
    let queue: DispatchQueue
    private var clients: [ObjectIdentifier: Client] = [:]
    private var lastParameterSets: Data?
    /// The remote door admitted a client (paired and checked), with its route. Called on the
    /// network queue.
    var onClientConnected: ((NWConnection, ClientRoute) -> Void)?
    /// A message from a client (selectSource, launchApp). Called on the network queue.
    var onMessage: ((StreamMessage, NWConnection) -> Void)?
    /// A client fell behind and lost a delta frame; the encoder should produce a keyframe now
    /// rather than in up to 4 s. Called on the network queue.
    var onKeyframeNeeded: (() -> Void)?
    /// Number of connected clients changed. Called on the network queue. Zero means the host can idle.
    var onClientCountChanged: ((Int) -> Void)?
    /// One connection ended (before `onClientCountChanged`), for per-client state such as its rate.
    var onClientDisconnected: ((NWConnection) -> Void)?
    /// Every ClientStats report, about once a second per device (the log prints every other one).
    /// Called on the network queue.
    var onClientStats: ((NWConnection, ClientStats) -> Void)?
    /// A device's hello (kind 23), the first of its connection, once it is registered. Called on the
    /// network queue.
    var onClientHello: ((NWConnection, Hello) -> Void)?
    /// A device's link changed (LinkJudge, docs/remote-bundle-plan.md §6): behind, stalled, fine again,
    /// fine because the stream restarted at another quality (`reset`), or the same state once its
    /// carried rate is first measured. Called on the network queue, from the once-a-second sweep and
    /// `resetLinks`.
    var onClientLinkChanged: ((NWConnection, LinkJudge.Verdict) -> Void)?
    /// The Mac's pointer (PointerWatch): who moves it, sampled at each tick and, while it moves over
    /// the source and a device is sent it, at the stream's frame rate; every device that is not
    /// moving it is sent where it is (kind 26). Set before the first session.
    var pointerWatch: PointerWatch?

    /// The oldest device version served (DeviceGate): the shipped "0" admits every device and
    /// nothing waits for a hello. TEST ONLY: SILL_TEST_MIN_DEVICE_VERSION on a host that does not
    /// advertise.
    let deviceFloor: SillVersion
    /// The Mac's name, for the update goodbye's message. Set by the coordinator before the first session.
    var macName = "Mac"
    /// TEST ONLY: SILL_TEST_GOODBYE's payload, sent by a refusal instead of the update goodbye.
    private let testGoodbye: Data?

    // MARK: Link keepalive
    //
    // Measured 2026-09-22: with nothing streaming, the iPad's ping round trip climbs 5 → 100 → 200 →
    // 300 ms in a sawtooth every few seconds while a simulator on the same Mac stays at 0 ms. That is
    // the device's Wi-Fi radio dozing whenever the downlink goes quiet; every next packet waits for a
    // wake window. During a steady video stream it never happens. A trackpad stroke over a static
    // window starts from a quiet link, so its first frames arrive 100–300 ms late and then bunch up:
    // the stutter. While a session is live we keep the downlink lightly busy with an empty 14-byte
    // tick every 30 ms (~0.5 KB/s). "Live" = the coordinator says a source is streaming, or a client
    // sent input in the last 3 s. Idle sessions tick nothing and let the radio sleep.
    //
    // The tick also samples the Mac's pointer (PointerWatch) and sends where it is (kind 26) to every
    // device that is not moving it, when that changed; a kind 26 stands in for that device's tick.
    // While the pointer moves over the source and a device is sent it, the frame-rate sampler
    // samples it at the stream's rate instead (docs/pointer-visibility-plan.md Q4, decided
    // 2026-09-26), so the device draws it as smoothly as the picture, and the tick only keeps the
    // link awake; at 33 fps and below the tick samples as often, and no sampler runs
    // (PointerWatch.samplerInterval). Without a geometry (nothing streams, or a synthetic host
    // without its scripted pointer) nothing is read.
    private var tickTimer: DispatchSourceTimer?
    private var lastInputAt: TimeInterval = 0
    private var streaming = false
    private static let tickInterval = 0.030
    private static let inputRecency = 3.0

    /// The coordinator flips this with the active source. Thread-safe.
    func setStreaming(_ on: Bool) {
        queue.async { [self] in streaming = on; updateTicking() }
    }

    /// On the network queue.
    private func updateTicking() {
        let wanted = !clients.isEmpty && (streaming || Date().timeIntervalSince1970 - lastInputAt < Self.inputRecency)
        if wanted, tickTimer == nil {
            let t = DispatchSource.makeTimerSource(queue: queue)
            t.schedule(deadline: .now(), repeating: Self.tickInterval, leeway: .milliseconds(5))
            t.setEventHandler { [weak self] in self?.tick() }
            t.resume()
            tickTimer = t
        } else if !wanted, let t = tickTimer {
            t.cancel(); tickTimer = nil
            setPointerSampler(interval: nil)
        }
    }

    /// On the network queue. Re-evaluates the recency rule so the timer stops itself after a quiet spell.
    private func tick() {
        let live = streaming || Date().timeIntervalSince1970 - lastInputAt < Self.inputRecency
        guard live, !clients.isEmpty else { updateTicking(); return }
        let now = Date().timeIntervalSince1970
        // The Mac's pointer, unless the frame-rate sampler has it while it moves.
        let reported = pointerSampler == nil ? samplePointer(now: now) : []
        let data = StreamMessage(kind: .tick, timestamp: now, isKeyframe: false, payload: Data()).serialized()
        for (id, client) in clients where client.connection.state == .ready {
            // A kind 26 just sent keeps its link awake this turn.
            if reported.contains(id) { continue }
            // Over TLS every record costs CPU (the remote plan's H20): skip a tick right after
            // anything else went out. The link is busy anyway, so the device's radio stays awake
            // exactly as before. The plain door keeps every tick.
            if client.encrypted, now - client.lastSentAt < Self.tickInterval { continue }
            client.connection.send(content: data, completion: .contentProcessed { _ in })   // not counted as inflight
        }
        Stats.shared.bump("net.tick")
    }

    // MARK: The Mac's pointer (kind 26)

    /// The frame-rate sampler: while the pointer moves over the source and a device is sent it, the
    /// pointer is sampled every frame interval of the stream instead of at the tick, when that is
    /// more often (PointerWatch.samplerInterval). On `queue`.
    private var pointerSampler: DispatchSourceTimer?
    private var pointerSamplerInterval = 0.0

    /// On `queue`: one sample of the Mac's pointer, and to every ready device that is not moving it a
    /// kind 26 when its report differs from the last one it was sent: at most one a sample, only on
    /// a change, sent as the tick is (not counted in `inflight`, so it can never make a slow link
    /// drop frames). A device that moves it is sent nothing and its last report is forgotten, so
    /// the next one goes out once it stops. Starts the frame-rate sampler while the pointer moves
    /// over the source and a device is sent it, faster than the tick, and stops it otherwise
    /// (PointerWatch.samplerInterval). Returns the devices sent one.
    @discardableResult
    private func samplePointer(now: TimeInterval) -> Set<ObjectIdentifier> {
        let ready = clients.compactMap { $0.value.connection.state == .ready ? $0.key : nil }
        guard let watch = pointerWatch, let reading = watch.sample(devices: ready) else {
            setPointerSampler(interval: nil)
            return []
        }
        var sent = Set<ObjectIdentifier>()
        var watched = false
        for (id, client) in clients where client.connection.state == .ready {
            guard let report = reading.report(for: id, seen: client.inputsRead) else {
                client.lastPointer = nil
                continue
            }
            watched = true
            guard report != client.lastPointer else { continue }
            client.lastPointer = report
            let data = StreamMessage(kind: .macPointer, timestamp: now, isKeyframe: false, payload: Wire.encode(report)).serialized()
            client.connection.send(content: data, completion: .contentProcessed { _ in })   // not counted as inflight
            client.lastSentAt = now
            Stats.shared.bump("ptr.sent")
            sent.insert(id)
        }
        let every = PointerWatch.samplerInterval(moving: reading.moving, inside: reading.inside, watched: watched,
                                                 frameInterval: watch.frameInterval, tickInterval: Self.tickInterval)
        setPointerSampler(interval: every)
        return sent
    }

    /// On `queue`: runs the frame-rate sampler every `interval` seconds, or stops it (nil). A new
    /// interval (the stream restarted at another rate) restarts it.
    private func setPointerSampler(interval: Double?) {
        guard let interval else {
            pointerSampler?.cancel()
            pointerSampler = nil
            return
        }
        if pointerSampler != nil, pointerSamplerInterval == interval { return }
        pointerSampler?.cancel()
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + interval, repeating: interval, leeway: .milliseconds(1))
        t.setEventHandler { [weak self] in
            guard let self, self.tickTimer != nil, !self.clients.isEmpty else { self?.setPointerSampler(interval: nil); return }
            self.samplePointer(now: Date().timeIntervalSince1970)
        }
        t.resume()
        pointerSampler = t
        pointerSamplerInterval = interval
    }

    // MARK: Sessions, without a listener of their own
    //
    // This type has no listener. The remote door (RemoteServer) is the only door: it listens on the
    // configured Tailscale address alone, admits a connection through its Door, and hands each
    // admitted session to `serve`. There is no Bonjour registration and no peer-to-peer Wi-Fi.

    /// A test host (DoorPolicy.isTestHost: a synthetic host that is not Sill.app's own executable):
    /// the only kind that reads the device floor's TEST ONLY variable.
    private let testHost: Bool

    /// `testHost`: true only for a synthetic host that is not Sill.app's own executable.
    init(testHost: Bool) {
        queue = DispatchQueue(label: "sill.net", qos: .userInteractive)
        self.testHost = testHost
        (deviceFloor, testGoodbye) = Self.gateSettings(testHost: testHost)
    }

    /// The device floor, and a test goodbye: DeviceGate's constant, except on a test host where
    /// SILL_TEST_MIN_DEVICE_VERSION replaces it and SILL_TEST_GOODBYE (a JSON Goodbye, sent as
    /// written) replaces the refusal's payload. A value that does not parse is ignored with one line.
    private static func gateSettings(testHost: Bool) -> (SillVersion, Data?) {
        guard testHost else { return (DeviceGate.floor, nil) }
        let env = ProcessInfo.processInfo.environment
        var floor = DeviceGate.floor
        if let raw = env["SILL_TEST_MIN_DEVICE_VERSION"], !raw.isEmpty {
            if let v = SillVersion(raw) { floor = v } else { print("SILL_TEST_MIN_DEVICE_VERSION=\(raw) ignored: not a version.") }
        }
        var goodbye: Data?
        if let raw = env["SILL_TEST_GOODBYE"], !raw.isEmpty {
            if Wire.decode(Goodbye.self, from: Data(raw.utf8)) != nil { goodbye = Data(raw.utf8) } else { print("SILL_TEST_GOODBYE ignored: not a Goodbye.") }
        }
        return (floor, goodbye)
    }

    /// Where `c` comes from: its endpoint's address, the local address it arrived at
    /// (`currentPath.localEndpoint`, which names the interface through `InterfaceSnapshot`),
    /// classified by OriginPolicy. On `queue`, at `.preparing` or later.
    func origin(of c: NWConnection) -> OriginPolicy.Origin { arrival(of: c).origin }

    /// `origin(of:)` with the interface it arrived on (the scope, else the owner of the local
    /// address), which names a VPN route ("through Tailscale").
    func arrival(of c: NWConnection) -> (origin: OriginPolicy.Origin, interface: String?) {
        guard case .hostPort(let host, _) = c.endpoint else { return (.internet, nil) }
        let (remote, scope) = Self.addressText(host)
        return arrival(remote: remote, scope: scope ?? OriginPolicy.scope(ofEndpoint: "\(c.endpoint)"), local: Self.pathLocal(c))
    }

    /// The same before `c` starts: a started TLS connection answers a ClientHello that is already
    /// waiting with the whole server flight, the Mac's certificate included, before any state
    /// callback runs. An accepted connection has its path already in `newConnectionHandler`; should
    /// one not, the local address is the one the kernel's route back to the peer sends from. Nil
    /// when neither is known: `.preparing` judges it then.
    func arrivalBeforeStart(of c: NWConnection) -> (origin: OriginPolicy.Origin, interface: String?)? {
        guard case .hostPort(let host, _) = c.endpoint else { return (.internet, nil) }
        let (remote, endpointScope) = Self.addressText(host)
        let scope = endpointScope ?? OriginPolicy.scope(ofEndpoint: "\(c.endpoint)")
        var local = Self.pathLocal(c)
        if local == nil, scope == nil, let source = IPBytes.parse(remote), !IPBytes.isLoopback(source) {
            guard let routed = InterfaceSnapshot.routeSource(to: source) else { return nil }
            local = IPBytes.text(routed)
        }
        return arrival(remote: remote, scope: scope, local: local)
    }

    /// The local address of `c`'s path, where it arrived; nil while it has no path.
    private static func pathLocal(_ c: NWConnection) -> String? {
        guard case .hostPort(let host, _)? = c.currentPath?.localEndpoint else { return nil }
        return addressText(host).text
    }

    private func arrival(remote: String, scope: String?, local: String?) -> (origin: OriginPolicy.Origin, interface: String?) {
        let interfaces = InterfaceSnapshot.shared.interfaces()
        let o = OriginPolicy.classify(remote: remote, localAddress: local, scope: scope, interfaces: interfaces)
        return (o, OriginPolicy.arrivalInterface(localAddress: local, scope: scope, interfaces: interfaces))
    }

    /// A test host: the only kind that honours TEST ONLY variables.
    var isTestHost: Bool { testHost }

    /// An endpoint host as an address string without its zone, and the interface a scoped
    /// (link-local) IPv6 address names.
    static func addressText(_ host: NWEndpoint.Host) -> (text: String, scope: String?) {
        switch host {
        case .ipv4(let a): return (IPBytes.text([UInt8](a.rawValue)), a.interface?.name)
        case .ipv6(let a): return (IPBytes.text([UInt8](a.rawValue)), a.interface?.name)
        case .name(let n, let i): return (n, i?.name)
        @unknown default: return ("\(host)", nil)
        }
    }

    /// On `queue`: from now on `client` gets broadcasts, ticks and the catalog.
    private func register(_ client: Client) {
        client.connectedAt = Date().timeIntervalSince1970
        client.lastHeardAt = client.connectedAt
        clients[ObjectIdentifier(client.connection)] = client
        onClientCountChanged?(clients.count)
        updateTicking()
        updateSweep()
    }

    /// A session the remote door admitted, already `.ready` and pinned, once the device gate has
    /// let it in (its Door runs `gate` first, and judges again what changed meanwhile): registered
    /// with its route, then `admitted` (the door's "Remote client connected" line), then its hello,
    /// when the gate read one (`took`). On `queue`.
    func serve(_ connection: NWConnection, route: ClientRoute, hello: Hello?, admitted: () -> Void = {}) {
        let client = Client(connection, route: route)
        let id = ObjectIdentifier(connection)
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .failed:
                connection.cancel()
                self.unregister(id)
            case .cancelled:
                self.unregister(id)
            default: break
            }
        }
        register(client)
        receiveLoop(client)
        onClientConnected?(connection, route)
        admitted()
        if let hello { took(hello, from: client) }
    }

    /// Admitted remote sessions: how many. On `queue`.
    var remoteSessionCount: Int { clients.values.filter { $0.route.isRemote }.count }

    /// Every admitted session, of either door, whose route matches gets goodbye `reason` and is
    /// closed; `line` names one (its paired name, else the device's own, and its endpoint) for the
    /// log, and `done` gets how many there were. Thread-safe.
    func closeSessions(_ reason: String, matching: @escaping @Sendable (ClientRoute) -> Bool,
                       line: (@Sendable (String, String) -> String)? = nil, done: (@Sendable (Int) -> Void)? = nil) {
        queue.async { [self] in
            let list = clients.values.filter { matching($0.route) }
            for client in list {
                if let line { print(line(client.route.pairedName ?? client.device ?? "a device", "\(client.connection.endpoint)")) }
                goodbye(Goodbye(reason: reason), to: client.connection)
            }
            done?(list.count)
        }
    }

    // MARK: Goodbye (kind 22)

    /// Tells one admitted client why it is about to be closed, then closes it once the message is
    /// handed to the network or `within` has passed, whichever comes first: a registered client,
    /// whose connection the stream and the catalog share. A connection that was never registered
    /// closes with `closeWithGoodbye`. On `queue`.
    func goodbye(_ goodbye: Goodbye, to connection: NWConnection, within: TimeInterval = 0.25) {
        Self.sayGoodbye(payload: Wire.encode(goodbye), on: connection, queue: queue, within: within)
    }

    /// A kind 22 with this payload, then the close. On `queue`.
    private static func sayGoodbye(payload: Data, on connection: NWConnection, queue: DispatchQueue, within: TimeInterval) {
        let data = StreamMessage(kind: .goodbye, timestamp: Date().timeIntervalSince1970, isKeyframe: false,
                                 payload: payload).serialized()
        connection.send(content: data, completion: .contentProcessed { _ in connection.cancel() })
        queue.asyncAfter(deadline: .now() + within) { connection.cancel() }
    }

    /// Every admitted client, home and remote, gets `goodbye` (the app's Quit and the signal path:
    /// "quit"); returns once each message was handed to the network or after `within`. Call from
    /// any thread but the network queue.
    func goodbyeAll(_ goodbye: Goodbye, within: TimeInterval) {
        let group = DispatchGroup()
        group.enter()
        queue.async { [self] in
            let data = StreamMessage(kind: .goodbye, timestamp: Date().timeIntervalSince1970, isKeyframe: false,
                                     payload: Wire.encode(goodbye)).serialized()
            for client in clients.values where client.connection.state == .ready {
                group.enter()
                client.connection.send(content: data, completion: .contentProcessed { _ in group.leave() })
            }
            group.leave()
        }
        _ = group.wait(timeout: .now() + within)
    }

    // MARK: The device gate (DeviceGate)
    //
    // With the floor above "0", a ready session is held unregistered (no broadcast, tick, catalog,
    // device row, "Client connected" line or count) while its first message is read: a hello the
    // floor admits is served (`admit`); anything else is refused with the update goodbye and
    // closed, never registered, so neither "Client connected" nor "Client left" is printed for it.
    // One gate for every door: a TLS door's Door runs it once the key is admitted (the hello is the
    // first message inside TLS, and never comes on a pairing connection), the plain home door at
    // `.ready`; the refusals, their lines and the loop slowdown are counted per source across both.

    /// Each source's refusals within the last `DeviceGate.loopWindow` (the loop slowdown), and the
    /// sources whose Refused line was printed within the last minute, with how many more came since.
    /// On `queue`.
    private var gateRefusals: [String: [CFAbsoluteTime]] = [:]
    private var gateLog: [String: Int] = [:]

    /// The floor at "0" (every build that ships so far): `admit(nil)` at once, as always, and nothing
    /// is read ahead. Above it: reads `c`'s first message, within `DeviceGate.firstMessageDeadline`
    /// of now (`.ready`, or a TLS door's admission): a hello the floor admits calls `admit` with it;
    /// a lower version, a hello that does not decode, any other kind first, the end of the
    /// connection or nothing in time is refused (`refuse`), and `admit` is never called. On `queue`.
    func gate(_ c: NWConnection, admit: @escaping (Hello?) -> Void) {
        guard deviceFloor != .zero else { admit(nil); return }
        var decided = false          // on `queue`, like every closure here
        let refuse = { [weak self] (hello: Hello?) in
            guard let self, !decided else { return }
            decided = true
            self.refuse(c, hello: hello)
        }
        let deadline = DispatchWorkItem { refuse(nil) }
        queue.asyncAfter(deadline: .now() + DeviceGate.firstMessageDeadline, execute: deadline)
        c.receive(minimumIncompleteLength: StreamMessage.headerLength, maximumLength: StreamMessage.headerLength) { [weak self] data, _, _, _ in
            guard let self, !decided else { return }
            // An older device's viewport, pick or ping, a header no Sill sends, or the end: refused
            // at once, its payload unread.
            guard let data, let header = StreamMessage.parseHeader(data), header.kind == .hello,
                  header.payloadLength <= StreamMessage.maxClientPayload else {
                deadline.cancel()
                refuse(nil)
                return
            }
            let judge = { (payload: Data) in
                guard !decided else { return }
                deadline.cancel()
                let hello = Wire.decode(Hello.self, from: payload)
                if let hello, DeviceGate.admits(hello, floor: self.deviceFloor) {
                    decided = true
                    admit(hello)
                } else {
                    refuse(hello)
                }
            }
            if header.payloadLength == 0 { judge(Data()); return }
            c.receive(minimumIncompleteLength: header.payloadLength, maximumLength: header.payloadLength) { data, _, _, _ in
                guard let data, data.count == header.payloadLength else {
                    deadline.cancel()
                    refuse(nil)
                    return
                }
                judge(data)
            }
        }
    }

    /// A device the gate did not admit: the update goodbye (or SILL_TEST_GOODBYE's payload), then
    /// the close (`closeWithGoodbye`); one Refused line per source a minute, the rest counted. A
    /// source refused `DeviceGate.loopRefusals` times within the window hears it
    /// `DeviceGate.loopDelay` later. On `queue`.
    private func refuse(_ c: NWConnection, hello: Hello?) {
        let source: String
        if case .hostPort(let host, _) = c.endpoint { source = Self.addressText(host).text } else { source = "\(c.endpoint)" }
        let now = CFAbsoluteTimeGetCurrent()
        if gateRefusals.count > 256 { gateRefusals = gateRefusals.filter { $0.value.contains { now - $0 < DeviceGate.loopWindow } } }
        var times = (gateRefusals[source] ?? []).filter { now - $0 < DeviceGate.loopWindow }
        let slowed = DeviceGate.slows(refusedInWindow: times.count)
        times.append(now)
        gateRefusals[source] = times
        logRefusal(DeviceGate.refusedLine(hello, endpoint: "\(c.endpoint)", floor: deviceFloor), source: source)
        let payload = testGoodbye ?? Wire.encode(DeviceGate.refusal(hello, floor: deviceFloor, macName: macName))
        let queue = queue
        if slowed {
            queue.asyncAfter(deadline: .now() + DeviceGate.loopDelay) { Self.closeWithGoodbye(payload, on: c, queue: queue) }
        } else {
            Self.closeWithGoodbye(payload, on: c, queue: queue)
        }
    }

    /// The goodbye and close of a connection that was never registered, so nothing else sends to
    /// it: the gate's refusals, a session the gate held and its Door then refused (DoorPolicy's
    /// `afterGate`), and a TLS door's goodbyes at `.ready` (Remote Access off, the session limit).
    /// The message, then this side's end (FIN; over TLS its close_notify first), then whatever the
    /// device still sends read and dropped until it closes too (at most `DeviceGate.closeWait`),
    /// then the connection cancelled. Cancelling at once, with what the device sent still unread,
    /// makes TCP answer with a reset, which can reach the device before it has read the goodbye
    /// (sillclient, sending on after its hello, got the goodbye and then ECONNRESET), and a device
    /// from 2026-09-25 on sends its hello as soon as its connection is ready; a device that loses
    /// the goodbye reads the reset instead and redials. On `queue`.
    static func closeWithGoodbye(_ goodbye: Goodbye, on c: NWConnection, queue: DispatchQueue) {
        closeWithGoodbye(Wire.encode(goodbye), on: c, queue: queue)
    }

    /// The same with this kind 22 payload (the gate's refusal, or SILL_TEST_GOODBYE's). On `queue`.
    private static func closeWithGoodbye(_ payload: Data, on c: NWConnection, queue: DispatchQueue) {
        let data = StreamMessage(kind: .goodbye, timestamp: Date().timeIntervalSince1970, isKeyframe: false,
                                 payload: payload).serialized()
        c.send(content: data, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in })
        func drain() {
            c.receive(minimumIncompleteLength: 1, maximumLength: 65536) { _, _, isComplete, error in
                if isComplete || error != nil { c.cancel(); return }
                drain()
            }
        }
        drain()
        queue.asyncAfter(deadline: .now() + DeviceGate.closeWait) { c.cancel() }
    }

    /// The first refusal of a source in a minute prints its line; the rest of that minute's are
    /// counted and printed in one line when it is up, and so on while they keep coming. On `queue`.
    private func logRefusal(_ line: String, source: String) {
        if let n = gateLog[source] {
            gateLog[source] = n + 1
            return
        }
        print(line)
        gateLog[source] = 0
        armRefusalLog(source)
    }

    private func armRefusalLog(_ source: String) {
        queue.asyncAfter(deadline: .now() + RefusalSummary.interval) { [weak self] in
            guard let self, let n = self.gateLog[source] else { return }
            guard n > 0 else { self.gateLog[source] = nil; return }
            print(DeviceGate.countLine(n, source: source, floor: self.deviceFloor))
            self.gateLog[source] = 0
            self.armRefusalLog(source)
        }
    }

    /// A device's hello, the first of its connection (after the gate, or in the receive loop): its
    /// name for the log until its stats name it, one line, and the callback. It never refuses: with
    /// the floor at "0" every device is served, and above it the gate has judged it already. On
    /// `queue`.
    private func took(_ hello: Hello, from client: Client) {
        client.helloSeen = true
        let c = client.connection
        let name = SafeText.label(hello.device ?? "")
        if client.device == nil, !name.isEmpty { client.device = name }
        print(DeviceGate.helloLine(hello, endpoint: "\(c.endpoint)"))
        onClientHello?(c, hello)
    }

    // MARK: The sweep: each device's link, and remote clients' silence and slow uplink
    //
    // Once a second while any client is registered, each client's second is closed into its link
    // judge (LinkJudge; every client, at home too: the home branch only counts), and a change is
    // reported (`onClientLinkChanged`).
    //
    // A home client that stops draining for 4 s is gone (8 s grace after connecting). A remote one
    // can legitimately take longer: on a 2 Mbps uplink a 1.5 MB keyframe needs 6 s to hand off. So a
    // remote client is dropped when it has sent nothing for 8 s (it pings every 0.25 s and reports
    // once a second, so silence means it is gone), once 8 s have passed since it was admitted, and
    // the drain backstop gives it 15 s after a 15 s grace. The same sweep asks for the keyframe a
    // remote client waits for once the window has gone still.
    private var sweepTimer: DispatchSourceTimer?
    /// When the sweep last closed the clients' seconds: a client heard since then was heard in it.
    private var lastSweepAt: TimeInterval = 0
    static let remoteSilence: TimeInterval = 8
    static let remoteDeadAfter: TimeInterval = 15
    static let remoteGrace: TimeInterval = 15

    /// On `queue`: a 1 s sweep while any client exists.
    private func updateSweep() {
        let wanted = !clients.isEmpty
        if wanted, sweepTimer == nil {
            lastSweepAt = Date().timeIntervalSince1970
            let t = DispatchSource.makeTimerSource(queue: queue)
            t.schedule(deadline: .now() + 1, repeating: 1, leeway: .milliseconds(100))
            t.setEventHandler { [weak self] in self?.sweep() }
            t.resume()
            sweepTimer = t
        } else if !wanted, let t = sweepTimer {
            t.cancel(); sweepTimer = nil
        }
    }

    private func sweep() {
        let now = Date().timeIntervalSince1970
        let since = lastSweepAt
        lastSweepAt = now
        var waiting: [Client] = []
        for client in clients.values {
            let second = LinkJudge.Second(sent: client.sentThisSecond, withheld: client.withheldThisSecond, taken: client.takenThisSecond,
                                          waiting: client.pendingBytes, heard: client.lastHeardAt > since)
            client.sentThisSecond = 0
            client.withheldThisSecond = 0
            client.takenThisSecond = 0
            if let verdict = client.judge.close(second) { onClientLinkChanged?(client.connection, verdict) }
            guard client.route.isRemote else { continue }
            let silent = now - client.lastHeardAt
            if now - client.connectedAt >= Self.remoteSilence, silent > Self.remoteSilence {
                print("Client silent for \(Int(silent)) s, dropping: \(client.connection.endpoint)")
                client.connection.cancel()   // its state handler forgets it
            } else if client.needsKeyframe, client.keyframeWanted, !client.awaitingFirstKeyframe,
                      client.pendingBytes <= Self.remoteIdleBytes, client.connection.state == .ready {
                waiting.append(client)
            }
        }
        // A client that lost a frame asks for its keyframe when a later frame comes (`paceRemote`).
        // Once the window has gone still, none comes, and it would keep the picture from before the
        // drop until the window next changes: the end of a scroll, the last letters typed. So the
        // sweep asks too, on the same terms (its queue idle, the request due); the encoder then
        // encodes the still window's last frame again (HEVCEncoder.requestKeyframe). While frames
        // come, whichever looks first asks, once.
        if !waiting.isEmpty, remoteKeyframeDue(now) {
            lastRemoteKeyframeRequest = now
            for client in waiting { client.keyframeWanted = false }
            onKeyframeNeeded?()
        }
    }

    /// On `queue`: forgets a registered client, once ("Client left" and the callbacks). A
    /// connection that was never registered (refused, or failed before it was ready) leaves no line.
    private func unregister(_ id: ObjectIdentifier) {
        guard let client = clients.removeValue(forKey: id) else { return }
        pointerWatch?.clientLeft(id)
        print("Client left: \(client.connection.endpoint)")
        onClientDisconnected?(client.connection)
        onClientCountChanged?(clients.count)
        updateTicking()
        updateSweep()
    }

    /// The source is changing: forget the old parameter sets and make every client wait for
    /// the next keyframe, so nobody decodes frames of the new window with the old format. Each
    /// client's link keeps its judgement (`resetLinks` is the coordinator's to call).
    func resetForNewStream() {
        queue.async { [self] in
            lastParameterSets = nil
            for client in clients.values {
                client.needsKeyframe = true
                client.awaitingFirstKeyframe = true
            }
        }
    }

    /// The stream runs at another quality, or stopped (LinkJudge.judgedAfresh): each client's link is
    /// judged afresh (LinkJudge.reset), and one that was not fine is reported fine, marked as a
    /// reset. A restart that keeps the quality never calls it. Thread-safe.
    func resetLinks() {
        queue.async { [self] in
            for client in clients.values {
                client.sentThisSecond = 0
                client.withheldThisSecond = 0
                if let verdict = client.judge.reset() { onClientLinkChanged?(client.connection, verdict) }
            }
        }
    }

    /// Each connection its own message (the devices' settings states, kind 16, one per connection):
    /// a registered, ready connection gets its own; any other is skipped without a word, as
    /// `broadcast` skips it, where `send(_:to:)` would print "send: no client for …" (a state can be
    /// built for a connection the server has just forgotten, before the coordinator hears it left).
    /// Thread-safe.
    func send(each messages: [(NWConnection, StreamMessage)]) {
        let items = messages.map { (ObjectIdentifier($0.0), $0.1.serialized()) }
        queue.async { [self] in
            for (id, data) in items {
                guard let client = clients[id], client.connection.state == .ready else { continue }
                send(data, to: client)
            }
        }
    }

    /// One message to one client (catalog on connect). Thread-safe.
    func send(_ message: StreamMessage, to connection: NWConnection) {
        let data = message.serialized()
        queue.async { [self] in
            guard let client = clients[ObjectIdentifier(connection)] else {
                print("send: no client for \(connection.endpoint) (\(clients.count) known)")
                return
            }
            send(data, to: client)
        }
    }

    /// Client → host messages share the same framing. Small and rare, so read them one at a time.
    private func receiveLoop(_ client: Client) {
        let c = client.connection
        c.receive(minimumIncompleteLength: StreamMessage.headerLength, maximumLength: StreamMessage.headerLength) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            guard let data, let header = StreamMessage.parseHeader(data) else {
                // EOF or a read error: the client closed (or was killed). Nothing else would notice
                // while no frames are being sent, so cancel here; the state handler prints and forgets it.
                if isComplete || error != nil { c.cancel() }
                return
            }
            client.lastHeardAt = Date().timeIntervalSince1970
            // A header can announce up to 4 GiB and the read below would wait for all of it. No
            // client message comes near a megabyte, so a bigger one is a broken or hostile peer.
            if header.payloadLength > StreamMessage.maxClientPayload {
                print("Closing \(c.endpoint): it announced a \(header.payloadLength)-byte message (the limit is 1 MB).")
                c.cancel()
                return
            }
            let deliver = { (payload: Data) in
                if header.kind == .input {
                    self.lastInputAt = Date().timeIntervalSince1970
                    if self.tickTimer == nil { self.updateTicking() }
                    // This device moves the Mac's pointer now. The count and the controller change
                    // in the same queue turn as every sample, so no kind 26 carries the new count
                    // with the old controller (docs/pointer-visibility-plan.md §3.3).
                    client.inputsRead += 1
                    self.pointerWatch?.inputArrived(from: ObjectIdentifier(c), movesPointer: PointerControl.movesPointer(payload: payload))
                }
                if header.kind == .ping {
                    // Echo straight back from the network queue: the round trip should measure the
                    // network and nothing else.
                    self.send(StreamMessage(kind: .pong, timestamp: header.timestamp, isKeyframe: false, payload: payload).serialized(), to: client)
                } else if header.kind == .clientStats {
                    // What the device sees, printed here so the latency number is in the Mac's log.
                    // The client reports every second; every other report (~2 s) is enough. The gate
                    // is 1.5 s, not 2, so arrival jitter on a 1 s cadence cannot stretch it to 3 s.
                    // A skipped report's maxima still reach the next line.
                    // Every report goes to `onClientStats` (the app's menu shows it live).
                    if let stats = Wire.decode(ClientStats.self, from: payload) {
                        // The device names itself: one clean line of at most 64 characters, never
                        // its raw text (a newline would forge a log line).
                        let name = SafeText.label(stats.device)
                        client.device = name.isEmpty ? nil : name
                        client.worstFrameAgeSincePrint = max(client.worstFrameAgeSincePrint, stats.frameAgeMaxMs ?? -1)
                        client.worstRttSincePrint = max(client.worstRttSincePrint, stats.rttMaxMs ?? -1)
                        let now = CFAbsoluteTimeGetCurrent()
                        if now - client.lastStatsPrint >= 1.5 {
                            client.lastStatsPrint = now
                            let age = Self.medianAndWorst(stats.frameAgeMs, worst: stats.frameAgeMaxMs.map { _ in client.worstFrameAgeSincePrint })
                            let rtt = Self.medianAndWorst(stats.rttMs, worst: stats.rttMaxMs.map { _ in client.worstRttSincePrint })
                            print("client \(client.device ?? "\(c.endpoint)"): \(stats.fps) fps, frame age \(age), rtt \(rtt)")
                            client.worstFrameAgeSincePrint = -1
                            client.worstRttSincePrint = -1
                        }
                        self.onClientStats?(c, stats)
                    }
                } else if header.kind == .hello {
                    // The device's hello: the first of this connection counts, a second is skipped
                    // without a line. Never a refusal here (see `took`).
                    if !client.helloSeen {
                        client.helloSeen = true
                        if let hello = Wire.decode(Hello.self, from: payload) { self.took(hello, from: client) }
                    }
                } else if header.kind == .pairingWanted {
                    // "Show your pairing code" came from a device near the Mac. This host has no
                    // home door, so it is ignored.
                } else {
                    self.onMessage?(StreamMessage(kind: header.kind, timestamp: header.timestamp, isKeyframe: header.isKeyframe, payload: payload), c)
                }
                self.receiveLoop(client)
            }
            if header.payloadLength == 0 { deliver(Data()); return }
            c.receive(minimumIncompleteLength: header.payloadLength, maximumLength: header.payloadLength) { data, _, isComplete, error in
                guard let data else {
                    if isComplete || error != nil { c.cancel() }
                    return
                }
                deliver(data)
            }
        }
    }

    /// One number of a client stats line. A current client reports each second's median and max:
    /// "7/80 ms" is the last second's median over the worst since the previous line, "–" a second
    /// without a sample (no frame arrived, no pong came back), "–/80 ms" such a second after one
    /// that had samples. An older client sends one sample and no max (`worst` nil): "7 ms", as the
    /// line always read.
    private static func medianAndWorst(_ median: Int, worst: Int?) -> String {
        guard let worst else { return "\(median) ms" }
        if median < 0 { return worst < 0 ? "–" : "–/\(worst) ms" }
        return "\(median)/\(max(worst, median)) ms"
    }

    /// Thread-safe: hops onto the network queue.
    func broadcast(_ message: StreamMessage) {
        let data = message.serialized()
        queue.async { [self] in
            if message.kind == .parameterSets { lastParameterSets = data }
            if message.kind == .frame, message.isKeyframe { lastKeyframeAt = Date().timeIntervalSince1970 }
            var wantKeyframe = false
            defer { if wantKeyframe { onKeyframeNeeded?() } }
            for client in clients.values where client.connection.state == .ready {
                if message.kind == .frame, client.route.isRemote {
                    if paceRemote(client, message: message, data: data) { wantKeyframe = true }
                    continue
                }
                if message.kind == .frame {
                    // Its link only counts here (LinkJudge): what it sends and drops is as ever.
                    if client.needsKeyframe {
                        guard message.isKeyframe, let ps = lastParameterSets else {
                            Stats.shared.bump("net.waitKey")
                            if !client.awaitingFirstKeyframe { client.withheldThisSecond += 1 }
                            continue
                        }
                        send(ps, to: client)
                        client.needsKeyframe = false
                        client.awaitingFirstKeyframe = false
                    } else if client.inflight > 2 && !message.isKeyframe {
                        // Drop the delta. Every later delta references it, so this client now waits for
                        // a keyframe (sending deltas anyway is what showed up as flicker on the iPad).
                        Stats.shared.bump("net.dropped")
                        client.withheldThisSecond += 1
                        client.needsKeyframe = true
                        wantKeyframe = true
                        continue
                    }
                    Stats.shared.bump("net.sent")
                    client.sentThisSecond += 1
                }
                send(data, to: client, isFrame: message.kind == .frame)
            }
        }
    }

    /// Remote clients' frames (home clients keep the rule above byte for byte). What is queued is
    /// counted in bytes the connection has not taken yet (`pendingBytes`), never in messages
    /// (docs/remote-bundle-plan.md §3):
    /// - Behind a keyframe the connection is still taking, frames go out up to `remoteHoldCap`:
    ///   every delta references that keyframe, so dropping them for its sake wasted it and looped
    ///   (drop, a keyframe 2 s later, the next delta dropped behind it: 2026-09-25, 0–3 fps and
    ///   rtt up to 12 s at 150 Mbps on a phone's hotspot). What counts against the cap is what
    ///   waits beyond every keyframe still being taken: a restarted stream's first keyframe goes
    ///   out at once, behind the old stream's if that one is still crossing, and its deltas
    ///   reference it alone.
    /// - Otherwise a frame is dropped only when the backlog exceeds both `remoteBacklogBudget` and
    ///   what the last keyframe left behind it (`backlogFloor`, following the backlog down) plus
    ///   `remoteBacklogSlack`: a backlog that shrinks is a link catching up, one that grows is a
    ///   stream the link cannot carry.
    /// - A client that lost a frame asks for a keyframe only once the connection has taken
    ///   everything but control messages (`remoteIdleBytes`), so the keyframe leads the queue
    ///   instead of queueing behind the backlog that caused the drop; at most every
    ///   `remoteKeyframeSpacing` for all remote clients together (later beside a home client:
    ///   `remoteKeyframeDue`). It asks when a later frame comes, or, once the window has gone
    ///   still and none does, at the sweep (`sweep`).
    /// - The keyframe it waits for goes out when the backlog fits the budget, or at once when it
    ///   has had none since it was admitted or the stream changed (the first keyframe).
    /// Returns whether to ask for one now. On `queue`. No new Stats key: skipped frames count as
    /// net.waitKey, dropped ones as net.dropped, sent ones as net.sent.
    private func paceRemote(_ client: Client, message: StreamMessage, data: Data) -> Bool {
        var ask = false
        client.backlogFloor = min(client.backlogFloor, client.pendingBytes)
        if client.needsKeyframe {
            guard message.isKeyframe else {
                Stats.shared.bump("net.waitKey")
                if !client.awaitingFirstKeyframe { client.withheldThisSecond += 1 }
                let now = Date().timeIntervalSince1970
                if client.keyframeWanted, client.pendingBytes <= Self.remoteIdleBytes, remoteKeyframeDue(now) {
                    lastRemoteKeyframeRequest = now
                    client.keyframeWanted = false
                    ask = true
                }
                return ask
            }
            guard client.awaitingFirstKeyframe || client.pendingBytes <= Self.remoteBacklogBudget, let ps = lastParameterSets else {
                // Its queue is still full: this keyframe is lost to it too. Ask again once it has
                // drained (within the spacing) rather than wait for the encoder's own periodic one.
                Stats.shared.bump("net.waitKey")
                client.withheldThisSecond += 1
                client.keyframeWanted = true
                return false
            }
            send(ps, to: client)
            client.needsKeyframe = false
            client.awaitingFirstKeyframe = false
        } else {
            let tooMuch: Bool
            if !client.keyframesInFlight.isEmpty {
                tooMuch = client.pendingBytes - client.keyframeBytesInFlight > Self.remoteHoldCap
            } else {
                tooMuch = client.pendingBytes > max(Self.remoteBacklogBudget, client.backlogFloor + Self.remoteBacklogSlack)
            }
            if tooMuch {
                Stats.shared.bump("net.dropped")
                client.withheldThisSecond += 1
                client.needsKeyframe = true
                client.keyframeWanted = true
                return false
            }
        }
        Stats.shared.bump("net.sent")
        client.sentThisSecond += 1
        send(data, to: client, isFrame: true, isKeyframe: message.isKeyframe)
        return false
    }

    /// A remote client's backlog that never drops a frame: about a quarter second at 8 Mbps, 30
    /// frames of the Low preset.
    static let remoteBacklogBudget = 256 * 1024
    /// Growth over what a keyframe left behind that still counts as noise (a thumbnail pass is 11
    /// small JPEGs).
    static let remoteBacklogSlack = 128 * 1024
    /// How much may queue behind a keyframe the connection is still taking: about a second of the
    /// Low preset's deltas (60 × ~8 KB), what piles up while a large keyframe is taken on a hotspot;
    /// past it the stream is more than the link carries.
    static let remoteHoldCap = 512 * 1024
    /// A queue this short holds nothing but control messages (pongs, a settings reply): a
    /// keyframe asked for now leads it.
    static let remoteIdleBytes = 16 * 1024

    /// When a keyframe was last asked for on behalf of a remote client.
    private var lastRemoteKeyframeRequest: TimeInterval = 0
    /// When the last keyframe went out, of any kind (the encoder's own, or one asked for).
    private var lastKeyframeAt: TimeInterval = 0
    static let remoteKeyframeSpacing: TimeInterval = 2
    /// The encoder's own keyframe interval: HEVCEncoder's `fps * 4` frames.
    static let remoteKeyframeSpacingBesideHome: TimeInterval = 4

    /// Whether a keyframe may be asked for on a remote client's behalf now: alone, 2 s after the
    /// last such request. It is encoded once and goes to every client, though, so while a home
    /// client is connected the request also waits until 4 s have passed since the last keyframe of
    /// any kind. The encoder's own is due by then, so a slow remote link gives a device on the LAN
    /// no more keyframes than the encoder's interval would, where each one showed as a 50–100 ms
    /// hitch (the trackpad stutter's cause 2); it only brings one forward when frames come slower
    /// than the stream's rate. The remote device waits longer after a drop in exchange. On `queue`.
    private func remoteKeyframeDue(_ now: TimeInterval) -> Bool {
        guard clients.values.contains(where: { !$0.route.isRemote }) else {
            return now - lastRemoteKeyframeRequest >= Self.remoteKeyframeSpacing
        }
        return now - lastRemoteKeyframeRequest >= Self.remoteKeyframeSpacingBesideHome
            && now - lastKeyframeAt >= Self.remoteKeyframeSpacingBesideHome
    }

    /// A peer that has not drained a single video frame for this long stopped reading (app killed,
    /// device asleep). Time-based rather than a frame count: a slow decoder (the simulator at full
    /// Retina) or the connect burst can hold many frames unacked and still be alive.
    private static let deadAfter: TimeInterval = 4.0
    /// No eviction while the connect burst (catalog + first keyframe) is still draining.
    private static let graceAfterConnect: TimeInterval = 8.0

    private func send(_ data: Data, to client: Client, isFrame: Bool = false, isKeyframe: Bool = false) {
        let now = Date().timeIntervalSince1970
        let remote = client.route.isRemote
        if isFrame, let oldest = client.oldestUnackedFrameAt,
           now - oldest > (remote ? Self.remoteDeadAfter : Self.deadAfter),
           now - client.connectedAt > (remote ? Self.remoteGrace : Self.graceAfterConnect) {
            print("Client not draining for \(Int(now - oldest)) s, dropping: \(client.connection.endpoint)")
            client.connection.cancel()   // its state handler removes it from `clients`
            return
        }
        client.inflight += 1
        client.lastSentAt = now
        client.pendingBytes += data.count
        var keyframeSeq: Int?
        if remote {
            if isKeyframe {
                client.keyframeSeq += 1
                keyframeSeq = client.keyframeSeq
                client.keyframesInFlight.append((client.keyframeSeq, data.count))
                client.keyframeBytesInFlight += data.count
            }
        }
        if isFrame {
            client.inflightFrames += 1
            if client.oldestUnackedFrameAt == nil { client.oldestUnackedFrameAt = now }
        }
        client.connection.send(content: data, completion: .contentProcessed { [weak client] _ in
            guard let client else { return }
            client.inflight -= 1
            client.pendingBytes -= data.count
            client.takenThisSecond += data.count
            if remote {
                if let seq = keyframeSeq, let i = client.keyframesInFlight.firstIndex(where: { $0.seq == seq }) {
                    client.keyframeBytesInFlight -= client.keyframesInFlight.remove(at: i).bytes
                    // The last of them taken: what they left behind them.
                    if client.keyframesInFlight.isEmpty { client.backlogFloor = client.pendingBytes }
                }
            }
            if isFrame {
                client.inflightFrames -= 1
                if client.inflightFrames <= 0 {
                    client.inflightFrames = 0; client.oldestUnackedFrameAt = nil
                } else {
                    // Progress: a slow but live peer on a saturated link never drains to zero.
                    client.oldestUnackedFrameAt = Date().timeIntervalSince1970
                }
            }
        })
    }
}

/// How the remote door admitted a session: from where (OriginPolicy's origin), its card's label
/// ("through Tailscale"), and the paired key with its name. This host has no other door.
enum ClientRoute: Equatable {
    case remote(origin: OriginPolicy.Origin, label: String, fingerprint: Data, name: String)

    /// Always true: every session comes through the remote door. Kept so that the pacing and the
    /// away rules read as they do upstream.
    var isRemote: Bool { true }
    var origin: OriginPolicy.Origin { if case .remote(let o, _, _, _) = self { return o }; return .internet }
    /// The label the Mac's card shows.
    var label: String? { if case .remote(_, let l, _, _) = self { return l }; return nil }
    /// The peer's key.
    var fingerprint: Data? { if case .remote(_, _, let f, _) = self { return f }; return nil }
    /// The paired name.
    var pairedName: String? { if case .remote(_, _, _, let n) = self { return n }; return nil }
    /// Every session is TLS.
    var encrypted: Bool { true }
}
