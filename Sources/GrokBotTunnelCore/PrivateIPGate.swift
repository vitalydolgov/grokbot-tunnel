import Foundation

public enum PrivateIPGate: Sendable {
    /// True when the IP must not be dialed unless allowPrivateTargets.
    public static func isBlockedDestinationIP(_ ip: String) -> Bool {
        let cleaned = ip.split(separator: "%", maxSplits: 1, omittingEmptySubsequences: false)
            .first
            .map(String.init) ?? ip

        if let v4 = parseIPv4(cleaned) {
            return isBlockedIPv4(v4)
        }
        if cleaned.contains(":") {
            let lower = cleaned.lowercased()
            if lower == "::1" || lower == "::" { return true }
            if lower.hasPrefix("fc") || lower.hasPrefix("fd") { return true }
            if lower.hasPrefix("fe80") { return true }
            if lower.hasPrefix("ff") { return true }
            if let mapped = extractIPv4Mapped(lower) {
                return isBlockedIPv4(mapped)
            }
            return false
        }
        return true
    }

    public static func isBlockedIPv4(_ parts: [Int]) -> Bool {
        guard parts.count == 4 else { return true }
        let a = parts[0], b = parts[1], c = parts[2]
        let privateRange = a == 10 || (a == 172 && (16...31).contains(b)) || (a == 192 && b == 168)
        let loopback = a == 127
        let linkLocal = a == 169 && b == 254
        let broadcast = parts.allSatisfy { $0 == 255 }
        let documentation = (a == 192 && b == 0 && c == 2)
            || (a == 198 && b == 51 && c == 100)
            || (a == 203 && b == 0 && c == 113)
        let unspecified = parts.allSatisfy { $0 == 0 }
        let multicast = (224...239).contains(a)
        let cgnat = a == 100 && (b & 192) == 64
        let benchmarking = a == 198 && (b & 254) == 18
        let reserved = a >= 240
        return privateRange || loopback || linkLocal || broadcast || documentation
            || unspecified || multicast || cgnat || benchmarking || reserved
    }

    public static func parseIPv4(_ ip: String) -> [Int]? {
        let parts = ip.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        var out: [Int] = []
        for part in parts {
            guard let n = Int(part), (0...255).contains(n) else { return nil }
            out.append(n)
        }
        return out
    }

    private static func extractIPv4Mapped(_ lower: String) -> [Int]? {
        guard let regex = try? NSRegularExpression(pattern: #"::ffff:(\d+\.\d+\.\d+\.\d+)$"#, options: []) else {
            return nil
        }
        let range = NSRange(lower.startIndex..<lower.endIndex, in: lower)
        guard let match = regex.firstMatch(in: lower, options: [], range: range),
              match.numberOfRanges >= 2,
              let v4Range = Range(match.range(at: 1), in: lower)
        else { return nil }
        return parseIPv4(String(lower[v4Range]))
    }
}
