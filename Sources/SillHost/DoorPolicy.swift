import Foundation
import StreamProtocol

/// Who the remote door admits, in one place. The remote door is this host's only door: it listens
/// on the configured Tailscale address, and the Door that runs its admission asks these rules.
///
/// Pure (Foundation, OriginPolicy's origins, StreamProtocol's wire values), so it is checked on its
/// own. Nothing here reads a clock, the network or the main actor: the verify block and admission
/// call it on the network queue with what the lock-protected TrustSnapshot says.
enum DoorPolicy {
    /// The remote door's sessions at once; the ninth gets goodbye `busy`.
    static let maxRemoteSessions = 8

    /// What admission knows about one connection: its key, and the Mac's switches as the
    /// TrustSnapshot has them.
    struct Trust: Equatable, Sendable {
        /// The peer presented a P-256 key (it has a fingerprint). A peer without one is trusted
        /// by nothing: no pin matches it, and a session must be named and removable by its key.
        var hasKey = true
        /// The peer's key is in the trust list.
        var paired = false
        var remoteAccess = false
        /// A pairing window that the Mac's user opened is open: the door takes its proofs.
        var pairingOpen = false
    }

    // MARK: Before the connection starts

    /// The word for the minute's summary for a connection refused before it started; nil when its
    /// origin and source are ones the door admits (OriginPolicy.tailnetAdmits).
    static func refusalBeforeStart(origin: OriginPolicy.Origin, source: [UInt8]?) -> String? {
        OriginPolicy.tailnetAdmits(origin, source: source) ? nil : "outside"
    }

    // MARK: The verify block

    /// The TLS handshake's verify block: trust is the key and the application protocol, nothing
    /// else. `sill/1` for a paired key, `sill-pair/1` only while a pairing window is open, anything
    /// else never.
    static func trusts(alpn: String?, _ t: Trust) -> Bool {
        guard t.hasKey else { return false }
        switch alpn {
        case RemoteTLS.sessionALPN?: return t.paired
        case RemoteTLS.pairingALPN?: return t.pairingOpen
        default: return false
        }
    }

    // MARK: At `.ready`

    enum AtReady: Equatable, Sendable {
        /// A session: registered with its route.
        case session
        /// A pairing connection: read exactly one kind 19 (at most 4 KiB, within the admission
        /// deadline), then treat it as `pairing(method:version:)` says.
        case pairing
        /// A paired key the door does not serve now: this goodbye ("remoteOff", "busy"), then close.
        case goodbye(String)
        /// Cancelled with no Sill byte, counted under this word in the minute's summary ("unpaired").
        case refuse(String)
    }

    /// What `.ready` does with a connection the verify block let through, judged again against the
    /// switches as they are now: an unpaired key is refused, a paired one gets goodbye `remoteOff`
    /// while Remote Access is off and `busy` at `maxRemoteSessions`, and `sill-pair/1` is read only
    /// while a pairing window is open.
    static func atReady(alpn: String?, _ t: Trust, remoteSessions: Int) -> AtReady {
        guard t.hasKey else { return .refuse("unpaired") }
        switch alpn {
        case RemoteTLS.sessionALPN?:
            guard t.paired else { return .refuse("unpaired") }
            guard t.remoteAccess else { return .goodbye(Goodbye.remoteOff) }
            guard remoteSessions < maxRemoteSessions else { return .goodbye(Goodbye.busy) }
            return .session
        case RemoteTLS.pairingALPN?:
            return t.pairingOpen ? .pairing : .refuse("unpaired")
        default:
            return .refuse("unpaired")
        }
    }

    // MARK: After the device gate

    /// A session the device gate held (the floor above "0": up to 2 s while it reads the hello) is
    /// neither pending nor a client meanwhile, so a change that closes sessions (Remove, Remote
    /// Access off) could not reach it. Judged again as the gate admits it, from the switches as
    /// they are then: the goodbye that change sends its sessions, or nil to admit it. In the order
    /// its changes are checked: "removed", "remoteOff", "busy" at `maxRemoteSessions`. An origin the
    /// door no longer admits gets "removed" too: it cannot happen while the bind address stays the
    /// same, and no other reason means "go away" to a device of this generation.
    static func afterGate(origin: OriginPolicy.Origin, _ t: Trust, remoteSessions: Int) -> String? {
        if !t.hasKey || !t.paired { return Goodbye.removed }
        if !t.remoteAccess { return Goodbye.remoteOff }
        if !OriginPolicy.remoteAdmits(origin) { return Goodbye.removed }
        if remoteSessions >= maxRemoteSessions { return Goodbye.busy }
        return nil
    }

    /// How the door treats the one kind 19 of a pairing connection it admitted.
    enum Pairing: Equatable, Sendable {
        /// The pairing window judges its proof: "qr" and "code", and any other method, which the
        /// window counts as a wrong proof.
        case window
        /// Answered `closed` at once with no try counted: an ask or a cancel (the home door's
        /// methods, which this host does not have), and a request of another generation than this
        /// build's (`PairRequest.v` not 1). The window never sees it.
        case closed
    }

    /// `version`: the request's `v`. Any other than `PairRequest.version` is a later generation's
    /// method or proof format, which this host cannot judge: answered `closed` without a try, never
    /// counted as one of the window's five wrong codes (the compatibility floor).
    static func pairing(method: String, version: Int) -> Pairing {
        guard version == PairRequest.version else { return .closed }
        if method == PairRequest.ask || method == PairRequest.cancel { return .closed }
        return .window
    }

    // MARK: A handshake that failed

    /// What a handshake that failed before admission counts as, from the TLS status on the Mac's
    /// side: the verify block refused the key (-9808), no certificate (-9863), an application
    /// protocol the door does not offer (-9810), an HTTP request (-9858), and not TLS 1.3 (-9836).
    /// Each is counted under the word, and one failure toward its source's backoff (5 in 60 s →
    /// refused for 300 s). Nil for a peer that went away by itself (-9816, a reset, -9825 when it
    /// refused the Mac's key): no count at all.
    static func handshakeRefusal(status: Int32) -> String? {
        switch status {
        case -9808, -9863, -9810, -9836, -9858: return "unpaired"
        default: return nil
        }
    }

    // MARK: Test hooks

    /// Which hosts honour the TEST ONLY hooks: a synthetic host that is not a .app's executable.
    /// Any process of this user can start Sill.app's own executable with an environment and
    /// arguments, and it then runs with Sill's Screen Recording and Accessibility grants; the
    /// bundle ignores them.
    static func isTestHost(synthetic: Bool, bundled: Bool) -> Bool { synthetic && !bundled }
}
