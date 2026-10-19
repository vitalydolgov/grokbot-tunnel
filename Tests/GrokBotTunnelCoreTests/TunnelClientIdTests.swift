import CryptoKit
import XCTest
@testable import GrokBotTunnelCore

final class TunnelClientIdTests: XCTestCase {
    func testStableSha256Prefix() {
        let id = TunnelClientId.make(machineId: "machine-abc")
        XCTAssertEqual(id.count, 32)
        XCTAssertEqual(id, TunnelClientId.make(machineId: "machine-abc"))
        XCTAssertNotEqual(id, TunnelClientId.make(machineId: "other"))
    }

    func testMatchesManualDigest() {
        let machineId = "machine-abc"
        let input = Data("sand-egress-tunnel-client:\(machineId)".utf8)
        let digest = SHA256.hash(data: input)
        let expected = digest.map { String(format: "%02x", $0) }.joined().prefix(32)
        XCTAssertEqual(TunnelClientId.make(machineId: machineId), String(expected))
    }
}
