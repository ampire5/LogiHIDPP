import Foundation

/// THUMB_WHEEL (`0x2150`): the byte layouts of the wheel under the thumb, as recorded on the MX Master 4
/// (docs/hardware-notes.md).
public enum ThumbWheel {
    public static let featureID: UInt16 = 0x2150

    /// What `getThumbwheelInfo` (function 0) says about the wheel.
    public struct Info: Equatable, Sendable {
        /// Steps per revolution when the system owns the wheel (the probe saw 20).
        public let nativeResolution: Int
        /// Steps per revolution while the wheel is diverted to the host (the probe saw 120).
        public let divertedResolution: Int
        /// Whether turning towards positive values is the wheel's default direction; when false the mouse's
        /// positive rotation is the opposite of the default and decoded deltas are negated.
        public let positiveIsDefault: Bool
        /// Whether the wheel has a capacitive touch sensor.
        public let hasTouch: Bool

        public init(nativeResolution: Int, divertedResolution: Int, positiveIsDefault: Bool, hasTouch: Bool) {
            self.nativeResolution = nativeResolution
            self.divertedResolution = divertedResolution
            self.positiveIsDefault = positiveIsDefault
            self.hasTouch = hasTouch
        }
    }

    /// Capabilities bit (byte 5 of the info) of the touch sensor; bit 0 is the timestamp.
    private static let touchCapability: UInt8 = 0x02
    /// Flags bit (byte 5 of an event) set while a finger is on the wheel.
    private static let touchFlag: UInt8 = 0x02

    /// Decodes the reply params of `getThumbwheelInfo` (function 0): native resolution BE (2), diverted resolution
    /// BE (2), default direction (1; 0 = positive), capabilities (1), time unit BE (2, µs). Fields the params are too
    /// short to hold read as 0 resolution, positive default direction and no touch.
    public static func info(from params: [UInt8]) -> Info {
        Info(nativeResolution: Int(bigEndian(params, at: 0)),
             divertedResolution: Int(bigEndian(params, at: 2)),
             positiveIsDefault: params.count <= 4 || params[4] == 0,
             hasTouch: params.count > 5 && params[5] & touchCapability != 0)
    }

    /// Params of `setThumbwheelReporting` (function 2): `01 00` diverts the wheel to the host, `00 00` hands it back.
    public static func reportingParams(divert: Bool) -> [UInt8] {
        [divert ? 0x01 : 0x00, 0x00]
    }

    /// Decodes the params of a wheel notification (function 0): rotation Int16 BE (2), time since the previous event
    /// UInt16 BE (2, ms), rotation status (1: 0 none, 1 start, 2 active, 3 stop), flags (1; bit 1 = finger on wheel).
    /// Start gives `.began`, active `.changed`, stop `.ended`. Status 0 (a finger touching or leaving without
    /// rotation) gives `.changed` with delta 0, so the app sees touch changes; an unknown status does the same.
    /// Returns nil for params shorter than 6 bytes.
    public static func event(from params: [UInt8], info: Info, at time: TimeInterval) -> MouseEvent? {
        guard params.count >= 6 else { return nil }
        let rotation = Int(Int16(bitPattern: bigEndian(params, at: 0)))
        let phase: WheelPhase
        switch params[4] {
        case 1: phase = .began
        case 3: phase = .ended
        default: phase = .changed
        }
        return .thumbWheel(delta: info.positiveIsDefault ? rotation : -rotation,
                           touching: params[5] & touchFlag != 0, phase: phase, at: time)
    }

    private static func bigEndian(_ bytes: [UInt8], at index: Int) -> UInt16 {
        guard bytes.count >= index + 2 else { return 0 }
        return UInt16(bytes[index]) << 8 | UInt16(bytes[index + 1])
    }
}
