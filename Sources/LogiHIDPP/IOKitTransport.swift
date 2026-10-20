import Foundation
import IOKit.hid
import Synchronization

/// The vendor (HID++) interface of a Logitech receiver, opened through `IOHIDManager`.
///
/// Every receiver of the process lives on one dedicated thread with its own run loop (`HIDThread`): the manager's
/// arrival and removal callbacks and every receiver's input-report callback run there. `send` may be called from any
/// thread (`IOHIDDeviceSetReport` on an opened device is thread-safe).
///
/// `events` hands out a new stream on every access (each `HIDPPChannel` reads its own): reports from the moment of the
/// access on, then `.removed` when the receiver is unplugged, after which the stream finishes. A stream taken after the
/// removal yields `.removed` at once.
public final class IOKitTransport: HIDPPTransport, @unchecked Sendable {
    /// The receiver's name as IOKit reports it (a Bolt receiver: "USB Receiver").
    public let productName: String
    /// The receiver's USB product ID (Bolt `0xC548`).
    public let productID: Int

    /// Retained for the transport's whole life. Touched on the HID thread, except by `send` (thread-safe).
    private let device: IOHIDDevice
    /// Input-report buffer handed to IOKit; freed in `deinit`, after the callback is unregistered.
    private let buffer: UnsafeMutablePointer<UInt8>
    private let hub = TransportEventHub()
    private let removed = Atomic<Bool>(false)

    static let bufferSize = 64

    fileprivate init(device: IOHIDDevice) {
        self.device = device
        productName = IOHIDDeviceGetProperty(device, kIOHIDProductKey as CFString) as? String ?? "?"
        productID = IOHIDDeviceGetProperty(device, kIOHIDProductIDKey as CFString) as? Int ?? 0
        buffer = .allocate(capacity: Self.bufferSize)
        buffer.initialize(repeating: 0, count: Self.bufferSize)
    }

    deinit {
        buffer.deallocate()
    }

    /// Receivers as they arrive: those already plugged in first, then every later arrival. Each call returns an
    /// independent stream; the same receiver is the same `IOKitTransport` instance in every stream while it stays
    /// plugged in. A re-plugged receiver is a new instance.
    public static func receivers() -> AsyncStream<IOKitTransport> {
        let (stream, continuation) = AsyncStream.makeStream(of: IOKitTransport.self)
        HIDHost.shared.subscribe(continuation)
        return stream
    }

    /// The clock of the report timestamps, now: seconds since boot (mach absolute time), the same domain as `.report`'s
    /// `at`.
    public static var currentTime: TimeInterval {
        seconds(fromMachTime: mach_absolute_time())
    }

    public var events: AsyncStream<TransportEvent> {
        hub.subscribe()
    }

    public func send(_ report: HIDPPReport) throws {
        guard !removed.load(ordering: .acquiring) else { throw HIDPPError.disconnected }
        let bytes = report.bytes
        let status = IOHIDDeviceSetReport(device, kIOHIDReportTypeOutput, CFIndex(bytes[0]), bytes, bytes.count)
        guard status == kIOReturnSuccess else { throw HIDPPError.transport(status) }
    }

    // MARK: - HID thread

    /// Opens the device and starts its input reports. Returns the IOKit status of the open.
    fileprivate func start() -> IOReturn {
        let status = IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone))
        guard status == kIOReturnSuccess else { return status }
        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDDeviceRegisterInputReportWithTimeStampCallback(device, buffer, Self.bufferSize, { context, _, _, _, _, report, length, timeStamp in
            guard let context else { return }
            let transport = Unmanaged<IOKitTransport>.fromOpaque(context).takeUnretainedValue()
            transport.received(Array(UnsafeBufferPointer(start: report, count: length)), machTime: timeStamp)
        }, context)
        return status
    }

    /// The receiver went away: stop the callback (the host drops its strong reference right after), close, announce.
    fileprivate func stop() {
        removed.store(true, ordering: .releasing)
        IOHIDDeviceRegisterInputReportWithTimeStampCallback(device, buffer, Self.bufferSize, nil, nil)
        IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone))
        hub.remove()
    }

    fileprivate func owns(_ other: IOHIDDevice) -> Bool {
        CFEqual(device, other)
    }

    private func received(_ bytes: [UInt8], machTime: UInt64) {
        // Other report IDs and lengths (none expected on this interface) are not HID++: dropped.
        guard let report = HIDPPReport(bytes: bytes) else { return }
        hub.yield(.report(report, at: Self.seconds(fromMachTime: machTime)))
    }

    // MARK: - Clock

    private static let timebase: mach_timebase_info_data_t = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return info
    }()

    static func seconds(fromMachTime time: UInt64) -> TimeInterval {
        seconds(fromMachTime: time, numer: timebase.numer, denom: timebase.denom)
    }

    /// `time × numer / denom` nanoseconds, in seconds.
    static func seconds(fromMachTime time: UInt64, numer: UInt32, denom: UInt32) -> TimeInterval {
        Double(time) * Double(numer) / Double(denom) / 1_000_000_000
    }
}

/// Fan-out of one transport's events to any number of streams, ending with `.removed`.
final class TransportEventHub: Sendable {
    private struct State {
        var nextID = 0
        var subscribers: [Int: AsyncStream<TransportEvent>.Continuation] = [:]
        var removed = false
    }

