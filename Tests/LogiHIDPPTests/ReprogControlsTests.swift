import Testing
@testable import LogiHIDPP

@Suite struct ReprogControlsTests {
    @Test func cidConstants() {
        #expect(CID.left.rawValue == 0x50)
        #expect(CID.right.rawValue == 0x51)
        #expect(CID.middle.rawValue == 0x52)
        #expect(CID.back.rawValue == 0x53)
        #expect(CID.forward.rawValue == 0x56)
        #expect(CID.gesture.rawValue == 0xC3)
        #expect(CID.smartShift.rawValue == 0xC4)
        #expect(CID.hapticPanel.rawValue == 0x01A0)
        #expect(CID(rawValue: 0x01A0) == .hapticPanel)
    }

    @Test func divertParamsDivertAndRelease() {
        #expect(ReprogControls.divertParams(.hapticPanel, divert: true) == [0x01, 0xA0, 0x03])
        #expect(ReprogControls.divertParams(.hapticPanel, divert: false) == [0x01, 0xA0, 0x02])
        #expect(ReprogControls.divertParams(.gesture, divert: true) == [0x00, 0xC3, 0x03])
    }

    @Test func controlInfoFromProbe() {
        // Probe: `cid 0x0052 tid 0x003a flags 31`, `cid 0x0050 tid 0x0038 flags 01`.
        let middle = ReprogControls.control(fromInfo: [0x00, 0x52, 0x00, 0x3a, 0x31] + [UInt8](repeating: 0, count: 11))
        #expect(middle == Control(cid: .middle, divertable: true))
        let left = ReprogControls.control(fromInfo: [0x00, 0x50, 0x00, 0x38, 0x01] + [UInt8](repeating: 0, count: 11))
        #expect(left == Control(cid: .left, divertable: false))
    }

    @Test func controlInfoShortParamsIsNotDivertable() {
        #expect(ReprogControls.control(fromInfo: [0x00, 0x52]) == Control(cid: .middle, divertable: false))
    }

    @Test func watchParamsSwitchAnalyticsOnAndOff() {
        // `cid_hi cid_lo 00 00 00 03` on, `… 02` off: byte 2 = 0 leaves the divert flags alone.
        #expect(ReprogControls.watchParams(.forward, watch: true) == [0x00, 0x56, 0x00, 0x00, 0x00, 0x03])
        #expect(ReprogControls.watchParams(.forward, watch: false) == [0x00, 0x56, 0x00, 0x00, 0x00, 0x02])
        #expect(ReprogControls.watchParams(.hapticPanel, watch: true) == [0x01, 0xA0, 0x00, 0x00, 0x00, 0x03])
    }

