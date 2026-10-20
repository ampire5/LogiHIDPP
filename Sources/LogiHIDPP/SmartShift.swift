import Foundation

/// The vertical wheel's mode under SmartShift (`0x2111`): spinning freely or clicking from notch to notch.
public enum WheelMode: UInt8, Sendable, Equatable {
    case freeSpin = 1
    case ratchet = 2
}

/// SMARTSHIFT (`0x2111`, SmartShift enhanced): the vertical wheel's free spin or ratchet, as recorded on the MX Master
/// 4 (docs/hardware-notes.md: index 17; the mouse sends no notification when the mode changes).
public enum SmartShift {
    public static let featureID: UInt16 = 0x2111
    /// The reply is `mode threshold torque`: the first byte is the mode.
    static let readMode: UInt8 = 1
    /// The params are `mode threshold torque`, 0 keeping a value; the reply repeats the whole mode.
    static let writeMode: UInt8 = 2

    /// The params of a write of `mode`: the threshold and torque kept.
    static func writeParams(_ mode: WheelMode) -> [UInt8] { [mode.rawValue, 0, 0] }
}

/// "The mouse had this wheel mode before this app wrote its own, and has not been given it back" — survives a crash.
/// Set to the mode known before the first write of the app's mode, or before the first press of the SmartShift button
/// that `LogiMouse` adopts as the wanted mode (the mouse switched itself, without a write); cleared once that mode is
/// back in the mouse (a confirmed write of it, or a read showing it while the app wants none), and by
/// `releaseAllSync()` once its write of the mode is sent without a transport error: only a crash (or a failed send at
/// exit) leaves it set for the next launch. A mouse found with the marker set gets the saved mode back unless the app
/// wants one; without it, the mouse's mode is its own and is written only while wanted.
public protocol WheelModeMarker: AnyObject, Sendable {
    var saved: WheelMode? { get set }
}

/// The marker in the app's `UserDefaults.standard`, key `LogiHIDPP.wheelModeSaved`.
public final class DefaultsWheelModeMarker: WheelModeMarker {
    static let key = "LogiHIDPP.wheelModeSaved"

    public init() {}

    public var saved: WheelMode? {
        get {
            (UserDefaults.standard.object(forKey: Self.key) as? Int).flatMap { UInt8(exactly: $0) }
                .flatMap(WheelMode.init(rawValue:))
        }
        set {
            if let newValue {
                UserDefaults.standard.set(Int(newValue.rawValue), forKey: Self.key)
            } else {
                UserDefaults.standard.removeObject(forKey: Self.key)
            }
        }
    }
}
