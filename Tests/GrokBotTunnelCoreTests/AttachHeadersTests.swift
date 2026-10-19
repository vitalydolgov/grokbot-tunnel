import XCTest
@testable import GrokBotTunnelCore

final class AttachHeadersTests: XCTestCase {
    func testClaimHeaders() {
        let headers = AttachHeaders.build(
            bearer: "tok",
            mode: "claim",
            clientId: "abc",
            networkToken: "net"
        )
        XCTAssertEqual(headers["Authorization"], "Bearer tok")
        XCTAssertEqual(headers["x-sand-egress-attach"], "claim")
        XCTAssertEqual(headers["x-sand-egress-client"], "abc")
        XCTAssertEqual(headers["x-anyrun-network-token"], "net")
    }
}
