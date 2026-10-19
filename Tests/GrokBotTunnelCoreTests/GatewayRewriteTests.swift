import XCTest
@testable import GrokBotTunnelCore

final class GatewayRewriteTests: XCTestCase {
    func testSetsPort8790AndWss() {
        XCTAssertEqual(
            GatewayRewrite.rewriteGatewayToTunnelWs("https://gateway.example.com:443/path?x=1"),
            "wss://gateway.example.com:8790/"
        )
        XCTAssertEqual(
            GatewayRewrite.rewriteGatewayToTunnelWs("http://127.0.0.1:8080/"),
            "ws://127.0.0.1:8790/"
        )
    }

    func testVncHostnameRewrite() {
        XCTAssertEqual(
            GatewayRewrite.rewriteGatewayToTunnelWs("https://box-1340.pods.example.com", useVncHostnameRewrite: true),
            "wss://box-8790.pods.example.com/"
        )
        XCTAssertNil(
            GatewayRewrite.rewriteGatewayToTunnelWs("https://no-suffix.example.com", useVncHostnameRewrite: true)
        )
    }

    func testTunnelConfigFromBoxRequiresUrlAndToken() {
        XCTAssertNil(GatewayRewrite.tunnelConfigFromBox(gatewayUrl: nil, gatewayToken: nil))
        XCTAssertNil(GatewayRewrite.tunnelConfigFromBox(gatewayUrl: "https://g.example", gatewayToken: ""))
        let cfg = GatewayRewrite.tunnelConfigFromBox(
            gatewayUrl: "https://g.example.com/x",
            gatewayToken: "tok"
        )
        XCTAssertEqual(cfg?.url, "wss://g.example.com:8790/")
        XCTAssertEqual(cfg?.bearer, "tok")
        XCTAssertNil(cfg?.networkToken)
    }

    func testTunnelConfigUsesVncWhenTokensPresent() {
        let cfg = GatewayRewrite.tunnelConfigFromBox(
            gatewayUrl: "https://box-100.pods.example.com",
            gatewayToken: "tok",
            networkToken: "net",
            vncUrl: "https://vnc",
            forkVncBaseUrl: "https://fork"
        )
        XCTAssertEqual(cfg?.url, "wss://box-8790.pods.example.com/")
        XCTAssertEqual(cfg?.networkToken, "net")
    }
}
