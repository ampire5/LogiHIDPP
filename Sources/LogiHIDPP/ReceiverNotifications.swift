import os

private let log = Logger(subsystem: "LogiHIDPP", category: "Receiver")

/// The receiver's HID++ 1.0 notification flags (short register `0x00` of device `0xFF`, 3 bytes, big-endian).
///
/// With the wireless flag (`0x000100`) clear the receiver sends no device-connection notices (`0x41`): a mouse switched
/// on after the app started is never found, and a mouse that slept or was switched off and on (and so forgot its
/// diverts) is never set up again. Another client (BetterMouse, Logi Options+) usually sets it, but the register is
/// volatile: a receiver re-plug or reset clears it.
///
/// The package only ever sets that one flag, by read-modify-write, and only when it is clear; every other flag stays
/// as it is. It is receiver state, not a mouse setting, and lasts until the receiver is re-plugged or reset.
public enum ReceiverNotifications {
    /// The register address.
    public static let register: UInt8 = 0x00
    /// The wireless-notification flag: bit 0 of the middle byte (`0x000100`).
    static let wirelessByte = 1
    static let wirelessMask: UInt8 = 0x01

    /// The register value with the wireless flag set, or nil when it already is (nothing to write).
    static func withWireless(_ value: [UInt8]) -> [UInt8]? {
        guard value.count == 3, value[wirelessByte] & wirelessMask == 0 else { return nil }
        var updated = value
        updated[wirelessByte] |= wirelessMask
        return updated
    }

    /// Reads the flags of the receiver behind `channel` and sets the wireless flag if it is clear. Returns whether it
    /// wrote. Failures are logged and ignored (returns false).
    @discardableResult
    public static func enable(on channel: HIDPPChannel) async -> Bool {
        do {
            let value = try await channel.readRegister(address: register)
            guard let updated = withWireless(value) else { return false }
            try await channel.writeRegister(address: register, value: updated)
            log.info("receiver wireless notifications enabled")
            return true
        } catch {
            log.error("receiver notification flags: \(String(describing: error), privacy: .public)")
            return false
        }
    }
}
