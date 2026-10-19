import XCTest
@testable import GrokBotTunnelCore

final class FramesTests: XCTestCase {
    func testEncodeDecodeOpen() {
        let encoded = FrameCodec.encodeOpen(streamId: 42, host: "example.com", port: 443)
        XCTAssertEqual(encoded[0], 1)
        guard case let .open(streamId, host, port) = FrameCodec.decode(encoded) else {
            return XCTFail("expected open")
        }
        XCTAssertEqual(streamId, 42)
        XCTAssertEqual(host, "example.com")
        XCTAssertEqual(port, 443)
    }

    func testEncodeDecodeData() {
        let payload = Data("hello".utf8)
        let encoded = FrameCodec.encodeData(streamId: 7, payload: payload)
        XCTAssertEqual(encoded[0], 2)
        guard case let .data(streamId, got) = FrameCodec.decode(encoded) else {
            return XCTFail("expected data")
        }
        XCTAssertEqual(streamId, 7)
        XCTAssertEqual(got, payload)
    }

    func testEncodeDecodeClose() {
        let encoded = FrameCodec.encodeClose(streamId: 99)
        XCTAssertEqual(encoded.count, 5)
        XCTAssertEqual(encoded[0], 3)
        guard case let .close(streamId) = FrameCodec.decode(encoded) else {
            return XCTFail("expected close")
        }
        XCTAssertEqual(streamId, 99)
    }

    func testDecodeRejectsShort() {
        XCTAssertNil(FrameCodec.decode(Data([1, 0, 0])))
        XCTAssertNil(FrameCodec.decode(Data([9, 0, 0, 0, 1])))
    }

    func testStreamIdBigEndian() {
        let encoded = FrameCodec.encodeClose(streamId: 0x01020304)
        XCTAssertEqual(Array(encoded), [3, 1, 2, 3, 4])
    }
}
