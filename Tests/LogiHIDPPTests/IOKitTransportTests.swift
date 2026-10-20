import Foundation
import Testing
@testable import LogiHIDPP

/// The parts of `IOKitTransport` that need no device: its event fan-out and its clock. No test here opens IOKit.
struct IOKitTransportTests {
    private let report = HIDPPReport(bytes: bytes(0x10, 0x02, 0x00, 0x1A, 0x04, 0x05, 0x5A))!

    @Test func everyStreamGetsReportsThenRemovedAndEnds() async {
        let hub = TransportEventHub()
        let first = hub.subscribe()
        let second = hub.subscribe()
        hub.yield(.report(report, at: 1.5))
        hub.remove()
        for stream in [first, second] {
            let events = await collect(stream, count: 3)
            #expect(events.count == 2)
            guard events.count == 2, case .report(let got, let time) = events[0], case .removed = events[1] else {
                Issue.record("unexpected events \(events)")
                continue
            }
            #expect(got == report)
            #expect(time == 1.5)
        }
    }

    @Test func streamTakenAfterRemovalYieldsRemovedAndEnds() async {
        let hub = TransportEventHub()
        hub.remove()
        let events = await collect(hub.subscribe(), count: 2)
        #expect(events.count == 1)
        if case .removed? = events.first {} else { Issue.record("expected .removed, got \(events)") }
        #expect(await ends(hub.subscribe()))
    }

    @Test func removalIsAnnouncedOnce() async {
        let hub = TransportEventHub()
        let stream = hub.subscribe()
        hub.remove()
        hub.remove()
        #expect(await collect(stream, count: 3).count == 1)
    }

    @Test func streamOnlyGetsReportsFromItsSubscriptionOn() async {
        let hub = TransportEventHub()
        hub.yield(.report(report, at: 1))
        let stream = hub.subscribe()
        hub.yield(.report(report, at: 2))
        hub.remove()
        let times = await collect(stream, count: 3).compactMap { event -> TimeInterval? in
            if case .report(_, let time) = event { time } else { nil }
        }
        #expect(times == [2])
    }

    @Test func machTimeConvertsToSeconds() {
        // Apple silicon timebase: 125/3 ns per tick, 24 MHz.
        #expect(IOKitTransport.seconds(fromMachTime: 24_000_000, numer: 125, denom: 3) == 1.0)
        #expect(IOKitTransport.seconds(fromMachTime: 2_500_000_000, numer: 1, denom: 1) == 2.5)
    }

    @Test func currentTimeIsMachAbsoluteSeconds() {
        let before = IOKitTransport.seconds(fromMachTime: mach_absolute_time())
        let now = IOKitTransport.currentTime
        let after = IOKitTransport.seconds(fromMachTime: mach_absolute_time())
        #expect(before <= now && now <= after)
    }
}
