import Testing
@testable import LogiHIDPP

@Suite struct HIDPPReportTests {
    @Test func pingReplyRoundTrip() throws {
        let raw = bytes(0x11, 0x02, 0x00, 0x1a, 0x04, 0x05, 0x5a)
        let report = try #require(HIDPPReport(bytes: raw))
        #expect(report.bytes == raw)
        #expect(report.deviceIndex == 2)
        #expect(report.featureIndex == 0)
        #expect(report.function == 1)
        #expect(report.softwareID == 0x0A)
        #expect(report.params.count == 16)
        #expect(Array(report.params.prefix(3)) == [0x04, 0x05, 0x5a])
        #expect(report.params.dropFirst(3).allSatisfy { $0 == 0 })

        let rebuilt = HIDPPReport.long(device: 2, feature: 0, function: 1, softwareID: 0x0A, params: [0x04, 0x05, 0x5a])
        #expect(rebuilt == report)
    }

    @Test func shortReportFields() throws {
        let report = try #require(HIDPPReport(bytes: [0x10, 0x03, 0x8f, 0x00, 0x1a, 0x09, 0x00]))
        #expect(report.deviceIndex == 3)
        #expect(report.featureIndex == 0x8f)
        // A HID++ 1.0 error: byte 3 is the failed request's feature index, so function and software ID read as 0.
        #expect(report.function == 0)
        #expect(report.softwareID == 0)
        #expect(report.params == [0x1a, 0x09, 0x00])
    }

    @Test func rejectsWrongLengthAndUnknownID() {
        #expect(HIDPPReport(bytes: []) == nil)
        #expect(HIDPPReport(bytes: [0x10, 0x02, 0x00, 0x1a, 0x00, 0x00]) == nil)          // short, 6 bytes
        #expect(HIDPPReport(bytes: [0x10] + [UInt8](repeating: 0, count: 19)) == nil)     // short id, long length
        #expect(HIDPPReport(bytes: [0x11] + [UInt8](repeating: 0, count: 6)) == nil)      // long id, short length
        #expect(HIDPPReport(bytes: [0x11] + [UInt8](repeating: 0, count: 20)) == nil)     // long, 21 bytes
        #expect(HIDPPReport(bytes: [0x12] + [UInt8](repeating: 0, count: 63)) == nil)     // very long: not supported
        #expect(HIDPPReport(bytes: [0x20, 0x02, 0x00, 0x1a, 0x00, 0x00, 0x5a]) == nil)    // unknown id
        #expect(HIDPPReport(bytes: [0x10, 0x02, 0x00, 0x1a, 0x00, 0x00, 0x5a]) != nil)
    }

    @Test func shortPadsToSevenAndLongToTwenty() {
        let ping = HIDPPReport.short(device: 2, feature: 0, function: 1, softwareID: 0x0A, params: [0x00, 0x00, 0x5a])
        #expect(ping.bytes == [0x10, 0x02, 0x00, 0x1a, 0x00, 0x00, 0x5a])

        let lookup = HIDPPReport.short(device: 2, feature: 0, function: 0, softwareID: 0x0A, params: [0x1b, 0x04])
        #expect(lookup.bytes == [0x10, 0x02, 0x00, 0x0a, 0x1b, 0x04, 0x00])

        let notification = HIDPPReport.short(device: 2, feature: 0x0d, function: 0, params: [])   // default ID 0
        #expect(notification.bytes == [0x10, 0x02, 0x0d, 0x00, 0x00, 0x00, 0x00])

        let divert = HIDPPReport.long(device: 2, feature: 0x0d, function: 3, softwareID: 0x0A, params: [0x01, 0xa0, 0x03, 0x00])
        #expect(divert.bytes.count == 20)
        #expect(divert.bytes == bytes(0x11, 0x02, 0x0d, 0x3a, 0x01, 0xa0, 0x03))
        #expect(divert.params.count == 16)
    }

    @Test func stampedReplacesOnlyTheSoftwareID() {
        let divert = HIDPPReport.short(device: 2, feature: 0x0d, function: 3, params: [0x01, 0xa0, 0x03])
        #expect(divert.stamped(softwareID: 0x0B).bytes == [0x10, 0x02, 0x0d, 0x3b, 0x01, 0xa0, 0x03])
        #expect(divert.stamped(softwareID: 0x0B).stamped(softwareID: 0x01).bytes == [0x10, 0x02, 0x0d, 0x31, 0x01, 0xa0, 0x03])
    }
}