    private let state = Mutex(State())

    func subscribe() -> AsyncStream<TransportEvent> {
        let (stream, continuation) = AsyncStream.makeStream(of: TransportEvent.self)
        let accepted = state.withLock { state -> Bool in
            guard !state.removed else { return false }
            state.nextID += 1
            let id = state.nextID
            continuation.onTermination = { [weak self] _ in self?.unsubscribe(id) }
            state.subscribers[id] = continuation
            return true
        }
        if !accepted {
            continuation.yield(.removed)
            continuation.finish()
        }
        return stream
    }

    func yield(_ event: TransportEvent) {
        for continuation in state.withLock({ Array($0.subscribers.values) }) {
            continuation.yield(event)
        }
    }

    /// Yields `.removed` to every stream and finishes them; later subscribers get `.removed` at once.
    func remove() {
        let continuations = state.withLock { state -> [AsyncStream<TransportEvent>.Continuation] in
            guard !state.removed else { return [] }
            state.removed = true
            defer { state.subscribers = [:] }
            return Array(state.subscribers.values)
        }
        for continuation in continuations {
            continuation.yield(.removed)
            continuation.finish()
        }
    }

    private func unsubscribe(_ id: Int) {
        _ = state.withLock { $0.subscribers.removeValue(forKey: id) }
    }
}

/// The process's one `IOHIDManager` for Logitech receivers and the registry of their live transports. All state is
/// confined to the HID thread.
private final class HIDHost: @unchecked Sendable {
    static let shared = HIDHost()

    /// Receiver match: Logitech, the vendor collection (page `0xFF00`, usage 1) that carries HID++ reports.
    static let matching: [String: Int] = [
        kIOHIDVendorIDKey: 0x046D,
        kIOHIDPrimaryUsagePageKey: 0xFF00,
        kIOHIDPrimaryUsageKey: 0x01,
    ]

    private let thread = HIDThread()
    private var manager: IOHIDManager?
    /// Live transports, strongly held while their device is present (their input callback holds an unretained pointer).
    private var transports: [IOKitTransport] = []
    private var nextSubscriberID = 0
    private var subscribers: [Int: AsyncStream<IOKitTransport>.Continuation] = [:]

    private init() {}

    func subscribe(_ continuation: AsyncStream<IOKitTransport>.Continuation) {
        thread.perform { [self] in
            startIfNeeded()
            nextSubscriberID += 1
            let id = nextSubscriberID
            subscribers[id] = continuation
            continuation.onTermination = { [weak self] _ in
                self?.thread.perform { self?.subscribers[id] = nil }
            }
            for transport in transports { continuation.yield(transport) }
        }
    }

    private func startIfNeeded() {
        guard manager == nil else { return }
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        self.manager = manager
        IOHIDManagerSetDeviceMatching(manager, Self.matching as CFDictionary)
        let context = Unmanaged.passUnretained(self).toOpaque()   // the host is a process-wide singleton
        IOHIDManagerRegisterDeviceMatchingCallback(manager, { context, _, _, device in
            guard let context else { return }
            Unmanaged<HIDHost>.fromOpaque(context).takeUnretainedValue().arrived(device)
        }, context)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, { context, _, _, device in
            guard let context else { return }
            Unmanaged<HIDHost>.fromOpaque(context).takeUnretainedValue().left(device)
        }, context)
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
        let status = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        if status != kIOReturnSuccess {
            log("IOHIDManagerOpen failed: 0x\(String(UInt32(bitPattern: status), radix: 16))")
        }
    }

    private func arrived(_ device: IOHIDDevice) {
        guard !transports.contains(where: { $0.owns(device) }) else { return }
        let transport = IOKitTransport(device: device)
        let status = transport.start()
        guard status == kIOReturnSuccess else {
            log("IOHIDDeviceOpen failed for \(transport.productName): 0x\(String(UInt32(bitPattern: status), radix: 16))")
            return
        }
        transports.append(transport)
        for continuation in subscribers.values { continuation.yield(transport) }
    }

    private func left(_ device: IOHIDDevice) {
        guard let position = transports.firstIndex(where: { $0.owns(device) }) else { return }
        let transport = transports.remove(at: position)
        transport.stop()
    }

    private func log(_ message: String) {
        FileHandle.standardError.write(Data("LogiHIDPP: \(message)\n".utf8))
    }
}

/// One thread with its own run loop, kept alive for the process.
private final class HIDThread: @unchecked Sendable {
    private nonisolated(unsafe) var runLoop: CFRunLoop?

    init() {
        let ready = DispatchSemaphore(value: 0)
        let thread = Thread { [self] in
            runLoop = CFRunLoopGetCurrent()
            // A port keeps the run loop from returning while no IOKit source is scheduled yet.
            RunLoop.current.add(NSMachPort(), forMode: .default)
            ready.signal()
            while true { CFRunLoopRun() }
        }
        thread.name = "LogiHIDPP.HID"
        thread.qualityOfService = .userInteractive
        thread.start()
        ready.wait()
    }

    /// Runs `block` on the HID thread, in submission order.
    func perform(_ block: @escaping () -> Void) {
        guard let runLoop else { return }
        CFRunLoopPerformBlock(runLoop, CFRunLoopMode.defaultMode.rawValue, block)
        CFRunLoopWakeUp(runLoop)
    }
}
