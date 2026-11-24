import Foundation

/// Validates user-entered Nextcloud addresses without changing persisted accounts.
struct NextcloudServerAddress: Sendable {
    enum InputKind: Sendable { case installation, davRoot, principal, collection }
    let baseURL: URL
    let discoverySeed: URL?
    let inputKind: InputKind
    enum ParseError: Error, Equatable { case invalid, unsupported }

    static func parse(_ input: String) throws -> Self {
        guard input.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else { throw ParseError.invalid }
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ParseError.invalid }
        let value = trimmed.contains("://") ? trimmed : "https://" + trimmed
        // Foundation repairs malformed percent escapes; reject them before parsing.
        let bytes = Array(value.utf8)
        for index in bytes.indices where bytes[index] == 37 {
            guard index + 2 < bytes.count, isHex(bytes[index + 1]), isHex(bytes[index + 2]) else { throw ParseError.invalid }
        }
        guard var components = URLComponents(string: value),
              components.scheme?.lowercased() == "https", components.host?.isEmpty == false,
              components.user == nil, components.password == nil,
              components.percentEncodedQuery == nil, components.percentEncodedFragment == nil,
              let original = components.url else { throw ParseError.invalid }
        let segments = components.percentEncodedPath.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        var endpointIndex: Int?
        var kind: InputKind = .installation
        for index in segments.indices {
            let tail = Array(segments[index...])
            if tail.starts(with: ["remote.php", "dav"]) {
                let remainder = Array(tail.dropFirst(2)).filter { !$0.isEmpty }
                if remainder.isEmpty { kind = .davRoot }
                else if remainder.count >= 3 && remainder[0] == "principals" && remainder[1] == "users" && remainder.count == 3 { kind = .principal }
                else if remainder.count >= 2 && remainder[0] == "calendars" && remainder.count <= 3 { kind = .collection }
                else { throw ParseError.unsupported }
                endpointIndex = index
                break
            }
            if tail.starts(with: ["remote.php", "webdav"]) || tail.starts(with: ["s"]) || tail.starts(with: ["index.php", "apps"]) || tail.starts(with: ["apps"]) {
                throw ParseError.unsupported
            }
        }
        if let index = endpointIndex {
            components.percentEncodedPath = segments.prefix(index).joined(separator: "/")
        }
        while components.percentEncodedPath.hasSuffix("/") { components.percentEncodedPath.removeLast() }
        guard let base = components.url else { throw ParseError.invalid }
        return Self(baseURL: base, discoverySeed: endpointIndex == nil ? nil : original, inputKind: kind)
    }

    static func sameOrigin(_ lhs: URL, _ rhs: URL) -> Bool {
        guard let a = URLComponents(url: lhs, resolvingAgainstBaseURL: false),
              let b = URLComponents(url: rhs, resolvingAgainstBaseURL: false),
              a.scheme?.lowercased() == "https", b.scheme?.lowercased() == "https",
              a.user == nil, a.password == nil, b.user == nil, b.password == nil,
              a.percentEncodedQuery == nil, a.percentEncodedFragment == nil,
              b.percentEncodedQuery == nil, b.percentEncodedFragment == nil,
              let ah = normalizedHost(lhs), let bh = normalizedHost(rhs) else { return false }
        return ah == bh && (a.port ?? 443) == (b.port ?? 443)
    }

    static func normalizedHost(_ url: URL) -> String? {
        guard let host = url.host(), !host.isEmpty else { return nil }
        return host.lowercased()
    }

    static func encodePathSegment(_ value: String) -> String {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed)!
    }
    private static func isHex(_ byte: UInt8) -> Bool {
        (48...57).contains(byte) || (65...70).contains(byte) || (97...102).contains(byte)
    }
}
