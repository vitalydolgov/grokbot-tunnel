import CryptoKit
import Foundation

public enum TunnelClientId: Sendable {
    /// sha256("sand-egress-tunnel-client:" + machineId).hex.first32
    public static func make(machineId: String) -> String {
        let input = Data("sand-egress-tunnel-client:\(machineId)".utf8)
        let digest = SHA256.hash(data: input)
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return String(hex.prefix(32))
    }
}
