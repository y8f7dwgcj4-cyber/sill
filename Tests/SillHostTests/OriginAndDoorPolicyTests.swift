import XCTest
import StreamProtocol
@testable import SillHostCore

/// Who the door admits: only Tailscale sources on a tunnel, and only paired keys for a session.
final class OriginAndDoorPolicyTests: XCTestCase {
    private func b(_ s: String) -> [UInt8] { IPBytes.parse(s)! }
    private let all: [OriginPolicy.Origin] = [.loopback, .direct, .vpn, .lan, .internet]

    func testOnlyATunnelArrivalIsAdmitted() {
        XCTAssertEqual(all.filter(OriginPolicy.remoteAdmits), [.vpn])
    }

    func testTailnetRule() {
        XCTAssertTrue(OriginPolicy.tailnetAdmits(.vpn, source: b("100.101.102.103")))
        XCTAssertTrue(OriginPolicy.tailnetAdmits(.vpn, source: b("fd7a:115c:a1e0::1")))
        XCTAssertTrue(OriginPolicy.tailnetAdmits(.vpn, source: b("::ffff:100.64.0.1")), "an IPv4-mapped Tailscale source")
        XCTAssertFalse(OriginPolicy.tailnetAdmits(.vpn, source: b("10.8.0.6")), "another VPN")
        XCTAssertFalse(OriginPolicy.tailnetAdmits(.vpn, source: b("100.100.100.100")))
        XCTAssertFalse(OriginPolicy.tailnetAdmits(.vpn, source: nil))
        for o in all where o != .vpn {
            XCTAssertFalse(OriginPolicy.tailnetAdmits(o, source: b("100.101.102.103")), "\(o)")
        }
    }

    func testRefusalBeforeStart() {
        XCTAssertNil(DoorPolicy.refusalBeforeStart(origin: .vpn, source: b("100.101.102.103")))
        XCTAssertEqual(DoorPolicy.refusalBeforeStart(origin: .lan, source: b("192.168.1.9")), "outside")
        XCTAssertEqual(DoorPolicy.refusalBeforeStart(origin: .loopback, source: b("127.0.0.1")), "outside")
        XCTAssertEqual(DoorPolicy.refusalBeforeStart(origin: .internet, source: b("203.0.113.9")), "outside")
    }

    func testVerifyBlock() {
        let paired = DoorPolicy.Trust(hasKey: true, paired: true, remoteAccess: true, pairingOpen: false)
        let stranger = DoorPolicy.Trust(hasKey: true, paired: false, remoteAccess: true, pairingOpen: false)
        let strangerWindow = DoorPolicy.Trust(hasKey: true, paired: false, remoteAccess: true, pairingOpen: true)
        let noKey = DoorPolicy.Trust(hasKey: false, paired: true, remoteAccess: true, pairingOpen: true)
        XCTAssertTrue(DoorPolicy.trusts(alpn: RemoteTLS.sessionALPN, paired))
        XCTAssertFalse(DoorPolicy.trusts(alpn: RemoteTLS.sessionALPN, stranger))
        XCTAssertFalse(DoorPolicy.trusts(alpn: RemoteTLS.pairingALPN, stranger))
        XCTAssertTrue(DoorPolicy.trusts(alpn: RemoteTLS.pairingALPN, strangerWindow))
        XCTAssertFalse(DoorPolicy.trusts(alpn: RemoteTLS.sessionALPN, noKey))
        XCTAssertFalse(DoorPolicy.trusts(alpn: "h2", paired))
        XCTAssertFalse(DoorPolicy.trusts(alpn: nil, paired))
    }

    func testAtReady() {
        let on = DoorPolicy.Trust(hasKey: true, paired: true, remoteAccess: true, pairingOpen: false)
        var off = on; off.remoteAccess = false
        XCTAssertEqual(DoorPolicy.atReady(alpn: RemoteTLS.sessionALPN, on, remoteSessions: 0), .session)
        XCTAssertEqual(DoorPolicy.atReady(alpn: RemoteTLS.sessionALPN, off, remoteSessions: 0), .goodbye(Goodbye.remoteOff))
        XCTAssertEqual(DoorPolicy.atReady(alpn: RemoteTLS.sessionALPN, on, remoteSessions: DoorPolicy.maxRemoteSessions),
                       .goodbye(Goodbye.busy))
        XCTAssertEqual(DoorPolicy.atReady(alpn: RemoteTLS.pairingALPN, on, remoteSessions: 0), .refuse("unpaired"))
    }

    func testAfterGate() {
        let on = DoorPolicy.Trust(hasKey: true, paired: true, remoteAccess: true, pairingOpen: false)
        XCTAssertNil(DoorPolicy.afterGate(origin: .vpn, on, remoteSessions: 0))
        var removed = on; removed.paired = false
        XCTAssertEqual(DoorPolicy.afterGate(origin: .vpn, removed, remoteSessions: 0), Goodbye.removed)
        var off = on; off.remoteAccess = false
        XCTAssertEqual(DoorPolicy.afterGate(origin: .vpn, off, remoteSessions: 0), Goodbye.remoteOff)
        XCTAssertEqual(DoorPolicy.afterGate(origin: .lan, on, remoteSessions: 0), Goodbye.removed)
        XCTAssertEqual(DoorPolicy.afterGate(origin: .vpn, on, remoteSessions: DoorPolicy.maxRemoteSessions), Goodbye.busy)
    }

    func testPairingMethods() {
        XCTAssertEqual(DoorPolicy.pairing(method: PairRequest.qr, version: PairRequest.version), .window)
        XCTAssertEqual(DoorPolicy.pairing(method: PairRequest.code, version: PairRequest.version), .window)
        XCTAssertEqual(DoorPolicy.pairing(method: PairRequest.ask, version: PairRequest.version), .closed)
        XCTAssertEqual(DoorPolicy.pairing(method: PairRequest.cancel, version: PairRequest.version), .closed)
        XCTAssertEqual(DoorPolicy.pairing(method: PairRequest.qr, version: PairRequest.version + 1), .closed)
    }

    func testHandshakeRefusals() {
        for status: Int32 in [-9808, -9863, -9810, -9836, -9858] {
            XCTAssertEqual(DoorPolicy.handshakeRefusal(status: status), "unpaired")
        }
        XCTAssertNil(DoorPolicy.handshakeRefusal(status: -9816))
    }

    func testTestHosts() {
        XCTAssertTrue(DoorPolicy.isTestHost(synthetic: true, bundled: false))
        XCTAssertFalse(DoorPolicy.isTestHost(synthetic: true, bundled: true))
        XCTAssertFalse(DoorPolicy.isTestHost(synthetic: false, bundled: false))
    }
}
