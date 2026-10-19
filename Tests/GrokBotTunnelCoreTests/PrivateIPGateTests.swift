import XCTest
@testable import GrokBotTunnelCore

final class PrivateIPGateTests: XCTestCase {
    func testBlocksPrivateAndLoopback() {
        XCTAssertTrue(PrivateIPGate.isBlockedDestinationIP("10.0.0.1"))
        XCTAssertTrue(PrivateIPGate.isBlockedDestinationIP("192.168.1.1"))
        XCTAssertTrue(PrivateIPGate.isBlockedDestinationIP("172.16.0.1"))
        XCTAssertTrue(PrivateIPGate.isBlockedDestinationIP("127.0.0.1"))
        XCTAssertTrue(PrivateIPGate.isBlockedDestinationIP("169.254.1.1"))
        XCTAssertTrue(PrivateIPGate.isBlockedDestinationIP("0.0.0.0"))
        XCTAssertTrue(PrivateIPGate.isBlockedDestinationIP("224.0.0.1"))
        XCTAssertTrue(PrivateIPGate.isBlockedDestinationIP("100.64.0.1"))
    }

    func testAllowsPublic() {
        XCTAssertFalse(PrivateIPGate.isBlockedDestinationIP("8.8.8.8"))
        XCTAssertFalse(PrivateIPGate.isBlockedDestinationIP("1.1.1.1"))
    }

    func testIPv6() {
        XCTAssertTrue(PrivateIPGate.isBlockedDestinationIP("::1"))
        XCTAssertTrue(PrivateIPGate.isBlockedDestinationIP("::"))
        XCTAssertTrue(PrivateIPGate.isBlockedDestinationIP("fc00::1"))
        XCTAssertTrue(PrivateIPGate.isBlockedDestinationIP("fe80::1"))
        XCTAssertTrue(PrivateIPGate.isBlockedDestinationIP("::ffff:127.0.0.1"))
        XCTAssertFalse(PrivateIPGate.isBlockedDestinationIP("2001:4860:4860::8888"))
    }

    func testRejectsNonIP() {
        XCTAssertTrue(PrivateIPGate.isBlockedDestinationIP("not-an-ip"))
    }
}
