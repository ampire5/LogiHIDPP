import Foundation

/// What a transport delivers: an incoming report with its arrival time, or the device going away.
public enum TransportEvent: Sendable {
    /// `at`: arrival time in seconds on a monotonic clock (the transport chooses which; only differences matter).
    case report(HIDPPReport, at: TimeInterval)
    /// The receiver was unplugged or the interface closed; no further events follow.
    case removed
}

/// One open HID++ interface (a receiver's vendor collection). `IOKitTransport` talks to hardware; tests use a fake.
public protocol HIDPPTransport: AnyObject, Sendable {
    /// Writes one report. Throws `HIDPPError.transport` with the IOKit status on failure.
    func send(_ report: HIDPPReport) throws
    /// Incoming reports, in arrival order. A transport may return one shared stream (then a single consumer, the
    /// `HIDPPChannel`, reads it) or a new stream per access (`IOKitTransport`).
    var events: AsyncStream<TransportEvent> { get }
}

public enum HIDPPError: Error, Equatable, Sendable {
    /// No reply within the channel's timeout.
    case timeout
    /// HID++ 1.0 error reply (`0x8F`), with its code (e.g. `0x09`: unknown device, an empty receiver slot).
    case hidpp1(UInt8)
    /// HID++ 2.0 error reply (feature index `0xFF`), with its code.
    case hidpp2(UInt8)
    /// The device does not have this feature (the root feature returned index 0).
    case featureMissing(UInt16)
    /// The transport failed to send (IOKit status).
    case transport(Int32)
    /// The transport was removed while the request waited, or before it was sent.
    case disconnected
}

/// The HID++ protocol version a device reports to a ping (MX Master 4: 4.5).
public struct HIDPPVersion: Equatable, Sendable {
    public let major, minor: UInt8

    public init(major: UInt8, minor: UInt8) {
        self.major = major
        self.minor = minor
    }
}

/// Unsolicited reports from the receiver and its devices.
public enum HIDPPNotification: Equatable, Sendable {
    /// A HID++ 2.0 feature event (software ID 0), e.g. diverted buttons from REPROG_CONTROLS_V4 function 0.
    case feature(device: UInt8, featureIndex: UInt8, function: UInt8, params: [UInt8], at: TimeInterval)
    /// The receiver's HID++ 1.0 device-connection notice (sub-ID `0x41`): the device linked or lost its link.
    case connection(device: UInt8, linked: Bool)
}
