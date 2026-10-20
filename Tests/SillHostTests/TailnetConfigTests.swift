import Darwin
import XCTest
@testable import SillHostCore

/// The Tailscale address file: what it takes, and what it refuses.
final class TailnetConfigTests: XCTestCase {
    private func parsed(_ text: String) -> TailnetConfig? { try? TailnetConfig.parse(text).get() }
    private func problem(_ text: String) -> TailnetConfig.Problem? {
        if case .failure(let p) = TailnetConfig.parse(text) { return p }
        return nil
    }

    func testIPv4AddressWithoutPort() {
        let c = parsed("address = 100.101.102.103\n")
        XCTAssertEqual(c?.address, "100.101.102.103")
        XCTAssertEqual(c?.bytes, [100, 101, 102, 103])
        XCTAssertNil(c?.port)
    }

    func testIPv6AddressAndPortAndComments() {
        let c = parsed("# Sill\n  address=fd7a:115c:a1e0::1234   # this Mac\n\nport = 7460\n")
        XCTAssertEqual(c?.address, "fd7a:115c:a1e0::1234")
        XCTAssertEqual(c?.bytes.count, 16)
        XCTAssertEqual(c?.port, 7460)
    }

    func testKeysIgnoreCase() {
        XCTAssertEqual(parsed("ADDRESS = 100.64.0.1")?.address, "100.64.0.1")
    }

    func testRangeEdges() {
        XCTAssertNotNil(parsed("address = 100.64.0.0"))
        XCTAssertNotNil(parsed("address = 100.127.255.255"))
        XCTAssertEqual(problem("address = 100.63.255.255"), .notTailscale("100.63.255.255"))
        XCTAssertEqual(problem("address = 100.128.0.0"), .notTailscale("100.128.0.0"))
        XCTAssertNotNil(parsed("address = fd7a:115c:a1e0:ffff::1"))
        XCTAssertEqual(problem("address = fd7a:115c:a1e1::1"), .notTailscale("fd7a:115c:a1e1::1"))
    }

    func testRefusesWhatIsNotATailscaleNodeAddress() {
        XCTAssertEqual(problem("address = 192.168.1.20"), .notTailscale("192.168.1.20"))
        XCTAssertEqual(problem("address = 10.8.0.6"), .notTailscale("10.8.0.6"))
        XCTAssertEqual(problem("address = 0.0.0.0"), .notTailscale("0.0.0.0"))
        XCTAssertEqual(problem("address = ::"), .notTailscale("::"))
        XCTAssertEqual(problem("address = 127.0.0.1"), .notTailscale("127.0.0.1"))
        XCTAssertEqual(problem("address = 100.100.100.100"), .notTailscale("100.100.100.100"))
        XCTAssertEqual(problem("address = mac.tail1234.ts.net"), .notTailscale("mac.tail1234.ts.net"))
        XCTAssertEqual(problem("address = fe80::1%utun4"), .notTailscale("fe80::1%utun4"))
        XCTAssertEqual(problem("address = [fd7a:115c:a1e0::1]"), .notTailscale("[fd7a:115c:a1e0::1]"))
        XCTAssertEqual(problem("address = 100.64.0.0/10"), .notTailscale("100.64.0.0/10"))
        XCTAssertEqual(problem("address = ::ffff:100.64.0.1"), .notTailscale("::ffff:100.64.0.1"))
    }

    func testRefusesBadFiles() {
        XCTAssertEqual(problem(""), .noAddress)
        XCTAssertEqual(problem("# only a comment\n"), .noAddress)
        XCTAssertEqual(problem("port = 7455"), .noAddress)
        XCTAssertEqual(problem("address 100.64.0.1"), .badLine(1))
        XCTAssertEqual(problem("\naddress ="), .badLine(2))
        XCTAssertEqual(problem("address = 100.64.0.1\nbind = 0.0.0.0"), .unknownKey("bind"))
        XCTAssertEqual(problem("address = 100.64.0.1\naddress = 100.64.0.2"), .duplicateKey("address"))
        XCTAssertEqual(problem("address = 100.64.0.1\nport = 80"), .badPort("80"))
        XCTAssertEqual(problem("address = 100.64.0.1\nport = 70000"), .badPort("70000"))
        XCTAssertEqual(problem("address = 100.64.0.1\nport = 7455x"), .badPort("7455x"))
    }

    func testFileChecks() {
        let me = getuid()
        XCTAssertNil(TailnetConfig.fileProblem(mode: S_IFREG | 0o600, owner: me, size: 30, user: me))
        XCTAssertNil(TailnetConfig.fileProblem(mode: S_IFREG | 0o644, owner: me, size: 30, user: me))
        XCTAssertNotNil(TailnetConfig.fileProblem(mode: S_IFREG | 0o666, owner: me, size: 30, user: me))
        XCTAssertNotNil(TailnetConfig.fileProblem(mode: S_IFREG | 0o620, owner: me, size: 30, user: me))
        XCTAssertNotNil(TailnetConfig.fileProblem(mode: S_IFLNK | 0o600, owner: me, size: 30, user: me))
        XCTAssertNotNil(TailnetConfig.fileProblem(mode: S_IFDIR | 0o700, owner: me, size: 30, user: me))
        XCTAssertNotNil(TailnetConfig.fileProblem(mode: S_IFREG | 0o600, owner: me &+ 1, size: 30, user: me))
        XCTAssertNotNil(TailnetConfig.fileProblem(mode: S_IFREG | 0o600, owner: me, size: 5000, user: me))
    }

    func testLoadFromAFile() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sill-tailnet-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("tailscale.conf")
        guard case .failure(.missing) = TailnetConfig.load(from: url) else { return XCTFail("a missing file must say so") }
        try Data("address = 100.64.0.9\n".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        XCTAssertEqual(try TailnetConfig.load(from: url).get().address, "100.64.0.9")
        try FileManager.default.setAttributes([.posixPermissions: 0o666], ofItemAtPath: url.path)
        guard case .failure(.unsafe) = TailnetConfig.load(from: url) else { return XCTFail("a world-writable file must be refused") }
        let link = dir.appendingPathComponent("link.conf")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: url)
        guard case .failure(.unsafe) = TailnetConfig.load(from: link) else { return XCTFail("a link must be refused") }
    }
}
