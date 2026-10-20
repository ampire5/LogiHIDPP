import Testing
@testable import LogiHIDPP

@Suite struct ThumbWheelTests {
    private func params(_ bytes: [UInt8]) throws -> [UInt8] {
        try #require(HIDPPReport(bytes: bytes)).params
    }

    private func info() throws -> ThumbWheel.Info {
        ThumbWheel.info(from: try params(Fixtures.thumbWheelInfo))
    }

    @Test func featureID() {
        #expect(ThumbWheel.featureID == 0x2150)
    }

    @Test func infoFromRecordedReply() throws {
        #expect(try info() == ThumbWheel.Info(nativeResolution: 20, divertedResolution: 120,
                                              positiveIsDefault: true, hasTouch: true))
    }

    @Test func infoDirectionAndTouchBits() {
        let reversed = ThumbWheel.info(from: [0x00, 0x14, 0x00, 0x78, 0x01, 0x01, 0x03, 0xe8])
        #expect(reversed.positiveIsDefault == false)
        #expect(reversed.hasTouch == false)
    }

    @Test func infoShortParamsIsConservative() {
        let info = ThumbWheel.info(from: [0x00, 0x14])
        #expect(info == ThumbWheel.Info(nativeResolution: 20, divertedResolution: 0, positiveIsDefault: true, hasTouch: false))
    }

    @Test func reportingParamsMatchHardwareSession() {
        #expect(ThumbWheel.reportingParams(divert: true) == Fixtures.thumbWheelDivertParams)
        #expect(ThumbWheel.reportingParams(divert: false) == Fixtures.thumbWheelReleaseParams)
    }

    @Test func startPlus() throws {
        let event = ThumbWheel.event(from: try params(Fixtures.thumbWheelStartPlus), info: try info(), at: 5)
        #expect(event == .thumbWheel(delta: 1, touching: true, phase: .began, at: 5))
    }

    @Test func activePlus() throws {
        let event = ThumbWheel.event(from: try params(Fixtures.thumbWheelActivePlus), info: try info(), at: 6)
        #expect(event == .thumbWheel(delta: 1, touching: true, phase: .changed, at: 6))
    }

    @Test func startAndActiveMinusAreNegative() throws {
        let start = ThumbWheel.event(from: try params(Fixtures.thumbWheelStartMinus), info: try info(), at: 1)
        #expect(start == .thumbWheel(delta: -1, touching: true, phase: .began, at: 1))
        let active = ThumbWheel.event(from: try params(Fixtures.thumbWheelActiveMinus), info: try info(), at: 2)
        #expect(active == .thumbWheel(delta: -1, touching: true, phase: .changed, at: 2))
    }

    @Test func stopHasNoTouchFlag() throws {
        let event = ThumbWheel.event(from: try params(Fixtures.thumbWheelStop), info: try info(), at: 7)
        #expect(event == .thumbWheel(delta: 0, touching: false, phase: .ended, at: 7))
    }

    @Test func touchAndLiftAreChangedWithZeroDelta() throws {
        let touch = ThumbWheel.event(from: try params(Fixtures.thumbWheelTouch), info: try info(), at: 3)
        #expect(touch == .thumbWheel(delta: 0, touching: true, phase: .changed, at: 3))
        let lift = ThumbWheel.event(from: try params(Fixtures.thumbWheelLift), info: try info(), at: 4)
        #expect(lift == .thumbWheel(delta: 0, touching: false, phase: .changed, at: 4))
    }

    @Test func reversedDefaultDirectionNegatesDelta() throws {
        let reversed = ThumbWheel.Info(nativeResolution: 20, divertedResolution: 120, positiveIsDefault: false, hasTouch: true)
        let plus = ThumbWheel.event(from: try params(Fixtures.thumbWheelActivePlus), info: reversed, at: 1)
        #expect(plus == .thumbWheel(delta: -1, touching: true, phase: .changed, at: 1))
        let minus = ThumbWheel.event(from: try params(Fixtures.thumbWheelActiveMinus), info: reversed, at: 1)
        #expect(minus == .thumbWheel(delta: 1, touching: true, phase: .changed, at: 1))
    }

    @Test func largeSignedRotation() throws {
        let info = try info()
        #expect(ThumbWheel.event(from: [0x80, 0x00, 0, 0, 2, 0x02], info: info, at: 0)
                == .thumbWheel(delta: -32768, touching: true, phase: .changed, at: 0))
        #expect(ThumbWheel.event(from: [0x7F, 0xFF, 0, 0, 2, 0x02], info: info, at: 0)
                == .thumbWheel(delta: 32767, touching: true, phase: .changed, at: 0))
    }

    @Test func shortParamsGiveNil() throws {
        #expect(ThumbWheel.event(from: [0, 1, 0, 0, 2], info: try info(), at: 0) == nil)
        #expect(ThumbWheel.event(from: [], info: try info(), at: 0) == nil)
    }
}
