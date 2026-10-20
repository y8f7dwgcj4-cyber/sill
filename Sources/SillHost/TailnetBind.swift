import Foundation
import Network

/// The pure parts of the door's bind to its Tailscale address (RemoteServer): which interface
/// holds the address, the endpoint to bind, and how long to wait before the next try.
enum TailnetBind {
    /// What the door binds: the configured address and the port in force.
    struct Target: Equatable, Sendable {
        let address: String
        let bytes: [UInt8]
        /// 0 is any free port (the CLI's `--remote` without a port).
        let port: Int

        /// The file's address, with the file's port when it sets one, else `port`.
        init(_ config: TailnetConfig, port: Int) {
            address = config.address
            bytes = config.bytes
            self.port = config.port ?? port
        }
    }

    /// The delays between tries, in seconds. After the last one, every try waits 60 s.
    static let delays: [TimeInterval] = [2, 4, 8, 16, 32, 60]

    /// The delay before the next try, after `failures` tries that did not bind.
    static func retryDelay(failures: Int) -> TimeInterval {
        delays[min(max(failures, 0), delays.count - 1)]
    }

    /// The name of the up tunnel interface ("utun4") that holds `address`, else nil. The door
    /// binds only then: an address on any other kind of interface is not Tailscale's.
    static func owner(of address: [UInt8], in entries: [InterfaceSnapshot.Entry]) -> String? {
        entries.first { e in
            e.up && e.address == address
                && OriginPolicy.interfaceKind(name: e.name, pointToPoint: e.pointToPoint, loopback: e.loopback) == .tunnel
        }?.name
    }

    /// The local endpoint to bind: the configured address and port. Port 0 is any free port (the
    /// CLI's default). Nil when the address is neither 4 nor 16 bytes.
    static func endpoint(_ c: Target) -> NWEndpoint? {
        guard let port = NWEndpoint.Port(rawValue: UInt16(clamping: c.port)) else { return nil }
        let host: NWEndpoint.Host
        if c.bytes.count == 4, let a = IPv4Address(Data(c.bytes)) {
            host = .ipv4(a)
        } else if c.bytes.count == 16, let a = IPv6Address(Data(c.bytes)) {
            host = .ipv6(a)
        } else {
            return nil
        }
        return .hostPort(host: host, port: port)
    }
}
