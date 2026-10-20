import Foundation
import Darwin

/// The one Tailscale address that the door listens on, read from a file outside the repository.
///
/// The file is `~/Library/Application Support/Sill/tailscale.conf`. `docs/tailscale.conf.example`
/// shows its form. Each line holds one `key = value` pair. A `#` starts a comment. These keys
/// are known:
///
/// - `address`: this Mac's own Tailscale address, as a literal. IPv4 must be in 100.64.0.0/10.
///   IPv6 must be in fd7a:115c:a1e0::/48. A host name is refused.
/// - `port`: optional. A number from 1024 to 65535. Without it the port is the app's setting (7455
///   by default) or the CLI's `--remote=PORT`.
///
/// The door fails closed. A missing file, a bad line, an unknown key, an address outside the
/// Tailscale ranges or a file that other users can write gives no listener at all.
///
/// Pure (Foundation and Darwin only). `load(from:)` reads the file. `parse(_:)` does the rest.
package struct TailnetConfig: Equatable, Sendable {
    /// The address as text, in its canonical form.
    package let address: String
    /// The address as 4 or 16 bytes.
    package let bytes: [UInt8]
    /// The port from the file; nil when the file sets none.
    package let port: Int?

    /// A larger file is refused before it is read.
    static let maxFileSize = 4096

    /// Why there is no usable configuration. The text is for the log and the status menu.
    package enum Problem: Error, Equatable, CustomStringConvertible {
        case missing(String)
        case unreadable(String)
        case unsafe(String)
        case badLine(Int)
        case unknownKey(String)
        case duplicateKey(String)
        case noAddress
        case notTailscale(String)
        case badPort(String)

        package var description: String {
            switch self {
            case .missing(let path): return "no configuration file at \(path)"
            case .unreadable(let why): return "the configuration file cannot be read (\(why))"
            case .unsafe(let why): return "the configuration file is not safe (\(why))"
            case .badLine(let n): return "line \(n) of the configuration file is not “key = value”"
            case .unknownKey(let k): return "the configuration file has an unknown key “\(k)”"
            case .duplicateKey(let k): return "the configuration file sets “\(k)” two times"
            case .noAddress: return "the configuration file has no address"
            case .notTailscale(let a): return "\(a) is not a Tailscale address"
            case .badPort(let p): return "\(p) is not a port from 1024 to 65535"
            }
        }
    }

    /// `~/Library/Application Support/Sill/tailscale.conf`.
    package static var defaultURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("Sill/tailscale.conf")
    }

    // MARK: The file

    /// Reads and parses the file at `url`. The file must be a regular file (not a link), owned by
    /// this user, not writable by the group or by others, and at most 4 KB.
    package static func load(from url: URL = defaultURL) -> Result<TailnetConfig, Problem> {
        var info = stat()
        guard lstat(url.path, &info) == 0 else {
            return errno == ENOENT ? .failure(.missing(url.path)) : .failure(.unreadable(String(cString: strerror(errno))))
        }
        if let problem = fileProblem(mode: info.st_mode, owner: info.st_uid, size: Int64(info.st_size), user: getuid()) {
            return .failure(problem)
        }
        guard let data = FileManager.default.contents(atPath: url.path) else { return .failure(.unreadable("no data")) }
        guard let text = String(data: data, encoding: .utf8) else { return .failure(.unreadable("not UTF-8")) }
        return parse(text)
    }

    /// The checks on the file itself, apart from the read, so that a test can give the values.
    static func fileProblem(mode: mode_t, owner: uid_t, size: Int64, user: uid_t) -> Problem? {
        if mode & S_IFMT == S_IFLNK { return .unsafe("it is a symbolic link") }
        if mode & S_IFMT != S_IFREG { return .unsafe("it is not a regular file") }
        if owner != user { return .unsafe("another user owns it") }
        if mode & (S_IWGRP | S_IWOTH) != 0 { return .unsafe("the group or other users can write it") }
        if size > Int64(maxFileSize) { return .unsafe("it is larger than \(maxFileSize) bytes") }
        return nil
    }

    // MARK: The text

    /// Parses the file's text. The first problem found is the result.
    package static func parse(_ text: String) -> Result<TailnetConfig, Problem> {
        var values: [String: String] = [:]
        for (index, raw) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let line = raw.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { continue }
            let parts = trimmed.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { return .failure(.badLine(index + 1)) }
            let key = parts[0].trimmingCharacters(in: .whitespaces).lowercased()
            let value = parts[1].trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty, !value.isEmpty else { return .failure(.badLine(index + 1)) }
            guard key == "address" || key == "port" else { return .failure(.unknownKey(key)) }
            guard values[key] == nil else { return .failure(.duplicateKey(key)) }
            values[key] = value
        }
        guard let addressText = values["address"] else { return .failure(.noAddress) }
        guard let bytes = literal(addressText), isTailscale(bytes) else { return .failure(.notTailscale(addressText)) }
        var port: Int?
        if let p = values["port"] {
            guard p.allSatisfy(\.isASCII), let n = Int(p), (1024...65535).contains(n) else { return .failure(.badPort(p)) }
            port = n
        }
        return .success(TailnetConfig(address: IPBytes.text(bytes), bytes: bytes, port: port))
    }

    /// The bytes of an IPv4 or IPv6 literal. Nil for a host name, a zone ("%en0"), brackets or
    /// anything else that `inet_pton` refuses.
    static func literal(_ text: String) -> [UInt8]? {
        guard !text.contains("%"), !text.contains("["), !text.contains("/") else { return nil }
        var v4 = in_addr()
        if inet_pton(AF_INET, text, &v4) == 1 { return withUnsafeBytes(of: &v4) { Array($0) } }
        var v6 = in6_addr()
        if inet_pton(AF_INET6, text, &v6) == 1 { return withUnsafeBytes(of: &v6) { Array($0) } }
        return nil
    }

    /// Tailscale's node addresses (IPBytes.isTailscale).
    package static func isTailscale(_ a: [UInt8]) -> Bool { IPBytes.isTailscale(a) }
}
