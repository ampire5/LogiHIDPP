import Testing
@testable import LogiHIDPP

@Suite struct ForceSensingTests {
    private func params(_ bytes: [UInt8]) throws -> [UInt8] {
        try #require(HIDPPReport(bytes: bytes)).params
    }

    @Test func featureID() {
        #expect(ForceSensing.featureID == 0x19C0)
    }

    @Test func infoFromRecordedReply() throws {
        let info = try #require(ForceSensing.info(from: try params(Fixtures.forceInfo)))
        #expect(info == ForceSensing.Info(changeable: true, defaultValue: 4749, range: 3799...6316))
        #expect(info.changeable)
        #expect(info.defaultValue == 4749)
        #expect(info.range == 3799...6316)
    }

    @Test func infoNotChangeable() throws {
        let info = try #require(ForceSensing.info(from: [0x00, 0x00, 0x12, 0x8d, 0x18, 0xac, 0x0e, 0xd7]))
        #expect(info.changeable == false)
    }

    @Test func infoShortOrInvertedIsNil() {
        #expect(ForceSensing.info(from: [0x00, 0x01, 0x12, 0x8d, 0x18, 0xac, 0x0e]) == nil)
        #expect(ForceSensing.info(from: []) == nil)
        // min above max: not a range.
        #expect(ForceSensing.info(from: [0x00, 0x01, 0x12, 0x8d, 0x0e, 0xd7, 0x18, 0xac]) == nil)
    }

    @Test func currentFromRecordedReply() throws {
        #expect(ForceSensing.current(from: try params(Fixtures.forceCurrent)) == 4749)
        #expect(ForceSensing.current(from: [0x12]) == nil)
    }

    @Test func setParamsAreButtonAndBigEndianValue() {
        #expect(ForceSensing.setParams(button: 0, value: 3799) == [0x00, 0x0E, 0xD7])
        #expect(ForceSensing.setParams(button: 1, value: 0x18AC) == [0x01, 0x18, 0xAC])
    }
}
