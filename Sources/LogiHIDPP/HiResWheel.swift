import Foundation

/// HI-RES WHEEL (`0x2121`, Logitech "Precision Scroll"): the vertical wheel's high-resolution mode, as recorded on the
/// MX Master 4 (docs/hardware-notes.md: index 18, mode 0 by default, about 6 macOS scroll events per notch in high
/// resolution instead of 1).
public enum HiResWheel {
    public static let featureID: UInt16 = 0x2121
    /// getWheelMode: the reply's first byte is the mode.
    static let getMode: UInt8 = 1
    /// setWheelMode: the param is the whole mode byte.
    static let setMode: UInt8 = 2
    /// Bit 1 of the mode byte; bit 0 (divert) is never touched, nor bit 2 (invert).
    public static let highResolution: UInt8 = 0x02
}

/// "This app turned the wheel to high resolution and has not given it back" — survives a crash. A wheel found in high
/// resolution with the marker set is a leftover of this app (turned off unless wanted); without it, the user's own
/// setting (LinearMouse, Logi Options+), which is never written.
public protocol HiResMarker: AnyObject, Sendable {
    var isSet: Bool { get set }
}

/// The marker in the app's `UserDefaults.standard`, key `LogiHIDPP.hiResTurnedOn`.
public final class DefaultsHiResMarker: HiResMarker {
    static let key = "LogiHIDPP.hiResTurnedOn"

    public init() {}

    public var isSet: Bool {
        get { UserDefaults.standard.bool(forKey: Self.key) }
        set {
            if newValue {
                UserDefaults.standard.set(true, forKey: Self.key)
            } else {
                UserDefaults.standard.removeObject(forKey: Self.key)
            }
        }
    }
}
