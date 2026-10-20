import Foundation

/// A Logitech control ID: the number REPROG_CONTROLS_V4 (`0x1B04`) gives each physical control of the mouse.
public struct CID: Hashable, Sendable, RawRepresentable {
    public let rawValue: UInt16

    public init(rawValue: UInt16) {
        self.rawValue = rawValue
    }

    public static let left = CID(rawValue: 0x50)
    public static let right = CID(rawValue: 0x51)
    public static let middle = CID(rawValue: 0x52)
    public static let back = CID(rawValue: 0x53)
    public static let forward = CID(rawValue: 0x56)
    public static let gesture = CID(rawValue: 0xC3)
    public static let smartShift = CID(rawValue: 0xC4)
    /// The MX Master 4 haptic panel (thumb-rest button).
    public static let hapticPanel = CID(rawValue: 0x01A0)
}

/// Where a thumb-wheel gesture is: its first rotation step, the steps after it, or its end.
public enum WheelPhase: Equatable, Sendable {
    case began, changed, ended
}

/// What a connected mouse reports. Times are seconds on the monotonic clock of the process (`TimeInterval`).
public enum MouseEvent: Equatable, Sendable {
    case pressed(CID, at: TimeInterval)
    case released(CID, at: TimeInterval)
    case thumbWheel(delta: Int, touching: Bool, phase: WheelPhase, at: TimeInterval)
    /// The mouse switched on or came back into range.
    case connected
    /// The mouse switched off or went out of range.
    case disconnected
    /// `LogiMouse.isHighResolution` changed: the vertical wheel is (true) or is no longer (false) in high resolution
    /// (`0x2121`), whether this app turned it on or the user's own setting did.
    case highResolutionWheel(Bool)
    /// `LogiMouse.wheelMode` changed: the vertical wheel spins freely or ratchets now (SmartShift, `0x2111`).
    /// `byButton`: the mouse switched it itself on a press of the SmartShift button; false for a mode read from the
    /// mouse or written by this app.
    case wheelMode(WheelMode, byButton: Bool)
}
