import Foundation

public enum CursorChecksum: Sendable {
    /// Exact port of the JS `cursorChecksum` transform (32-bit shift semantics).
    public static func make(machineId: String, nowMs: Int64 = Int64(Date().timeIntervalSince1970 * 1000)) -> String {
        let epoch = Int(nowMs / 1_000_000)
        // JS `>>` converts to Int32 and masks the shift count with 0x1F.
        var bytes: [UInt8] = [
            UInt8(truncatingIfNeeded: jsShiftRight(epoch, 40) & 255),
            UInt8(truncatingIfNeeded: jsShiftRight(epoch, 32) & 255),
            UInt8(truncatingIfNeeded: jsShiftRight(epoch, 24) & 255),
            UInt8(truncatingIfNeeded: jsShiftRight(epoch, 16) & 255),
            UInt8(truncatingIfNeeded: jsShiftRight(epoch, 8) & 255),
            UInt8(truncatingIfNeeded: jsShiftRight(epoch, 0) & 255),
        ]
        var previous: UInt8 = 165
        for index in 0..<bytes.count {
            bytes[index] = UInt8(truncatingIfNeeded: Int(bytes[index] ^ previous) + index)
            previous = bytes[index]
        }
        return base64URL(Data(bytes)) + machineId
    }

    /// ECMAScript ToInt32(value) >> (shift & 0x1F)
    public static func jsShiftRight(_ value: Int, _ shift: Int) -> Int {
        let int32 = Int32(truncatingIfNeeded: value)
        let amount = Int(UInt32(bitPattern: Int32(truncatingIfNeeded: shift)) & 0x1F)
        return Int(int32 >> amount)
    }

    public static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
