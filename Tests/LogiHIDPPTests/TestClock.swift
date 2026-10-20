import Synchronization

/// A clock that moves only when a test calls `advance(by:)`. A sleeper whose deadline has passed returns at once;
/// cancelling a sleeper makes it throw `CancellationError`.
final class TestClock: Clock, Sendable {
    struct Instant: InstantProtocol {
        let offset: Duration

        func advanced(by duration: Duration) -> Instant { Instant(offset: offset + duration) }
        func duration(to other: Instant) -> Duration { other.offset - offset }
        static func < (lhs: Instant, rhs: Instant) -> Bool { lhs.offset < rhs.offset }
    }

    private struct Sleeper {
        let deadline: Instant
        let continuation: CheckedContinuation<Void, any Error>
    }

    private struct State {
        var now = Instant(offset: .zero)
        var nextID: UInt64 = 0
        var sleepers: [UInt64: Sleeper] = [:]
        /// Sleepers cancelled before they registered their continuation.
        var cancelled: Set<UInt64> = []
    }

    private let state = Mutex(State())

    var now: Instant { state.withLock { $0.now } }
    var minimumResolution: Duration { .zero }

    /// Sleepers waiting for a later instant.
    var sleeperCount: Int { state.withLock { $0.sleepers.count } }

    func sleep(until deadline: Instant, tolerance: Duration?) async throws {
        let id = state.withLock { state in
            state.nextID += 1
            return state.nextID
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                enum Outcome { case wait, wake, cancel }
                let outcome = state.withLock { state -> Outcome in
                    if state.cancelled.remove(id) != nil { return .cancel }
                    if deadline <= state.now { return .wake }
                    state.sleepers[id] = Sleeper(deadline: deadline, continuation: continuation)
                    return .wait
                }
                switch outcome {
                case .wait: break
                case .wake: continuation.resume()
                case .cancel: continuation.resume(throwing: CancellationError())
                }
            }
        } onCancel: {
            let sleeper = state.withLock { state -> Sleeper? in
                if let sleeper = state.sleepers.removeValue(forKey: id) { return sleeper }
                state.cancelled.insert(id)
                return nil
            }
            sleeper?.continuation.resume(throwing: CancellationError())
        }
    }

    /// Moves the clock forward and wakes every sleeper whose deadline it reached.
    func advance(by duration: Duration) {
        let due = state.withLock { state -> [Sleeper] in
            state.now = state.now.advanced(by: duration)
            let now = state.now
            let ids = state.sleepers.filter { $0.value.deadline <= now }.map(\.key)
            return ids.compactMap { state.sleepers.removeValue(forKey: $0) }
        }
        for sleeper in due { sleeper.continuation.resume() }
    }
}
