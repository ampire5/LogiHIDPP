import Foundation
import Synchronization

/// HID++ 2.0 over one transport: matches replies to requests, maps error replies to `HIDPPError`, caches feature
/// indices per device and fans unsolicited reports out to any number of `notifications` streams.
///
/// Every request carries the channel's `softwareID` (by default this process's, `HIDPPSoftwareID.process`) and only
/// replies with that ID answer it: another process on the same receiver uses another ID.
///
/// One task reads `transport.events` for the channel's lifetime. It stops when the transport emits `.removed` (or its
/// stream ends), which also fails every waiting request with `.disconnected`, makes later requests throw at once and
/// finishes every notification stream; and when the channel is deinitialised.
public actor HIDPPChannel {
    /// A request waits for the reply carrying the same device, feature index, function and software ID.
    private struct Key: Hashable {
        let device, feature, function, softwareID: UInt8

        init(_ report: HIDPPReport) {
            self.init(device: report.deviceIndex, feature: report.featureIndex, function: report.function,
                      softwareID: report.softwareID)
        }

        init(device: UInt8, feature: UInt8, function: UInt8, softwareID: UInt8) {
            self.device = device
            self.feature = feature
            self.function = function
            self.softwareID = softwareID
        }
    }

    private struct Waiter {
        let id: UInt64
        let echo: [UInt8]?
        /// Called once with the reply or the failure.
        let resume: @Sendable (Result<HIDPPReport, any Error>) -> Void
        let timer: Task<Void, Never>
    }

    /// One place in a key's FIFO. A request that timed out leaves a tombstone in its place: its late reply (or error)
    /// is consumed by the tombstone instead of answering a newer request with the same key. That matters most for
    /// root lookups, which all share one key per device: a late `0x1B04` index cached as another feature's index would
    /// send later calls to the wrong feature.
    ///
    /// An entry with an echo (waiting or tombstone) claims only a successful reply whose params start with it; other
    /// replies pass on to the next entry. Calls that share a key but differ in what the reply repeats (setControlReporting
    /// for different CIDs) then stay apart: a lost reply's tombstone cannot swallow another CID's reply.
    private enum Entry {
        case waiting(Waiter)
        case tombstone(expires: ContinuousClock.Instant, echo: [UInt8]?)

        func isExpiredTombstone(at now: ContinuousClock.Instant) -> Bool {
            if case .tombstone(let expires, _) = self { expires <= now } else { false }
        }

        func claims(_ params: [UInt8]) -> Bool {
            let echo: [UInt8]?
            switch self {
            case .waiting(let waiter): echo = waiter.echo
            case .tombstone(_, let tombstoneEcho): echo = tombstoneEcho
            }
            guard let echo else { return true }
            return params.starts(with: echo)
        }
    }

    /// HID++ 1.0 short register access sub-IDs: `10 dev 80 <register> v0 v1 v2` writes, `10 dev 81 <register> 00 00 00`
    /// reads (the reply repeats the sub-ID and register, then the value).
    static let setRegisterID: UInt8 = 0x80
    static let getRegisterID: UInt8 = 0x81
    /// HID++ 1.0 error reply sub-ID: `10 dev 8f <feature> <function|sw> <code> 00`.
    static let hidpp1ErrorID: UInt8 = 0x8F
    /// HID++ 2.0 error reply feature index: `11 dev ff <feature> <function|sw> <code> …`.
    static let hidpp2ErrorID: UInt8 = 0xFF
    /// The receiver's HID++ 1.0 device-connection notice sub-ID.
    static let connectionNoticeID: UInt8 = 0x41
    /// Bit of byte 4 of the connection notice that is set while the link is down (assumed layout).
    static let linkLostMask: UInt8 = 0x40
    /// Receiver slots of a Bolt / Unifying receiver.
    static let slots: ClosedRange<UInt8> = 1...6

    /// The software ID stamped on this channel's requests (1…15; never 0, the notification ID).
    public nonisolated let softwareID: UInt8
    private let transport: any HIDPPTransport
    private let timeout: Duration
    private let lateReplyWindow: Duration
    private let hub = NotificationHub()
    /// The task reading `transport.events`. A `let` box: the initialiser starts the task after `self` escapes.
    private let reader = Mutex<Task<Void, Never>?>(nil)
    private var pending: [Key: [Entry]] = [:]
    private var nextWaiterID: UInt64 = 0
    private var featureIndices: [UInt8: [UInt16: UInt8]] = [:]
    /// Bumped by `forget`, so a lookup that was in flight across a `forget` does not refill the cache.
    private var generations: [UInt8: Int] = [:]
    private var removed = false

    /// - Parameters:
    ///   - timeout: how long a request waits for its reply (2 s by default: an idle mouse takes up to ~1 s).
    ///   - softwareID: the ID stamped on requests (1…15); nil, the default, uses this process's
    ///     (`HIDPPSoftwareID.process`). Two channels of one process may share it only if they never talk to the same
    ///     receiver at the same time.
    public init(transport: any HIDPPTransport, timeout: Duration = .seconds(2), softwareID: UInt8? = nil) {
        self.init(transport: transport, timeout: timeout, lateReplyWindow: .seconds(5), softwareID: softwareID)
    }

    /// - Parameter lateReplyWindow: how long a timed-out request still claims its late reply (its tombstone lives).
    init(transport: any HIDPPTransport, timeout: Duration, lateReplyWindow: Duration, softwareID: UInt8? = nil) {
        let softwareID = softwareID ?? HIDPPSoftwareID.process
        precondition((1...15).contains(softwareID), "HID++ software ID must be 1…15 (0 is the notification ID)")
        self.softwareID = softwareID
        self.transport = transport
        self.timeout = timeout
        self.lateReplyWindow = lateReplyWindow
        let events = transport.events
        let task = Task { [weak self] in
            for await event in events {
                guard let self, await self.handle(event) else { return }
            }
            await self?.transportEnded()
        }
        reader.withLock { $0 = task }
    }

    deinit {
        reader.withLock { $0 }?.cancel()
        hub.finish()
    }

    /// Unsolicited reports, from the moment of the call on; every call returns a new independent stream. The stream
    /// finishes when the transport is removed or the channel goes away.
    public nonisolated var notifications: AsyncStream<HIDPPNotification> {
        hub.subscribe()
    }

    /// Sends `report` with this channel's software ID stamped on it and waits for its reply (same device, feature
    /// index, function and software ID; with `echo`, also params starting with `echo`). Error replies are matched
    /// without the echo (they do not carry params). Throws `.hidpp1` / `.hidpp2` for an error reply, `.timeout`,
    /// `.transport` or `.disconnected`. For HID++ 1.0 register access use `readRegister` / `writeRegister`.
    public func request(_ report: HIDPPReport, echo: [UInt8]? = nil) async throws -> HIDPPReport {
        try await exchange(report.stamped(softwareID: softwareID), echo: echo)
    }

    /// Reads HID++ 1.0 short register `address` of `device` (`0xFF`: the receiver itself); returns its 3 value bytes.
    /// Register replies carry no software ID: a read of the same register by another program at the same moment may
    /// answer this one (with the same value).
    public func readRegister(device: UInt8 = 0xFF, address: UInt8) async throws -> [UInt8] {
        let reply = try await exchange(.short(device: device, feature: Self.getRegisterID, function: address >> 4,
                                              softwareID: address & 0x0F, params: []), echo: nil)
        return Array(reply.params.prefix(3))
    }

    /// Writes the 3 value bytes of HID++ 1.0 short register `address` of `device` (`0xFF`: the receiver itself).
    public func writeRegister(device: UInt8 = 0xFF, address: UInt8, value: [UInt8]) async throws {
        precondition(value.count == 3, "a short register holds 3 bytes")
        _ = try await exchange(.short(device: device, feature: Self.setRegisterID, function: address >> 4,
                                      softwareID: address & 0x0F, params: value), echo: nil)
    }

    /// Like `request(_:echo:)`, but returns once the report is sent: the returned task waits for the reply. What the
    /// caller sends after this call returns goes out after `report`, and the caller need not wait for the reply.
    func sendRequest(_ report: HIDPPReport, echo: [UInt8]? = nil) -> Task<HIDPPReport, any Error> {
        let (reply, continuation) = AsyncThrowingStream.makeStream(of: HIDPPReport.self)
        start(report.stamped(softwareID: softwareID), echo: echo) { result in
            switch result {
            case .success(let report):
                continuation.yield(report)
                continuation.finish()
            case .failure(let error):
                continuation.finish(throwing: error)
            }
        }
        return Task {
            for try await report in reply { return report }
            throw HIDPPError.disconnected
        }
    }

    /// Sends `report` as it is and waits for its reply.
    private func exchange(_ report: HIDPPReport, echo: [UInt8]?) async throws -> HIDPPReport {
        try await withCheckedThrowingContinuation { continuation in
            start(report, echo: echo) { continuation.resume(with: $0) }
        }
    }

    /// Registers a waiter for `report`'s reply and sends `report` as it is; `resume` gets the outcome.
    private func start(_ report: HIDPPReport, echo: [UInt8]?,
                       resume: @escaping @Sendable (Result<HIDPPReport, any Error>) -> Void) {
        guard !removed else {
            resume(.failure(HIDPPError.disconnected))
            return
        }
        let key = Key(report)
        nextWaiterID &+= 1
        let id = nextWaiterID
        let timer = Task { [weak self, timeout] in
            do { try await Task.sleep(for: timeout) } catch { return }
            await self?.expire(id: id, key: key)
        }
        pending[key, default: []].append(.waiting(Waiter(id: id, echo: echo, resume: resume, timer: timer)))
        do {
            try transport.send(report)
        } catch {
            if let waiter = take(id: id, key: key) {
                waiter.timer.cancel()
                waiter.resume(.failure(error))
            }
        }
    }

    /// Sends `report`, with this channel's software ID stamped on it, without waiting for a reply.
    public func post(_ report: HIDPPReport) throws {
        guard !removed else { throw HIDPPError.disconnected }
        try transport.send(report.stamped(softwareID: softwareID))
    }

    /// Root feature, function 1 (`ping`): the device's HID++ version. An empty receiver slot throws `.hidpp1(0x09)`.
    public func ping(device: UInt8) async throws -> HIDPPVersion {
        let reply = try await request(.short(device: device, feature: 0, function: 1, params: [0x00, 0x00, 0x5A]))
        return HIDPPVersion(major: reply.params[0], minor: reply.params[1])
    }

    /// Pings every receiver slot at once; returns the slots that answered, ascending.
    public func discover() async -> [UInt8] {
        await withTaskGroup(of: UInt8?.self) { group in
            for device in Self.slots {
                group.addTask { (try? await self.ping(device: device)) == nil ? nil : device }
            }
            var found: [UInt8] = []
            for await device in group {
                if let device { found.append(device) }
            }
            return found.sorted()
        }
    }

    /// The index of feature `id` on `device` (root feature, function 0), cached until `forget(device:)`.
    /// Throws `.featureMissing` when the device does not have it.
    public func featureIndex(_ id: UInt16, device: UInt8) async throws -> UInt8 {
        if id == 0x0000 { return 0 }
        if let index = featureIndices[device]?[id] { return index }
        let generation = generations[device, default: 0]
        let reply = try await request(.short(device: device, feature: 0, function: 0,
                                             params: [UInt8(id >> 8), UInt8(id & 0xFF)]))
        let index = reply.params[0]
        guard index != 0 else { throw HIDPPError.featureMissing(id) }
        if generations[device, default: 0] == generation {
            featureIndices[device, default: [:]][id] = index
        }
        return index
    }

    /// Calls `function` of feature `feature` on `device`: a short report for up to 3 params, long beyond. Returns the
    /// reply's params (3 or 16 bytes). `echo`: see `request(_:echo:)`.
    public func call(_ feature: UInt16, device: UInt8, function: UInt8, params: [UInt8] = [],
                     echo: [UInt8]? = nil) async throws -> [UInt8] {
        let index = try await featureIndex(feature, device: device)
        let report = params.count > 3
            ? HIDPPReport.long(device: device, feature: index, function: function, params: params)
            : HIDPPReport.short(device: device, feature: index, function: function, params: params)
        return try await request(report, echo: echo).params
    }

    /// Drops the cached feature indices of `device` (it reconnected, or another device took its slot).
    public func forget(device: UInt8) {
        featureIndices[device] = nil
        generations[device, default: 0] += 1
    }

    // MARK: - Reader

    /// Returns false when the reader should stop.
    private func handle(_ event: TransportEvent) -> Bool {
        switch event {
        case .report(let report, let time):
            route(report, at: time)
            return true
        case .removed:
            transportEnded()
            return false
        }
    }

    private func route(_ report: HIDPPReport, at time: TimeInterval) {
        let id = report.featureIndex
        if id == Self.hidpp1ErrorID || id == Self.hidpp2ErrorID {
            // Bytes 3–4 echo the failed request's feature index and `function << 4 | softwareID`; byte 5 is the code.
            let failed = Key(device: report.deviceIndex, feature: report.bytes[3], function: report.bytes[4] >> 4,
                             softwareID: report.bytes[4] & 0x0F)
            let code = report.bytes[5]
            complete(failed, with: .failure(id == Self.hidpp2ErrorID ? .hidpp2(code) : .hidpp1(code)))
            return   // an error for someone else's request (another program on the receiver) is dropped
        }
        if complete(Key(report), with: .success(report)) { return }
        if id == Self.connectionNoticeID {
            hub.yield(.connection(device: report.deviceIndex, linked: report.bytes[4] & Self.linkLostMask == 0))
        } else if report.softwareID == 0 && id < 0x80 {
            // Feature events carry software ID 0. Sub-IDs 0x80… are HID++ 1.0 register traffic, never feature events.
            hub.yield(.feature(device: report.deviceIndex, featureIndex: id, function: report.function,
                               params: report.params, at: time))
        }
        // Anything else is a reply to another program's request (it uses another software ID): dropped.
    }

    /// Hands `result` to the oldest live entry on `key` that claims it (an error: the oldest live entry): a waiting
    /// request is resumed, a tombstone swallows it. False when nothing claims it.
    @discardableResult
    private func complete(_ key: Key, with result: Result<HIDPPReport, HIDPPError>) -> Bool {
        guard var queue = pending[key] else { return false }
        let now = ContinuousClock.now
        queue.removeAll { $0.isExpiredTombstone(at: now) }
        let position: Int?
        switch result {
        case .success(let report): position = queue.firstIndex { $0.claims(report.params) }
        case .failure: position = queue.indices.first
        }
        guard let position else {
            pending[key] = queue.isEmpty ? nil : queue
            return false
        }
        let entry = queue.remove(at: position)
        pending[key] = queue.isEmpty ? nil : queue
        if case .waiting(let waiter) = entry {
            waiter.timer.cancel()
            waiter.resume(result.mapError { $0 })
        }
        return true
    }

    /// The request timed out: it throws `.timeout` and leaves a tombstone in its place for `lateReplyWindow`.
    private func expire(id: UInt64, key: Key) {
        guard var queue = pending[key], let position = position(of: id, in: queue),
              case .waiting(let waiter) = queue[position] else { return }
        let now = ContinuousClock.now
        queue[position] = .tombstone(expires: now + lateReplyWindow, echo: waiter.echo)
        queue.removeAll { $0.isExpiredTombstone(at: now) }
        pending[key] = queue
        waiter.resume(.failure(HIDPPError.timeout))
    }

    /// Removes a waiting request without a tombstone (its report was never sent).
    private func take(id: UInt64, key: Key) -> Waiter? {
        guard var queue = pending[key], let position = position(of: id, in: queue),
              case .waiting(let waiter) = queue.remove(at: position) else { return nil }
        pending[key] = queue.isEmpty ? nil : queue
        return waiter
    }

    private func position(of id: UInt64, in queue: [Entry]) -> Int? {
        queue.firstIndex { entry in
            if case .waiting(let waiter) = entry { waiter.id == id } else { false }
        }
    }

    private func transportEnded() {
        guard !removed else { return }
        removed = true
        let waiters = pending.values.joined().compactMap { entry -> Waiter? in
            if case .waiting(let waiter) = entry { waiter } else { nil }
        }
        pending = [:]
        for waiter in waiters {
            waiter.timer.cancel()
            waiter.resume(.failure(HIDPPError.disconnected))
        }
        hub.finish()
    }
}

