import Foundation
import Synchronization
@testable import LogiHIDPP

/// A transport without hardware: records every sent report, answers scripted requests (matched by the sent report's
/// exact bytes) and lets a test push arbitrary incoming reports or a removal.
final class FakeTransport: HIDPPTransport {
    private struct State {
        var sent: [HIDPPReport] = []
        var script: [[UInt8]: [[UInt8]]] = [:]
        var sendError: HIDPPError?
        var terminated = false
    }

    private let state = Mutex(State())
    private let continuation: AsyncStream<TransportEvent>.Continuation
    let events: AsyncStream<TransportEvent>

    init() {
        let (stream, continuation) = AsyncStream.makeStream(of: TransportEvent.self)
        events = stream
        self.continuation = continuation
        continuation.onTermination = { [weak self] _ in self?.state.withLock { $0.terminated = true } }
    }

    /// When a report with exactly `request` bytes is sent, `replies` arrive in order.
    func script(_ request: [UInt8], replies: [[UInt8]]) {
        state.withLock { $0.script[request] = replies }
    }

    func failSends(with error: HIDPPError?) {
        state.withLock { $0.sendError = error }
    }

    var sent: [HIDPPReport] { state.withLock { $0.sent } }

    /// The channel stopped reading: its iteration of `events` was cancelled.
    var terminated: Bool { state.withLock { $0.terminated } }

    func send(_ report: HIDPPReport) throws {
        let replies = try state.withLock { state -> [[UInt8]] in
            if let error = state.sendError { throw error }
            state.sent.append(report)
            return state.script[report.bytes] ?? []
        }
        for reply in replies { push(reply) }
    }

    func push(_ bytes: [UInt8], at time: TimeInterval = 0) {
        guard let report = HIDPPReport(bytes: bytes) else {
            preconditionFailure("bad fixture \(bytes)")
        }
        continuation.yield(.report(report, at: time))
    }

    func pushRemoved() {
        continuation.yield(.removed)
    }
}

/// Builds a full-length report from the bytes a probe log shows, zero-padding the rest (`11 02 00 1a 04 05 5a …`).
func bytes(_ prefix: UInt8...) -> [UInt8] {
    let length = prefix.first == 0x11 ? 20 : 7
    return prefix + [UInt8](repeating: 0, count: max(0, length - prefix.count))
}

/// Waits (polling, at most `limit`) until `condition` holds. Runs on the caller's actor, so main-actor tests can poll
/// main-actor state.
func eventually(_ limit: Duration = .seconds(1), isolation: isolated (any Actor)? = #isolation,
                _ condition: () async -> Bool) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now + limit
    while clock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(2))
    }
    return await condition()
}

/// Collects up to `count` elements of `stream`, giving up after `limit`, so a missing element fails the test instead
/// of hanging it.
func collect<T: Sendable>(_ stream: AsyncStream<T>, count: Int, within limit: Duration = .seconds(1)) async -> [T] {
    let collector = Task {
        var out: [T] = []
        for await element in stream {
            out.append(element)
            if out.count == count { break }
        }
        return out
    }
    let watchdog = Task {
        try? await Task.sleep(for: limit)
        collector.cancel()
    }
    let result = await collector.value
    watchdog.cancel()
    return result
}

struct StillWaiting: Error {}

/// The outcome of `task`, or `StillWaiting` after `limit`, so a request that never completes fails the test instead of
/// hanging the suite. (A task group would wait for the stuck child; two unstructured tasks race for one resume.)
func outcome<T: Sendable>(of task: Task<T, any Error>, within limit: Duration = .seconds(1)) async -> Result<T, any Error> {
    let resumed = Mutex(false)
    return await withCheckedContinuation { (continuation: CheckedContinuation<Result<T, any Error>, Never>) in
        let resumeOnce: @Sendable (Result<T, any Error>) -> Void = { result in
            if resumed.withLock({ done in defer { done = true }; return !done }) { continuation.resume(returning: result) }
        }
        Task { resumeOnce(await task.result) }
        Task {
            try? await Task.sleep(for: limit)
            resumeOnce(.failure(StillWaiting()))
        }
    }
}

/// Whether `stream` finishes on its own within `limit`: true only when `for await` ran out of elements, not when the
/// watchdog stopped it.
func ends<T: Sendable>(_ stream: AsyncStream<T>, within limit: Duration = .milliseconds(500)) async -> Bool {
    let reader = Task {
        for await _ in stream {}
        return !Task.isCancelled
    }
    let watchdog = Task {
        try? await Task.sleep(for: limit)
        reader.cancel()
    }
    defer { watchdog.cancel() }
    return await reader.value
}

