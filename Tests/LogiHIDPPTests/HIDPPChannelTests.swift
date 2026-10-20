import Foundation
import Testing
@testable import LogiHIDPP

/// Bytes from the 2026-10-16 probe (docs/hardware-notes.md): MX Master 4 on slot 2 of a Bolt receiver, HID++ 4.5.
private enum Probe {
    static func ping(_ device: UInt8) -> [UInt8] { [0x10, device, 0x00, 0x1a, 0x00, 0x00, 0x5a] }
    static let pingReply = bytes(0x11, 0x02, 0x00, 0x1a, 0x04, 0x05, 0x5a)
    static func emptySlot(_ device: UInt8) -> [UInt8] { [0x10, device, 0x8f, 0x00, 0x1a, 0x09, 0x00] }
    static let foreignRegister = [UInt8]([0x10, 0xff, 0x81, 0x02, 0x00, 0x01, 0x00])
    static let foreignLongRegister = bytes(0x11, 0xff, 0x83, 0xfb)
    /// Root `getFeature(0x1B04)` on device 2 and its reply: index 13.
    static let lookupReprog = [UInt8]([0x10, 0x02, 0x00, 0x0a, 0x1b, 0x04, 0x00])
    static let lookupReprogReply = bytes(0x11, 0x02, 0x00, 0x0a, 0x0d, 0x00, 0x00)
}

private let fast = Duration.milliseconds(50)

@Suite struct HIDPPChannelTests {
    @Test func pingMatchesOnlyItsOwnReply() async throws {
        let fake = FakeTransport()
        fake.script(Probe.ping(2), replies: [
            Probe.foreignRegister,
            Probe.foreignLongRegister,
            bytes(0x11, 0x03, 0x00, 0x1a, 0x01, 0x00, 0x5a),   // another device
            bytes(0x11, 0x02, 0x01, 0x1a, 0x02, 0x00, 0x5a),   // another feature index
            bytes(0x11, 0x02, 0x00, 0x1b, 0x03, 0x00, 0x5a),   // another software ID
            bytes(0x11, 0x02, 0x00, 0x2a, 0x03, 0x00, 0x5a),   // another function
            Probe.pingReply,
        ])
        let channel = HIDPPChannel(transport: fake, timeout: fast, softwareID: 0x0A)

        let version = try await channel.ping(device: 2)

        #expect(version == HIDPPVersion(major: 4, minor: 5))
        #expect(fake.sent.map(\.bytes) == [Probe.ping(2)])
    }

    @Test func discoverFindsTheMouseAmongEmptySlots() async {
        let fake = FakeTransport()
        for slot: UInt8 in [1, 3, 4, 5, 6] {
            fake.script(Probe.ping(slot), replies: [Probe.emptySlot(slot)])
        }
        fake.script(Probe.ping(2), replies: [Probe.pingReply])
        let channel = HIDPPChannel(transport: fake, timeout: fast, softwareID: 0x0A)

        let devices = await channel.discover()

        #expect(devices == [2])
        #expect(Set(fake.sent.map(\.deviceIndex)) == [1, 2, 3, 4, 5, 6])
    }

    @Test func discoverSkipsSilentSlots() async {
        let fake = FakeTransport()
        fake.script(Probe.ping(2), replies: [Probe.pingReply])   // slots 1, 3–6 never answer
        let channel = HIDPPChannel(transport: fake, timeout: fast, softwareID: 0x0A)

        let start = ContinuousClock.now
        let devices = await channel.discover()

        #expect(devices == [2])
        #expect(ContinuousClock.now - start < .seconds(1))   // the six pings run at once
    }

    @Test func errorsMapToHIDPPError() async throws {
        let fake = FakeTransport()
        fake.script(Probe.ping(1), replies: [Probe.emptySlot(1)])
        let divert = HIDPPReport.short(device: 2, feature: 0x0d, function: 3, softwareID: 0x0A, params: [0x01, 0xa0, 0x03])
        fake.script(divert.bytes, replies: [bytes(0x11, 0x02, 0xff, 0x0d, 0x3a, 0x05)])
        let channel = HIDPPChannel(transport: fake, timeout: fast, softwareID: 0x0A)

        await #expect(throws: HIDPPError.hidpp1(0x09)) { try await channel.ping(device: 1) }
        await #expect(throws: HIDPPError.hidpp2(0x05)) { try await channel.request(divert) }

        let start = ContinuousClock.now
        await #expect(throws: HIDPPError.timeout) { try await channel.ping(device: 4) }
        #expect(ContinuousClock.now - start < .milliseconds(500))
    }

