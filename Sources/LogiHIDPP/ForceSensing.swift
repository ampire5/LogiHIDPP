import Foundation

/// FORCE_SENSING_BUTTON (`0x19C0`): how hard a force-sensing button (the MX Master 4's haptic panel) must be pressed.
/// Function 0 returns the number of buttons, function 1 (`button`) its info, function 2 (`button`) its current force,
/// function 3 (`button`, force) writes it. Logitech does not document the unit; the MX Master 4 has one button,
/// changeable, default 4749, range 3799…6316 (docs/hardware-notes.md).
public enum ForceSensing {
    public static let featureID: UInt16 = 0x19C0

    /// One button's force settings, as function 1 reports them.
    public struct Info: Equatable, Sendable {
        /// Whether the force can be written.
        public let changeable: Bool
        public let defaultValue: UInt16
        public let range: ClosedRange<UInt16>

        public init(changeable: Bool, defaultValue: UInt16, range: ClosedRange<UInt16>) {
            self.changeable = changeable
            self.defaultValue = defaultValue
            self.range = range
        }
    }

    /// Decodes the reply params of function 1: `changeable(2) default(2) max(2) min(2)`, big-endian. Nil when the
    /// params are too short or the minimum is above the maximum.
    public static func info(from params: [UInt8]) -> Info? {
        guard params.count >= 8 else { return nil }
        let maximum = word(params, 4), minimum = word(params, 6)
        guard minimum <= maximum else { return nil }
        return Info(changeable: word(params, 0) != 0, defaultValue: word(params, 2), range: minimum...maximum)
    }

    /// Decodes the reply params of function 2: the current force, big-endian. Nil when the params are too short.
    public static func current(from params: [UInt8]) -> UInt16? {
        guard params.count >= 2 else { return nil }
        return word(params, 0)
    }

    /// Params of function 3: `button hi lo`.
    public static func setParams(button: UInt8, value: UInt16) -> [UInt8] {
        [button, UInt8(value >> 8), UInt8(value & 0xFF)]
    }

    private static func word(_ params: [UInt8], _ at: Int) -> UInt16 {
        UInt16(params[at]) << 8 | UInt16(params[at + 1])
    }
}