    @Test func controlInfoDecodesWatchableFromFlags2() {
        // Probe, 2026-10-16: byte 8 is 0x05 for back / forward / middle / panel, 0x04 for left / right, 0x03 for 0xd7.
        func info(_ cid: UInt16, flags: UInt8, flags2: UInt8) -> [UInt8] {
            [UInt8(cid >> 8), UInt8(cid & 0xFF), 0x00, 0x3a, flags, 0x00, 0x00, 0x00, flags2] + [UInt8](repeating: 0, count: 7)
        }
        #expect(ReprogControls.control(fromInfo: info(0x53, flags: 0x31, flags2: 0x05))
                == Control(cid: .back, divertable: true, watchable: true))
        #expect(ReprogControls.control(fromInfo: info(0x01A0, flags: 0x31, flags2: 0x05))
                == Control(cid: .hapticPanel, divertable: true, watchable: true))
        #expect(ReprogControls.control(fromInfo: info(0x50, flags: 0x01, flags2: 0x04))
                == Control(cid: .left, divertable: false, watchable: true))
        #expect(ReprogControls.control(fromInfo: info(0xD7, flags: 0x01, flags2: 0x03))
                == Control(cid: CID(rawValue: 0xD7), divertable: false, watchable: false))
    }

    @Test func controlInfoShortParamsIsNotWatchable() {
        #expect(ReprogControls.control(fromInfo: [0x00, 0x53, 0x00, 0x3a, 0x31]).watchable == false)
        // Eight bytes: the flags2 byte (index 8) is missing.
        #expect(ReprogControls.control(fromInfo: [0x00, 0x53, 0x00, 0x3a, 0x31, 0x00, 0x00, 0x00]).watchable == false)
    }

    @Test func controlsAreNotWatchableByDefault() {
        #expect(Control(cid: .left, divertable: false).watchable == false)
    }

    @Test func keyEventsFromRecordedNotifications() throws {
        let pressed = try #require(HIDPPReport(bytes: Fixtures.forwardPressedAnalytics))
        #expect(keyEvents(pressed.params) == [KeyEvent(.forward, true)])
        let released = try #require(HIDPPReport(bytes: Fixtures.forwardReleasedAnalytics))
        #expect(keyEvents(released.params) == [KeyEvent(.forward, false)])
    }

    @Test func keyEventsReadTriplesAndStopAtZero() {
        let two: [UInt8] = [0x00, 0x53, 0x01, 0x00, 0x56, 0x00, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]
        #expect(keyEvents(two) == [KeyEvent(.back, true), KeyEvent(.forward, false)])
        // Up to five triples in a long report.
        let five: [UInt8] = [0x00, 0x50, 0x01, 0x00, 0x51, 0x01, 0x00, 0x52, 0x01, 0x00, 0x53, 0x01, 0x00, 0x56, 0x01, 0x00]
        #expect(keyEvents(five).map(\.cid) == [.left, .right, .middle, .back, .forward])
        // A zero CID ends the list, whatever follows it.
        let stop: [UInt8] = [0x00, 0x53, 0x01, 0x00, 0x00, 0x00, 0x00, 0x56, 0x01, 0, 0, 0, 0, 0, 0, 0]
        #expect(keyEvents(stop) == [KeyEvent(.back, true)])
        #expect(keyEvents([UInt8](repeating: 0, count: 16)) == [])
    }

    @Test func keyEventsIgnoreShortParams() {
        // A short report carries three params: exactly one triple, never a half one.
        #expect(keyEvents([0x00, 0x56, 0x01]) == [KeyEvent(.forward, true)])
        #expect(keyEvents([0x00, 0x56]) == [])
        #expect(keyEvents([0x00, 0x56, 0x01, 0x00, 0x53]) == [KeyEvent(.forward, true)])
        #expect(keyEvents([]) == [])
    }

    @Test func pressedFromRecordedNotifications() throws {
        let panel = try #require(HIDPPReport(bytes: Fixtures.panelPressed))
        #expect(ReprogControls.pressed(from: panel.params) == [.hapticPanel])
        let none = try #require(HIDPPReport(bytes: Fixtures.allReleased))
        #expect(ReprogControls.pressed(from: none.params) == [])
    }

    @Test func pressedReadsFourAndStopsAtZero() {
        let four: [UInt8] = [0x00, 0x50, 0x00, 0x51, 0x00, 0x52, 0x01, 0xA0, 0x00, 0x53, 0, 0, 0, 0, 0, 0]
        #expect(ReprogControls.pressed(from: four) == [.left, .right, .middle, .hapticPanel])
        let stop: [UInt8] = [0x00, 0x50, 0, 0, 0x00, 0x51, 0, 0]
        #expect(ReprogControls.pressed(from: stop) == [.left])
        // A short report carries only three params: one whole CID, no half CID.
        #expect(ReprogControls.pressed(from: [0x01, 0xA0, 0x00]) == [.hapticPanel])
        #expect(ReprogControls.pressed(from: [0x01, 0xA0, 0x00, 0x50, 0x00]) == [.hapticPanel, .left])
        #expect(ReprogControls.pressed(from: []) == [])
    }

    @Test func trackerPressesAndReleases() {
        var tracker = PressTracker()
        #expect(tracker.update([.hapticPanel], at: 1) == [.pressed(.hapticPanel, at: 1)])
        #expect(tracker.update([.hapticPanel, .gesture], at: 2) == [.pressed(.gesture, at: 2)])
        #expect(tracker.update([.gesture], at: 3) == [.released(.hapticPanel, at: 3)])
        #expect(tracker.update([.gesture], at: 4) == [])
        #expect(tracker.update([], at: 5) == [.released(.gesture, at: 5)])
        #expect(tracker.update([], at: 6) == [])
    }

    @Test func trackerReleasesBeforePresses() {
        var tracker = PressTracker()
        _ = tracker.update([.left], at: 1)
        #expect(tracker.update([.right], at: 2) == [.released(.left, at: 2), .pressed(.right, at: 2)])
    }

    @Test func trackerReleaseAllInPressOrder() {
        var tracker = PressTracker()
        _ = tracker.update([.gesture], at: 1)
        _ = tracker.update([.gesture, .hapticPanel], at: 2)
        #expect(tracker.releaseAll(at: 3) == [.released(.gesture, at: 3), .released(.hapticPanel, at: 3)])
        #expect(tracker.releaseAll(at: 4) == [])
        #expect(tracker.update([.gesture], at: 5) == [.pressed(.gesture, at: 5)])
    }
}

/// An analytics key event as the tests compare it (the decoder returns tuples).
private struct KeyEvent: Equatable {
    let cid: CID
    let pressed: Bool
    init(_ cid: CID, _ pressed: Bool) {
        self.cid = cid
        self.pressed = pressed
    }
}

private func keyEvents(_ params: [UInt8]) -> [KeyEvent] {
    ReprogControls.keyEvents(from: params).map { KeyEvent($0.cid, $0.pressed) }
}