    @Test func anErrorForAnotherRequestDoesNotFailOurs() async throws {
        let fake = FakeTransport()
        fake.script(Probe.ping(2), replies: [
            bytes(0x11, 0x02, 0xff, 0x0d, 0x3a, 0x05),            // error for a feature-13 request
            [0x10, 0x02, 0x8f, 0x00, 0x1b, 0x09, 0x00],            // error for another software ID
            Probe.emptySlot(3),                                    // error for another device
            Probe.pingReply,
        ])
        let channel = HIDPPChannel(transport: fake, timeout: fast, softwareID: 0x0A)

        #expect(try await channel.ping(device: 2) == HIDPPVersion(major: 4, minor: 5))
    }

    @Test func sendFailureIsThrown() async {
        let fake = FakeTransport()
        fake.failSends(with: .transport(-536_870_212))
        let channel = HIDPPChannel(transport: fake, timeout: fast, softwareID: 0x0A)

        await #expect(throws: HIDPPError.transport(-536_870_212)) { try await channel.ping(device: 2) }
        await #expect(throws: HIDPPError.transport(-536_870_212)) {
            try await channel.post(HIDPPReport.short(device: 2, feature: 0x0b, function: 4, params: [0x03]))
        }
    }

    @Test func featureIndexIsCachedUntilForget() async throws {
        let fake = FakeTransport()
        fake.script(Probe.lookupReprog, replies: [Probe.lookupReprogReply])
        fake.script([0x10, 0x03, 0x00, 0x0a, 0x1b, 0x04, 0x00], replies: [bytes(0x11, 0x03, 0x00, 0x0a, 0x00)])
        let channel = HIDPPChannel(transport: fake, timeout: fast, softwareID: 0x0A)

        #expect(try await channel.featureIndex(0x1B04, device: 2) == 13)
        #expect(try await channel.featureIndex(0x1B04, device: 2) == 13)
        #expect(fake.sent.count == 1)

        await channel.forget(device: 2)
        #expect(try await channel.featureIndex(0x1B04, device: 2) == 13)
        #expect(fake.sent.map(\.bytes) == [Probe.lookupReprog, Probe.lookupReprog])

        await #expect(throws: HIDPPError.featureMissing(0x1B04)) { try await channel.featureIndex(0x1B04, device: 3) }
        #expect(try await channel.featureIndex(0x0000, device: 2) == 0)   // root is always index 0, never asked
        #expect(fake.sent.count == 3)
    }

    @Test func callPicksShortOrLongByParamCount() async throws {
        let fake = FakeTransport()
        fake.script(Probe.lookupReprog, replies: [Probe.lookupReprogReply])
        let divert = [UInt8]([0x10, 0x02, 0x0d, 0x3a, 0x01, 0xa0, 0x03])
        fake.script(divert, replies: [bytes(0x11, 0x02, 0x0d, 0x3a, 0x01, 0xa0, 0x03)])
        let longRequest = bytes(0x11, 0x02, 0x0d, 0x3a, 0x01, 0xa0, 0x03, 0x00)
        fake.script(longRequest, replies: [bytes(0x11, 0x02, 0x0d, 0x3a, 0x01, 0xa0, 0x03)])
        let channel = HIDPPChannel(transport: fake, timeout: fast, softwareID: 0x0A)

        let reply = try await channel.call(0x1B04, device: 2, function: 3, params: [0x01, 0xa0, 0x03])
        #expect(reply.count == 16)
        #expect(Array(reply.prefix(3)) == [0x01, 0xa0, 0x03])
        _ = try await channel.call(0x1B04, device: 2, function: 3, params: [0x01, 0xa0, 0x03, 0x00])

        #expect(fake.sent.map(\.bytes) == [Probe.lookupReprog, divert, longRequest])
    }

    @Test func notificationsCarryFeatureEventsAndConnection() async throws {
        let fake = FakeTransport()
        fake.script(Probe.ping(2), replies: [Probe.pingReply])
        let channel = HIDPPChannel(transport: fake, timeout: fast, softwareID: 0x0A)
        // Let the channel's reader run before anyone subscribes: a later subscriber still gets later notifications.
        fake.push(bytes(0x11, 0x02, 0x0d, 0x00, 0x00, 0x50), at: 1)
        _ = try await channel.ping(device: 2)

        let first = channel.notifications
        let second = channel.notifications

        fake.push(Probe.foreignRegister)                                  // receiver register traffic: not ours
        fake.push(Probe.pingReply)                                        // an unmatched reply: not a notification
        fake.push(bytes(0x11, 0x02, 0x0d, 0x00, 0x01, 0xa0), at: 12.5)    // panel pressed
        // HID++ 1.0 connection notice. Assumed layout: bit 6 of byte 4 set = link lost.
        fake.push([0x10, 0x02, 0x41, 0x10, 0x42, 0x82, 0x40])
        fake.push([0x10, 0x02, 0x41, 0x10, 0x02, 0x82, 0x40])

        let expected: [HIDPPNotification] = [
            .feature(device: 2, featureIndex: 13, function: 0,
                     params: [0x01, 0xa0] + [UInt8](repeating: 0, count: 14), at: 12.5),
            .connection(device: 2, linked: false),
            .connection(device: 2, linked: true),
        ]
        #expect(await collect(first, count: 3) == expected)
        #expect(await collect(second, count: 3) == expected)
    }

    @Test func removedFailsPending() async throws {
        let fake = FakeTransport()
        let channel = HIDPPChannel(transport: fake, timeout: .seconds(5), softwareID: 0x0A)
        let notifications = channel.notifications

        #expect(await !ends(channel.notifications, within: .milliseconds(30)))   // a live channel's stream stays open

        let pending = Task { try await channel.ping(device: 2) }
        #expect(await eventually { fake.sent.count == 1 })
        fake.pushRemoved()

        await #expect(throws: HIDPPError.disconnected) { try await outcome(of: pending).get() }
        // After removal: requests fail at once and notification streams end.
        await #expect(throws: HIDPPError.disconnected) { try await channel.ping(device: 2) }
        #expect(await ends(notifications))           // subscribed before the removal
        #expect(await ends(channel.notifications))   // subscribed after it
    }

    /// All root lookups on a device share one key: a late reply to a timed-out lookup must not become the index of
    /// the next lookup's feature (later calls would write to the wrong feature on the mouse).
    @Test func aLateReplyAfterATimeoutDoesNotAnswerTheNextRequest() async throws {
        let fake = FakeTransport()
        let lookupHaptics = [UInt8]([0x10, 0x02, 0x00, 0x0a, 0x19, 0xb0, 0x00])
        fake.script(lookupHaptics, replies: [
            Probe.lookupReprogReply,                       // the late reply to the 0x1B04 lookup: index 13
            bytes(0x11, 0x02, 0x00, 0x0a, 0x0b, 0x00, 0x00),   // the reply to the 0x19B0 lookup: index 11
        ])
        let channel = HIDPPChannel(transport: fake, timeout: fast, softwareID: 0x0A)

        await #expect(throws: HIDPPError.timeout) { try await channel.featureIndex(0x1B04, device: 2) }
        #expect(try await channel.featureIndex(0x19B0, device: 2) == 11)
        #expect(try await channel.featureIndex(0x19B0, device: 2) == 11)   // the cache holds B's value
        #expect(fake.sent.map(\.bytes) == [Probe.lookupReprog, lookupHaptics])
    }

    @Test func aLateErrorAfterATimeoutDoesNotFailTheNextRequest() async throws {
        let fake = FakeTransport()
        let channel = HIDPPChannel(transport: fake, timeout: fast, softwareID: 0x0A)
        await #expect(throws: HIDPPError.timeout) { try await channel.ping(device: 1) }

        fake.script(Probe.ping(1), replies: [Probe.emptySlot(1), bytes(0x11, 0x01, 0x00, 0x1a, 0x04, 0x05, 0x5a)])
        #expect(try await channel.ping(device: 1) == HIDPPVersion(major: 4, minor: 5))
    }

    @Test func aTombstoneExpires() async throws {
        let fake = FakeTransport()
        let channel = HIDPPChannel(transport: fake, timeout: fast, lateReplyWindow: .milliseconds(20), softwareID: 0x0A)
        await #expect(throws: HIDPPError.timeout) { try await channel.ping(device: 2) }
        try await Task.sleep(for: .milliseconds(60))

        fake.script(Probe.ping(2), replies: [Probe.pingReply])
        #expect(try await channel.ping(device: 2) == HIDPPVersion(major: 4, minor: 5))
    }

    /// setControlReporting calls all share one key. With an echo (the CID the reply repeats), a lost reply's tombstone
    /// claims only that CID's reply: later calls for other CIDs complete at once instead of cascading into timeouts.
    @Test func aTombstoneWithAnEchoIgnoresRepliesForOtherEchoes() async throws {
        let fake = FakeTransport()
        let divertPanel = HIDPPReport.short(device: 2, feature: 0x0d, function: 3, softwareID: 0x0A, params: [0x01, 0xa0, 0x03])
        let divertGesture = HIDPPReport.short(device: 2, feature: 0x0d, function: 3, softwareID: 0x0A, params: [0x00, 0xc3, 0x03])
        let releaseGesture = HIDPPReport.short(device: 2, feature: 0x0d, function: 3, softwareID: 0x0A, params: [0x00, 0xc3, 0x02])
        fake.script(divertGesture.bytes, replies: [bytes(0x11, 0x02, 0x0d, 0x3a, 0x00, 0xc3, 0x03)])
        fake.script(releaseGesture.bytes, replies: [bytes(0x11, 0x02, 0x0d, 0x3a, 0x00, 0xc3, 0x02)])
        fake.script(Probe.lookupReprog, replies: [Probe.lookupReprogReply])
        let channel = HIDPPChannel(transport: fake, timeout: .milliseconds(200), softwareID: 0x0A)

        await #expect(throws: HIDPPError.timeout) { try await channel.request(divertPanel, echo: [0x01, 0xa0]) }   // reply lost

        let start = ContinuousClock.now
        #expect(try await channel.request(divertGesture, echo: [0x00, 0xc3]).params.prefix(3) == [0x00, 0xc3, 0x03])
        #expect(try await channel.call(0x1B04, device: 2, function: 3, params: [0x00, 0xc3, 0x02], echo: [0x00, 0xc3])
                .prefix(3) == [0x00, 0xc3, 0x02])
        #expect(ContinuousClock.now - start < .milliseconds(150))
    }

    @Test func aTombstoneWithAnEchoStillSwallowsItsOwnLateReply() async throws {
        let fake = FakeTransport()
        let divertPanel = HIDPPReport.short(device: 2, feature: 0x0d, function: 3, softwareID: 0x0A, params: [0x01, 0xa0, 0x03])
        let channel = HIDPPChannel(transport: fake, timeout: fast, softwareID: 0x0A)
        await #expect(throws: HIDPPError.timeout) { try await channel.request(divertPanel, echo: [0x01, 0xa0]) }

        // The late reply to the first divert arrives just before the second one's: the tombstone takes the first.
        fake.script(divertPanel.bytes, replies: [bytes(0x11, 0x02, 0x0d, 0x3a, 0x01, 0xa0, 0x03, 0x01),
                                                 bytes(0x11, 0x02, 0x0d, 0x3a, 0x01, 0xa0, 0x03, 0x02)])
        let reply = try await channel.request(divertPanel, echo: [0x01, 0xa0])
        #expect(reply.params.prefix(4) == [0x01, 0xa0, 0x03, 0x02])
    }

    @Test func aWaiterWithAnEchoLetsOtherRepliesPass() async throws {
        let fake = FakeTransport()
        let divertPanel = HIDPPReport.short(device: 2, feature: 0x0d, function: 3, softwareID: 0x0A, params: [0x01, 0xa0, 0x03])
        fake.script(divertPanel.bytes, replies: [bytes(0x11, 0x02, 0x0d, 0x3a, 0x00, 0xc3, 0x03),   // someone else's CID
                                                 bytes(0x11, 0x02, 0x0d, 0x3a, 0x01, 0xa0, 0x03)])
        let channel = HIDPPChannel(transport: fake, timeout: fast, softwareID: 0x0A)
        #expect(try await channel.request(divertPanel, echo: [0x01, 0xa0]).params.prefix(2) == [0x01, 0xa0])
    }

    @Test func anErrorReplyIgnoresTheEcho() async throws {
        let fake = FakeTransport()
        let divertPanel = HIDPPReport.short(device: 2, feature: 0x0d, function: 3, softwareID: 0x0A, params: [0x01, 0xa0, 0x03])
        fake.script(divertPanel.bytes, replies: [bytes(0x11, 0x02, 0xff, 0x0d, 0x3a, 0x02)])
        let channel = HIDPPChannel(transport: fake, timeout: fast, softwareID: 0x0A)
        await #expect(throws: HIDPPError.hidpp2(0x02)) { try await channel.request(divertPanel, echo: [0x01, 0xa0]) }
    }

    @Test func sendRequestSendsBeforeReturningAndAnswersLater() async throws {
        let fake = FakeTransport()
        let channel = HIDPPChannel(transport: fake, timeout: .seconds(1), softwareID: 0x0A)

        let reply = await channel.sendRequest(.short(device: 2, feature: 0x0b, function: 2, params: [0x01, 0x50]),
                                              echo: [0x01, 0x50])
        #expect(fake.sent.map(\.bytes) == [[0x10, 0x02, 0x0b, 0x2a, 0x01, 0x50, 0x00]])
        try await channel.post(.short(device: 2, feature: 0x0b, function: 4, params: [0x02]))
        #expect(fake.sent.map(\.bytes).last == [0x10, 0x02, 0x0b, 0x4a, 0x02, 0x00, 0x00])

        fake.push(bytes(0x11, 0x02, 0x0b, 0x2a, 0x01, 0x23))   // another echo: not ours
        fake.push(bytes(0x11, 0x02, 0x0b, 0x2a, 0x01, 0x50))
        let report = try await outcome(of: reply).get()
        #expect(Array(report.params.prefix(2)) == [0x01, 0x50])
    }

    @Test func sendRequestTimesOutAndFailsWhenRemoved() async throws {
        let fake = FakeTransport()
        let channel = HIDPPChannel(transport: fake, timeout: fast, softwareID: 0x0A)
        let lost = await channel.sendRequest(.short(device: 2, feature: 0x0b, function: 2, params: [0x01, 0x50]))
        await #expect(throws: HIDPPError.timeout) { try await outcome(of: lost).get() }

        let pending = await channel.sendRequest(.short(device: 2, feature: 0x0b, function: 1, params: []))
        fake.pushRemoved()
        await #expect(throws: HIDPPError.disconnected) { try await outcome(of: pending).get() }
    }

    @Test func readerStopsWhenTheChannelGoesAway() async {
        let fake = FakeTransport()
        var channel: HIDPPChannel? = HIDPPChannel(transport: fake, timeout: fast, softwareID: 0x0A)
        _ = await channel?.discover()
        #expect(!fake.terminated)

        channel = nil

        #expect(await eventually { fake.terminated })
    }

    // MARK: - Software IDs

    /// `0x1B04` getControlInfo of `index` on device 2 (a request every client sends with the same key) and the reply,
    /// which names the index in its first param byte.
    private static func controlInfo(_ index: UInt8) -> [UInt8] { [0x10, 0x02, 0x0d, 0x10, index, 0x00, 0x00] }
    private static func controlInfoReply(_ index: UInt8) -> [UInt8] { bytes(0x11, 0x02, 0x0d, 0x10, index, 0xa0) }

    @Test func requestsCarryTheChannelsSoftwareID() async throws {
        let fake = FakeTransport()
        fake.script([0x10, 0x02, 0x00, 0x1b, 0x00, 0x00, 0x5a], replies: [bytes(0x11, 0x02, 0x00, 0x1b, 0x04, 0x05, 0x5a)])
        let channel = HIDPPChannel(transport: fake, timeout: fast, softwareID: 0x0B)

        #expect(try await channel.ping(device: 2) == HIDPPVersion(major: 4, minor: 5))
        try await channel.post(.short(device: 2, feature: 0x0b, function: 4, softwareID: 0x0A, params: [0x03]))

        #expect(fake.sent.map(\.softwareID) == [0x0B, 0x0B])
    }

    @Test func twoClientsOnOneReceiverNeverTakeEachOthersReplies() async throws {
        let receiver = SharedReceiver()
        for index: UInt8 in 0..<4 { receiver.script(Self.controlInfo(index), replies: [Self.controlInfoReply(index)]) }
        let a = HIDPPChannel(transport: receiver.endpoint(), timeout: .milliseconds(500), softwareID: 0x0A)
        let bEndpoint = receiver.endpoint()
        let b = HIDPPChannel(transport: bEndpoint, timeout: .milliseconds(500), softwareID: 0x0B)

        // B waits for index 9, which the receiver has not answered yet, while A's replies (same key but for the
        // software ID) reach B's transport too.
        let waiting = Task { try await b.request(.short(device: 2, feature: 0x0d, function: 1, params: [9])).params }
        #expect(await eventually { bEndpoint.sent.count == 1 })
        for index: UInt8 in 0..<4 {
            let params = try await a.request(.short(device: 2, feature: 0x0d, function: 1, params: [index])).params
            #expect(params.prefix(2) == [index, 0xa0])
        }
        receiver.broadcast(bytes(0x11, 0x02, 0x0d, 0x1b, 9, 0xa0))   // B's own reply, at last

        let params = try await outcome(of: waiting).get()
        #expect(params.prefix(2) == [9, 0xa0])
    }

    @Test func twoClientsSettingUpAtOnceEachGetTheirOwnReplies() async throws {
        let receiver = SharedReceiver()
        for index: UInt8 in 0..<8 { receiver.script(Self.controlInfo(index), replies: [Self.controlInfoReply(index)]) }
        let channels = [HIDPPChannel(transport: receiver.endpoint(), softwareID: 0x0A),
                        HIDPPChannel(transport: receiver.endpoint(), softwareID: 0x0B)]

        let results = await withTaskGroup(of: [UInt8].self) { group in
            for channel in channels {
                group.addTask {
                    var seen: [UInt8] = []
                    for index: UInt8 in 0..<8 {
                        let report = HIDPPReport.short(device: 2, feature: 0x0d, function: 1, params: [index])
                        seen.append((try? await channel.request(report).params[0]) ?? 0xEE)
                    }
                    return seen
                }
            }
            return await group.reduce(into: []) { $0.append($1) }
        }

        #expect(results == [Array(0..<8), Array(0..<8)])
    }

    @Test func softwareIDsAreClaimedOncePerHolder() throws {
        let directory = NSTemporaryDirectory() + "LogiHIDPP-swid-test-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: directory) }

        let first = try #require(HIDPPSoftwareID.claim(in: directory))
        let second = try #require(HIDPPSoftwareID.claim(in: directory))
        #expect(first.id == 0x0A)
        #expect(second.id == 0x0B)
        #expect(!HIDPPSoftwareID.candidates.contains(0) && !HIDPPSoftwareID.candidates.contains(8))
        #expect((1...15).contains(HIDPPSoftwareID.process) && HIDPPSoftwareID.process != 8)

        close(first.descriptor)   // the holder went away: its ID is free again
        let third = try #require(HIDPPSoftwareID.claim(in: directory))
        #expect(third.id == 0x0A)
        close(second.descriptor)
        close(third.descriptor)

        let last = HIDPPSoftwareID.candidates.last!
        let all = HIDPPSoftwareID.candidates.compactMap { _ in HIDPPSoftwareID.claim(in: directory) }
        #expect(all.map(\.id) == HIDPPSoftwareID.candidates && all.last?.id == last)
        #expect(HIDPPSoftwareID.claim(in: directory) == nil)
        for claim in all { close(claim.descriptor) }
    }

    // MARK: - HID++ 1.0 registers

    @Test func registerReadAndWriteKeepTheirAddress() async throws {
        let fake = FakeTransport()
        fake.script([0x10, 0xff, 0x81, 0x00, 0x00, 0x00, 0x00], replies: [
            Probe.foreignRegister,                                // register 0x02 of another program
            [0x10, 0xff, 0x81, 0x00, 0x00, 0x09, 0x00],
        ])
        fake.script([0x10, 0xff, 0x80, 0x00, 0x00, 0x09, 0x00], replies: [[0x10, 0xff, 0x80, 0x00, 0x00, 0x00, 0x00]])
        let channel = HIDPPChannel(transport: fake, timeout: fast, softwareID: 0x0B)

        #expect(try await channel.readRegister(address: 0x00) == [0x00, 0x09, 0x00])
        try await channel.writeRegister(address: 0x00, value: [0x00, 0x09, 0x00])
        #expect(fake.sent.map(\.bytes) == [[0x10, 0xff, 0x81, 0x00, 0x00, 0x00, 0x00], [0x10, 0xff, 0x80, 0x00, 0x00, 0x09, 0x00]])
    }

    @Test func registerErrorReply() async throws {
        let fake = FakeTransport()
        fake.script([0x10, 0xff, 0x81, 0x00, 0x00, 0x00, 0x00], replies: [[0x10, 0xff, 0x8f, 0x81, 0x00, 0x02, 0x00]])
        let channel = HIDPPChannel(transport: fake, timeout: fast, softwareID: 0x0B)
        await #expect(throws: HIDPPError.hidpp1(0x02)) { try await channel.readRegister(address: 0x00) }
    }
}
