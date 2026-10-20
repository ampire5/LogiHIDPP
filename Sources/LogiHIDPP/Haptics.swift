import Foundation

/// A haptic waveform the MX Master 4 can play. Numbers and names are Logitech's (as listed in Solaar's
/// `HapticWaveForms`): `0x00…0x0E` and `0x1B`. "Collision" patterns suit stops and limits, "state change" toggles.
public struct HapticPattern: Hashable, Sendable {
    public let rawValue: UInt8
    /// Logitech's name, lower case: "sharp state change".
    public let name: String

    public static let sharpStateChange = HapticPattern(0x00, "sharp state change")
    public static let dampStateChange = HapticPattern(0x01, "damp state change")
    public static let sharpCollision = HapticPattern(0x02, "sharp collision")
    public static let dampCollision = HapticPattern(0x03, "damp collision")
    public static let subtleCollision = HapticPattern(0x04, "subtle collision")
    public static let happyAlert = HapticPattern(0x05, "happy alert")
    public static let angryAlert = HapticPattern(0x06, "angry alert")
    public static let completed = HapticPattern(0x07, "completed")
    public static let square = HapticPattern(0x08, "square")
    public static let wave = HapticPattern(0x09, "wave")
    public static let firework = HapticPattern(0x0A, "firework")
    public static let mad = HapticPattern(0x0B, "mad")
    public static let knock = HapticPattern(0x0C, "knock")
    public static let jingle = HapticPattern(0x0D, "jingle")
    public static let ringing = HapticPattern(0x0E, "ringing")
    public static let whisperCollision = HapticPattern(0x1B, "whisper collision")

    /// Every pattern, in number order.
    public static let all: [HapticPattern] = [
        .sharpStateChange, .dampStateChange, .sharpCollision, .dampCollision, .subtleCollision, .happyAlert,
        .angryAlert, .completed, .square, .wave, .firework, .mad, .knock, .jingle, .ringing, .whisperCollision,
    ]

    private init(_ raw: UInt8, _ name: String) {
        rawValue = raw
        self.name = name
    }

    /// The pattern with this number; nil for a number the mouse doesn't know.
    public init?(_ raw: UInt8) {
        guard let p = Self.all.first(where: { $0.rawValue == raw }) else { return nil }
        self = p
    }

    /// The pattern with this name (any case, spaces, hyphens or underscores: "Whisper-Collision").
    public init?(named text: String) {
        let key = text.lowercased().replacingOccurrences(of: "-", with: " ").replacingOccurrences(of: "_", with: " ")
        guard let p = Self.all.first(where: { $0.name == key }) else { return nil }
        self = p
    }
}

extension HapticPattern {
    /// The name as config files spell it: hyphenated, "whisper-collision".
    public var configName: String {
        name.replacingOccurrences(of: " ", with: "-")
    }
}

/// A `haptic-*` config value: the pattern to play and whether it plays at the app's strong strength rather than the
/// mouse's normal one. Shared by the apps that read such values (Loupe, FrameScrub).
public struct HapticChoice: Equatable, Sendable {
    public let pattern: HapticPattern
    /// Played at the strong strength (the value ends in ` strong`).
    public let strong: Bool

    public init(pattern: HapticPattern, strong: Bool = false) {
        self.pattern = pattern
        self.strong = strong
    }

    /// A config value: a name (any case, `-` `_` or space), the decimal or `0x` number of a known pattern, or `none`,
    /// optionally followed by ` strong` (any case, after spaces or tabs). `.some(nil)` is `none`; nil is anything that
    /// is not a pattern (`strong` alone, `none strong`, an unknown number, a signed number).
    public static func parse(_ text: String) -> HapticChoice?? {
        let t = text.trimmingCharacters(in: .whitespaces)
        var strong = false
        var head = Substring(t)
        if let gap = t.lastIndex(where: { $0 == " " || $0 == "\t" }),
           t[t.index(after: gap)...].lowercased() == "strong" {
            strong = true
            head = t[..<gap]
        }
        let key = head.trimmingCharacters(in: .whitespaces).lowercased()
        if key == "none" { return strong ? nil : .some(nil) }
        let pattern: HapticPattern?
        if let number = number(key) {
            pattern = UInt8(exactly: number).flatMap { HapticPattern($0) }
        } else {
            pattern = HapticPattern(named: key)
        }
        guard let pattern else { return nil }
        return .some(HapticChoice(pattern: pattern, strong: strong))
    }

    /// The value as a config file spells it: the hyphenated lower-case name, with ` strong` when it plays strong, or
    /// `none` for nil.
    public static func text(_ choice: HapticChoice?) -> String {
        guard let choice else { return "none" }
        return choice.pattern.configName + (choice.strong ? " strong" : "")
    }

    /// `[0-9]+` or `0x[0-9a-f]+` (lower case), nothing else: no sign, no separators.
    private static func number(_ key: String) -> Int? {
        if key.hasPrefix("0x") {
            let digits = key.dropFirst(2)
            guard !digits.isEmpty, digits.allSatisfy(\.isHexDigit) else { return nil }
            return Int(digits, radix: 16)
        }
        guard !key.isEmpty, key.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        return Int(key)
    }
}

/// HAPTIC (`0x19B0`): the byte layouts of the haptic config read and write and of the play command. The strength is
/// written only when the app asks (`LogiMouse.setHapticStrength(_:)`, `play(haptic:strength:)`).
public enum Haptics {
    public static let featureID: UInt16 = 0x19B0

    /// Decodes the reply params of the config read (function 1): `enabled intensity`. Params too short to hold both
    /// mean haptics off: `(false, 0)`.
    public static func config(from params: [UInt8]) -> (enabled: Bool, intensity: UInt8) {
        guard params.count >= 2 else { return (false, 0) }
        return (params[0] != 0, params[1])
    }

    /// Params of the config write (function 2): haptics enabled, `strength` (0…100). The mouse echoes them in its
    /// reply. Writing it switches haptics on, so it is never sent to a mouse whose haptics are off.
    public static func setConfigParams(strength: UInt8) -> [UInt8] {
        [0x01, strength]
    }

    /// Params of the play command (function 4): the pattern number.
    public static func playParams(_ p: HapticPattern) -> [UInt8] {
        [p.rawValue]
    }
}

/// A one-value slot where a new value replaces the one not yet taken: bursts collapse to the latest.
public struct LatestOnly<Value: Sendable>: Sendable {
    private var value: Value?

    public init() {}

    public mutating func put(_ v: Value) {
        value = v
    }

    /// The value waiting, if any; the slot is empty afterwards.
    public mutating func take() -> Value? {
        defer { value = nil }
        return value
    }
}
