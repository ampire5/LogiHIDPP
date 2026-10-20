/// One HID++ report as it travels over the receiver's vendor interface: short (`0x10`, 7 bytes) or long (`0x11`,
/// 20 bytes).
///
/// Layout: byte 0 report ID, byte 1 device index (receiver slot 1…6, `0xFF` the receiver itself), byte 2 feature index
/// (HID++ 1.0: sub-ID), byte 3 `function << 4 | softwareID` (HID++ 1.0: register address), bytes 4… parameters.
public struct HIDPPReport: Equatable, Sendable {
    public static let shortID: UInt8 = 0x10
    public static let longID: UInt8 = 0x11
    public static let shortLength = 7
    public static let longLength = 20
    public let bytes: [UInt8]

    /// Accepts only a well-formed short (`0x10` × 7) or long (`0x11` × 20) report.
    public init?(bytes: [UInt8]) {
        switch (bytes.first, bytes.count) {
        case (Self.shortID, Self.shortLength), (Self.longID, Self.longLength):
            self.bytes = bytes
        default:
            return nil
        }
    }

    /// A short report; `params` (at most 3 bytes) is zero-padded. `HIDPPChannel.request` and `post` stamp the channel's
    /// software ID on it, so a request need not name one (0, the notification ID, is the default).
    public static func short(device: UInt8, feature: UInt8, function: UInt8, softwareID: UInt8 = 0,
                             params: [UInt8]) -> HIDPPReport {
        make(id: shortID, length: shortLength, device: device, feature: feature, function: function,
             softwareID: softwareID, params: params)
    }

    /// A long report; `params` (at most 16 bytes) is zero-padded. Software ID: see `short`.
    public static func long(device: UInt8, feature: UInt8, function: UInt8, softwareID: UInt8 = 0,
                            params: [UInt8]) -> HIDPPReport {
        make(id: longID, length: longLength, device: device, feature: feature, function: function,
             softwareID: softwareID, params: params)
    }

    public var isLong: Bool { bytes[0] == Self.longID }
    public var deviceIndex: UInt8 { bytes[1] }
    public var featureIndex: UInt8 { bytes[2] }
    public var function: UInt8 { bytes[3] >> 4 }
    public var softwareID: UInt8 { bytes[3] & 0x0F }
    /// Bytes 4…: 3 for a short report, 16 for a long one.
    public var params: [UInt8] { Array(bytes[4...]) }

    /// The same report with `softwareID` in the low nibble of byte 3 (a HID++ 2.0 request; not for HID++ 1.0 register
    /// access, whose byte 3 is the register address).
    public func stamped(softwareID: UInt8) -> HIDPPReport {
        precondition(softwareID < 16, "HID++ software ID is 4 bits")
        var bytes = bytes
        bytes[3] = bytes[3] & 0xF0 | softwareID
        return HIDPPReport(unchecked: bytes)
    }

    private static func make(id: UInt8, length: Int, device: UInt8, feature: UInt8, function: UInt8,
                             softwareID: UInt8, params: [UInt8]) -> HIDPPReport {
        precondition(params.count <= length - 4, "HID++ report \(String(id, radix: 16)): too many params")
        precondition(function < 16 && softwareID < 16, "HID++ function and software ID are 4 bits each")
        var bytes = [id, device, feature, function << 4 | softwareID] + params
        bytes += [UInt8](repeating: 0, count: length - bytes.count)
        return HIDPPReport(unchecked: bytes)
    }

    private init(unchecked bytes: [UInt8]) {
        self.bytes = bytes
    }
}

extension HIDPPReport: CustomStringConvertible {
    /// Hex bytes as the probe logs show them: `11 02 00 1a 04 05 5a …`.
    public var description: String {
        bytes.map { byte in
            let hex = String(byte, radix: 16)
            return byte < 0x10 ? "0" + hex : hex
        }.joined(separator: " ")
    }
}
