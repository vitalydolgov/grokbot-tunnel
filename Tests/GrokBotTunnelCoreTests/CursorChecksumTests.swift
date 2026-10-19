import XCTest
@testable import GrokBotTunnelCore

final class CursorChecksumTests: XCTestCase {
    func testMatchesNodeGoldenValues() {
        // Generated from grok-bot-headless.mjs cursorChecksum with fixed timestamps.
        XCTAssertEqual(
            CursorChecksum.make(machineId: "test-machine-id", nowMs: 1_760_847_419_000),
            "ezU3MPLCtest-machine-id"
        )
        XCTAssertEqual(
            CursorChecksum.make(machineId: "abc", nowMs: 0),
            "paaoq6-0abc"
        )
        XCTAssertEqual(
            CursorChecksum.make(machineId: "abc", nowMs: 1_000_000_000_000),
            "56iqqO6zabc"
        )
    }

    func testJsShiftRightMatchesECMAScript() {
        // 40 & 0x1F == 8, 32 & 0x1F == 0
        let epoch = 1_760_847
        XCTAssertEqual(CursorChecksum.jsShiftRight(epoch, 40) & 255, (epoch >> 8) & 255)
        XCTAssertEqual(CursorChecksum.jsShiftRight(epoch, 32) & 255, epoch & 255)
    }
}
