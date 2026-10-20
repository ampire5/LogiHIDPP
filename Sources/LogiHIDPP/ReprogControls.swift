import Foundation

/// One control the mouse reports in REPROG_CONTROLS_V4.
public struct Control: Equatable, Sendable {
    public let cid: CID
    /// Whether the mouse lets the host take the control over (divert it) instead of acting on it itself.
    public let divertable: Bool
    /// Whether the mouse can report the control's presses over HID++ (analytics key events) while it still sends the
    /// normal button to the OS: `LogiMouse.watch(_:)` listens without taking the control from other apps.
    public let watchable: Bool

    public init(cid: CID, divertable: Bool, watchable: Bool = false) {
        self.cid = cid
        self.divertable = divertable
        self.watchable = watchable
    }
}

/// REPROG_CONTROLS_V4 (`0x1B04`): the byte layouts of divert requests, control info and button notifications.
public enum ReprogControls {
    public static let featureID: UInt16 = 0x1B04

    /// Flags bit of a control (byte 4 of its info) that marks it divertable; the probe saw `0x31` and `0x01`.
    private static let divertableFlag: UInt8 = 0x20
    /// Flags2 bit (byte 8 of the info) that marks a control as reporting analytics key events (Solaar's
    /// `ANALYTICS_KEY_EVENTS`, `0x400` of the 16-bit flags `byte 4 | byte 8 << 8`); the MX Master 4 has it on the
    /// buttons, panel and middle button (`0x05`, left / right `0x04`; bit `0x01` is raw XY), not on `0xd7` (`0x03`).
    private static let watchableFlag: UInt8 = 0x04
    /// A button notification lists at most this many pressed controls.
    private static let maxPressed = 4
    /// An analytics key event report holds at most this many (CID, state) triples (16 params).
    private static let maxKeyEvents = 5

    /// Params of `setControlReporting` (function 3): `CID_hi CID_lo flags`. `0x03` diverts the control to the host,
    /// `0x02` hands it back to the mouse.
    public static func divertParams(_ cid: CID, divert: Bool) -> [UInt8] {
        [UInt8(cid.rawValue >> 8), UInt8(cid.rawValue & 0xFF), divert ? 0x03 : 0x02]
    }

    /// Params of `setControlReporting` (function 3) that switch the control's analytics key events on or off:
    /// `CID_hi CID_lo 00 00 00 03|02`. Byte 5 is the analytics flags (bit 0 = on, bit 1 = valid, so `0x02` switches
    /// off); byte 2 = 0 (divert flags not valid) and remap 0 (unchanged) leave a divert alone. Six params: a long report.
    public static func watchParams(_ cid: CID, watch: Bool) -> [UInt8] {
        [UInt8(cid.rawValue >> 8), UInt8(cid.rawValue & 0xFF), 0x00, 0x00, 0x00, watch ? 0x03 : 0x02]
    }

    /// Decodes the reply params of `getControlInfo` (function 1): CID BE (2), task ID BE (2), flags (1), …, flags2 (at
    /// 8). Params too short to hold a flags byte make the control not divertable, resp. not watchable.
    public static func control(fromInfo params: [UInt8]) -> Control {
        let cid = CID(rawValue: bigEndian(params, at: 0))
        let flags = params.count > 4 ? params[4] : 0
        let flags2 = params.count > 8 ? params[8] : 0
        return Control(cid: cid, divertable: flags & divertableFlag != 0, watchable: flags2 & watchableFlag != 0)
    }

    /// Decodes the params of a diverted-button notification (function 0): up to four big-endian CIDs, zero-padded.
    /// Reading stops at the first zero CID; no CIDs means all released.
    public static func pressed(from params: [UInt8]) -> [CID] {
        var result: [CID] = []
        for index in 0..<maxPressed where params.count >= index * 2 + 2 {
            let raw = bigEndian(params, at: index * 2)
            if raw == 0 { break }
            result.append(CID(rawValue: raw))
        }
        return result
    }

    /// Decodes the params of an analytics key event (function 2): consecutive `CID_hi CID_lo state` triples (state 1 =
    /// pressed, 0 = released), at most five in a long report, up to the first zero CID. Solaar reads a list; the
    /// probe only ever saw one triple, with the rest zeros. A half triple at the end is ignored.
    public static func keyEvents(from params: [UInt8]) -> [(cid: CID, pressed: Bool)] {
        var result: [(cid: CID, pressed: Bool)] = []
        for index in 0..<maxKeyEvents where params.count >= index * 3 + 3 {
            let raw = bigEndian(params, at: index * 3)
            if raw == 0 { break }
            result.append((CID(rawValue: raw), params[index * 3 + 2] != 0))
        }
        return result
    }

    private static func bigEndian(_ bytes: [UInt8], at index: Int) -> UInt16 {
        guard bytes.count >= index + 2 else { return 0 }
        return UInt16(bytes[index]) << 8 | UInt16(bytes[index + 1])
    }
}

/// Turns the "currently pressed" lists of button notifications into press and release events.
public struct PressTracker: Sendable {
    /// Held controls in the order they were pressed.
    private var held: [CID] = []

    public init() {}

    /// Compares the new list with the held set: releases of controls that left it (in press order), then presses of
    /// controls that joined it (in list order).
    public mutating func update(_ pressed: [CID], at time: TimeInterval) -> [MouseEvent] {
        let released = held.filter { !pressed.contains($0) }
        let added = pressed.filter { !held.contains($0) }
        held = held.filter { pressed.contains($0) } + added
        return released.map { .released($0, at: time) } + added.map { .pressed($0, at: time) }
    }

    /// Releases everything held, in press order (the mouse went away or the app lost the foreground).
    public mutating func releaseAll(at time: TimeInterval) -> [MouseEvent] {
        defer { held = [] }
        return held.map { .released($0, at: time) }
    }
}