/// Something that answers scripted requests: `FakeTransport`, or a `SharedReceiver` behind several transports.
protocol ScriptedReceiver {
    func script(_ request: [UInt8], replies: [[UInt8]])
}

extension FakeTransport: ScriptedReceiver {}

/// One receiver opened by several clients (processes), as macOS delivers it: every incoming report — the reply to any
/// client's request as well as a notification — reaches every client's transport.
///
/// Like a real device it echoes the requester's software ID: a HID++ 2.0 request is looked up in the script with its
/// software ID ignored, and every reply to it carries the requester's ID (byte 3, or byte 4 of an error reply). HID++
/// 1.0 register access (sub-IDs `0x80…0x8E`) has no software ID and is matched and answered as it is.
final class SharedReceiver: ScriptedReceiver, Sendable {
    /// One client's open handle of the receiver.
    final class Endpoint: HIDPPTransport {
        let events: AsyncStream<TransportEvent>
        fileprivate let continuation: AsyncStream<TransportEvent>.Continuation
        private let receiver: SharedReceiver
        private let log = Mutex<[HIDPPReport]>([])

        fileprivate init(receiver: SharedReceiver) {
            self.receiver = receiver
            (events, continuation) = AsyncStream.makeStream(of: TransportEvent.self)
        }

        var sent: [HIDPPReport] { log.withLock { $0 } }

        func send(_ report: HIDPPReport) throws {
            log.withLock { $0.append(report) }
            receiver.received(report)
        }
    }

    private struct State {
        var script: [[UInt8]: [[UInt8]]] = [:]
        var endpoints: [Endpoint] = []
    }

    private let state = Mutex(State())

    /// A new client's transport.
    func endpoint() -> Endpoint {
        let endpoint = Endpoint(receiver: self)
        state.withLock { $0.endpoints.append(endpoint) }
        return endpoint
    }

    /// When a request matching `request` (software ID ignored) is sent, `replies` arrive at every client, stamped with
    /// the requester's software ID.
    func script(_ request: [UInt8], replies: [[UInt8]]) {
        state.withLock { $0.script[Self.key(request)] = replies }
    }

    /// Delivers `bytes` to every client as they are.
    func broadcast(_ bytes: [UInt8]) {
        guard let report = HIDPPReport(bytes: bytes) else { preconditionFailure("bad fixture \(bytes)") }
        for endpoint in state.withLock({ $0.endpoints }) { endpoint.continuation.yield(.report(report, at: 0)) }
    }

    fileprivate func received(_ report: HIDPPReport) {
        let replies = state.withLock { $0.script[Self.key(report.bytes)] ?? [] }
        for reply in replies { broadcast(Self.stamp(reply, softwareID: report.softwareID)) }
    }

    private static func isRegister(_ subID: UInt8) -> Bool { subID & 0xF0 == 0x80 && subID != 0x8F }

    private static func key(_ request: [UInt8]) -> [UInt8] {
        guard !isRegister(request[2]) else { return request }
        var key = request
        key[3] &= 0xF0
        return key
    }

    private static func stamp(_ reply: [UInt8], softwareID: UInt8) -> [UInt8] {
        var reply = reply
        switch reply[2] {
        case 0xFF: reply[4] = reply[4] & 0xF0 | softwareID
        case 0x8F where !isRegister(reply[3]): reply[4] = reply[4] & 0xF0 | softwareID
        case let subID where subID < 0x80: reply[3] = reply[3] & 0xF0 | softwareID
        default: break
        }
        return reply
    }
}

/// A hi-res marker kept in memory, not in UserDefaults.
final class MemoryHiResMarker: HiResMarker {
    private let value: Mutex<Bool>

    init(_ isSet: Bool = false) {
        value = Mutex(isSet)
    }

    var isSet: Bool {
        get { value.withLock { $0 } }
        set { value.withLock { $0 = newValue } }
    }
}

/// A wheel-mode marker kept in memory, not in UserDefaults.
final class MemoryWheelModeMarker: WheelModeMarker {
    private let value: Mutex<WheelMode?>

    init(_ saved: WheelMode? = nil) {
        value = Mutex(saved)
    }

    var saved: WheelMode? {
        get { value.withLock { $0 } }
        set { value.withLock { $0 = newValue } }
    }
}
