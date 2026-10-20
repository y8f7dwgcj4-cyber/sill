import Network
import XCTest
@testable import SillHostCore

/// The bind's pure parts: which interface holds the address, the endpoint, and the backoff.
final class TailnetBindTests: XCTestCase {
    private func entry(_ name: String, _ address: [UInt8], up: Bool = true, p2p: Bool = false) -> InterfaceSnapshot.Entry {
        InterfaceSnapshot.Entry(name: name, address: address, prefixBits: 32, up: up, pointToPoint: p2p, loopback: name.hasPrefix("lo"))
    }

    func testBackoff() {
        XCTAssertEqual((0..<9).map(TailnetBind.retryDelay(failures:)), [2, 4, 8, 16, 32, 60, 60, 60, 60])
        XCTAssertEqual(TailnetBind.retryDelay(failures: -1), 2)
    }

    func testOwnerIsAnUpTunnel() {
        let a: [UInt8] = [100, 64, 0, 9]
        XCTAssertEqual(TailnetBind.owner(of: a, in: [entry("en0", [192, 168, 1, 2]), entry("utun4", a, p2p: true)]), "utun4")
        XCTAssertNil(TailnetBind.owner(of: a, in: [entry("utun4", a, up: false, p2p: true)]), "a down interface holds nothing")
        XCTAssertNil(TailnetBind.owner(of: a, in: [entry("en0", a)]), "an address on a LAN interface is not Tailscale's")
        XCTAssertNil(TailnetBind.owner(of: a, in: [entry("lo0", a)]))
        XCTAssertNil(TailnetBind.owner(of: a, in: []))
    }

    func testTargetTakesTheFilePortFirst() throws {
        let withPort = try TailnetConfig.parse("address = 100.64.0.9\nport = 7460").get()
        let without = try TailnetConfig.parse("address = 100.64.0.9").get()
        XCTAssertEqual(TailnetBind.Target(withPort, port: 7455).port, 7460)
        XCTAssertEqual(TailnetBind.Target(without, port: 7455).port, 7455)
        XCTAssertEqual(TailnetBind.Target(without, port: 0).port, 0)
    }

    func testEndpoint() throws {
        let v4 = TailnetBind.Target(try TailnetConfig.parse("address = 100.64.0.9").get(), port: 7455)
        XCTAssertEqual(TailnetBind.endpoint(v4), .hostPort(host: .ipv4(IPv4Address("100.64.0.9")!), port: 7455))
        let v6 = TailnetBind.Target(try TailnetConfig.parse("address = fd7a:115c:a1e0::1").get(), port: 7460)
        XCTAssertEqual(TailnetBind.endpoint(v6), .hostPort(host: .ipv6(IPv6Address("fd7a:115c:a1e0::1")!), port: 7460))
    }
}