/// Fan-out of notifications to any number of streams. Subscribing is nonisolated, so the state sits behind a mutex;
/// continuations are yielded and finished outside it (finishing runs `onTermination`, which takes the lock again).
final class NotificationHub: Sendable {
    private struct State {
        var nextID = 0
        var subscribers: [Int: AsyncStream<HIDPPNotification>.Continuation] = [:]
        var finished = false
    }

    private let state = Mutex(State())

    func subscribe() -> AsyncStream<HIDPPNotification> {
        let (stream, continuation) = AsyncStream.makeStream(of: HIDPPNotification.self)
        let accepted = state.withLock { state -> Bool in
            guard !state.finished else { return false }
            state.nextID += 1
            let id = state.nextID
            continuation.onTermination = { [weak self] _ in self?.unsubscribe(id) }
            state.subscribers[id] = continuation
            return true
        }
        if !accepted { continuation.finish() }
        return stream
    }

    func yield(_ notification: HIDPPNotification) {
        for continuation in state.withLock({ Array($0.subscribers.values) }) {
            continuation.yield(notification)
        }
    }

    func finish() {
        let continuations = state.withLock { state in
            state.finished = true
            defer { state.subscribers = [:] }
            return Array(state.subscribers.values)
        }
        for continuation in continuations { continuation.finish() }
    }

    private func unsubscribe(_ id: Int) {
        _ = state.withLock { $0.subscribers.removeValue(forKey: id) }
    }
}
