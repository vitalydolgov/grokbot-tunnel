import Foundation

public enum FrameKind: UInt8, Sendable {
    case open = 1
    case data = 2
    case close = 3
}

public enum TunnelFrame: Sendable, Equatable {
    case open(streamId: UInt32, host: String, port: UInt16)
    case data(streamId: UInt32, payload: Data)
    case close(streamId: UInt32)
}

public enum FrameCodec: Sendable {
    public static func encodeOpen(streamId: UInt32, host: String, port: UInt16) -> Data {
        let hostData = Data(host.utf8)
        var data = Data(capacity: 7 + hostData.count)
        data.append(FrameKind.open.rawValue)
        appendUInt32BE(streamId, to: &data)
        appendUInt16BE(port, to: &data)
        data.append(hostData)
        return data
    }

    public static func encodeData(streamId: UInt32, payload: Data) -> Data {
        var data = Data(capacity: 5 + payload.count)
        data.append(FrameKind.data.rawValue)
        appendUInt32BE(streamId, to: &data)
        data.append(payload)
        return data
    }

    public static func encodeClose(streamId: UInt32) -> Data {
        var data = Data(capacity: 5)
        data.append(FrameKind.close.rawValue)
        appendUInt32BE(streamId, to: &data)
        return data
    }

    public static func decode(_ frame: Data) -> TunnelFrame? {
        guard frame.count >= 5 else { return nil }
        guard let kind = FrameKind(rawValue: frame[frame.startIndex]) else { return nil }
        let streamId = readUInt32BE(frame, offset: 1)
        switch kind {
        case .open:
            guard frame.count >= 7 else { return nil }
            let port = readUInt16BE(frame, offset: 5)
            let hostData = frame[(frame.startIndex + 7)...]
            guard let host = String(data: Data(hostData), encoding: .utf8) else { return nil }
            return .open(streamId: streamId, host: host, port: port)
        case .data:
            let payload = Data(frame[(frame.startIndex + 5)...])
            return .data(streamId: streamId, payload: payload)
        case .close:
            return .close(streamId: streamId)
        }
    }

    private static func appendUInt32BE(_ value: UInt32, to data: inout Data) {
        var be = value.bigEndian
        withUnsafeBytes(of: &be) { data.append(contentsOf: $0) }
    }

    private static func appendUInt16BE(_ value: UInt16, to data: inout Data) {
        var be = value.bigEndian
        withUnsafeBytes(of: &be) { data.append(contentsOf: $0) }
    }

    private static func readUInt32BE(_ data: Data, offset: Int) -> UInt32 {
        let i = data.startIndex + offset
        return (UInt32(data[i]) << 24)
            | (UInt32(data[i + 1]) << 16)
            | (UInt32(data[i + 2]) << 8)
            | UInt32(data[i + 3])
    }

    private static func readUInt16BE(_ data: Data, offset: Int) -> UInt16 {
        let i = data.startIndex + offset
        return (UInt16(data[i]) << 8) | UInt16(data[i + 1])
    }
}
