/// Percentage and charging state reported by a mouse with the HID++ Unified Battery feature.
public struct BatteryStatus: Equatable, Sendable {
    /// The device-reported percentage, from 0 to 100.
    public let percent: Int
    /// True during normal or slow charging.
    public let isCharging: Bool
}
