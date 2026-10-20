// Bytes recorded from an MX Master 4 on a Bolt receiver, 2026-10-16 (docs/hardware-notes.md).
// Device index 2; feature indices: 0x1B04 = 13 (0x0d), 0x19B0 = 11 (0x0b), 0x19C0 = 12 (0x0c), 0x2150 = 19 (0x13).
enum Fixtures {
    /// `0x2150` function 0 (getThumbwheelInfo) reply: native 20, diverted 120 per revolution, default direction 0,
    /// capabilities 0x03 (timestamp, touch), time unit 1000 µs.
    static let thumbWheelInfo: [UInt8] = [0x11, 0x02, 0x13, 0x0a, 0x00, 0x14, 0x00, 0x78, 0x00, 0x03, 0x03, 0xe8,
                                          0, 0, 0, 0, 0, 0, 0, 0]
    /// `0x2150` function 2 (setThumbwheelReporting) params that divert / release, and the reply to either.
    static let thumbWheelDivertParams: [UInt8] = [0x01, 0x00]
    static let thumbWheelReleaseParams: [UInt8] = [0x00, 0x00]
    static let thumbWheelSetReply: [UInt8] = [0x11, 0x02, 0x13, 0x2a, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]

    /// Thumb-wheel notifications (function 0, software ID 0). Params: rotation Int16 BE, time since the previous event
    /// UInt16 BE (ms), rotation status (0 none, 1 start, 2 active, 3 stop), flags (bit 1 = finger on the wheel).
    static let thumbWheelTouch: [UInt8] =        [0x11, 0x02, 0x13, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x02, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]
    static let thumbWheelLift: [UInt8] =         [0x11, 0x02, 0x13, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]
    static let thumbWheelStartPlus: [UInt8] =    [0x11, 0x02, 0x13, 0x00, 0x00, 0x01, 0x00, 0x00, 0x01, 0x02, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]
    static let thumbWheelActivePlus: [UInt8] =   [0x11, 0x02, 0x13, 0x00, 0x00, 0x01, 0x00, 0x79, 0x02, 0x02, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]
    static let thumbWheelStartMinus: [UInt8] =   [0x11, 0x02, 0x13, 0x00, 0xff, 0xff, 0x00, 0x00, 0x01, 0x02, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]
    static let thumbWheelActiveMinus: [UInt8] =  [0x11, 0x02, 0x13, 0x00, 0xff, 0xff, 0x01, 0x8d, 0x02, 0x02, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]
    static let thumbWheelStop: [UInt8] =         [0x11, 0x02, 0x13, 0x00, 0x00, 0x00, 0x00, 0x00, 0x03, 0x00, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]

    /// HID++ 1.0 device-connection notices from the receiver (sub-ID 0x41): the mouse switched off, then on.
    /// Byte 4 bit 6 set = link not established.
    static let connectionLost: [UInt8] = [0x10, 0x02, 0x41, 0x10, 0x42, 0x42, 0xb0]
    static let connectionUp: [UInt8] =   [0x10, 0x02, 0x41, 0x10, 0x02, 0x42, 0xb0]

    /// Diverted-button notifications (`0x1B04` function 0): the haptic panel pressed, then released.
    static let panelPressed: [UInt8] =  [0x11, 0x02, 0x0d, 0x00, 0x01, 0xa0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]
    static let allReleased: [UInt8] =   [0x11, 0x02, 0x0d, 0x00, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]

    /// Analytics key events (`0x1B04` function 2, software ID 0; docs/hardware-notes.md): params `cid_hi cid_lo state`
    /// (1 pressed, 0 released), as recorded with the back and forward buttons watched.
    static let forwardPressedAnalytics: [UInt8] =  [0x11, 0x02, 0x0d, 0x20, 0x00, 0x56, 0x01, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]
    static let forwardReleasedAnalytics: [UInt8] = [0x11, 0x02, 0x0d, 0x20, 0x00, 0x56, 0x00, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]
    static let backPressedAnalytics: [UInt8] =     [0x11, 0x02, 0x0d, 0x20, 0x00, 0x53, 0x01, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]
    static let backReleasedAnalytics: [UInt8] =    [0x11, 0x02, 0x0d, 0x20, 0x00, 0x53, 0x00, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]

    /// `0x19B0` function 1 reply: haptics enabled, intensity 25.
    static let hapticConfig: [UInt8] = [0x11, 0x02, 0x0b, 0x1a, 0x01, 0x19, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]

    /// `0x19B0` function 2 (set config) reply to writing `01 23` (enabled, strength 35): the params echoed.
    static let hapticStrengthEcho: [UInt8] = [0x11, 0x02, 0x0b, 0x2a, 0x01, 0x23, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
                                              0, 0, 0, 0]

    /// `0x19C0` (Force Sensing Button) function 0 reply: one button.
    static let forceButtonCount: [UInt8] = [0x11, 0x02, 0x0c, 0x0a, 0x01, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]
    /// `0x19C0` function 1 (`00`) reply: changeable 0x0001, default 4749 (0x128d), max 6316 (0x18ac),
    /// min 3799 (0x0ed7).
    static let forceInfo: [UInt8] = [0x11, 0x02, 0x0c, 0x1a, 0x00, 0x01, 0x12, 0x8d, 0x18, 0xac, 0x0e, 0xd7,
                                     0, 0, 0, 0, 0, 0, 0, 0]
    /// `0x19C0` function 2 (`00`) reply: current 4749.
    static let forceCurrent: [UInt8] = [0x11, 0x02, 0x0c, 0x2a, 0x12, 0x8d, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]
}
