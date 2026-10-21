import Foundation
import Synchronization
import Testing
@testable import LogiHIDPP

/// The user's MX Master 4 on slot 2 of a Bolt receiver, as a script for `FakeTransport`: pings, root lookups
/// (`0x1B04` → 13, `0x19B0` → 11, `0x19C0` → 12, `0x2150` → 19, `0x2121` → 18, `0x2111` → 17 when asked for), six
/// controls, thumb-wheel info, haptic config and panel force from the recorded fixtures, the hi-res wheel mode, the
/// SmartShift wheel mode, and replies to divert / release / wheel reporting, analytics on / off, the setting writes and
/// the hi-res and SmartShift mode writes.
private enum MX4 {
    static let device: UInt8 = 2
    static let reprog: UInt8 = 0x0d
    static let haptic: UInt8 = 0x0b
    static let force: UInt8 = 0x0c
    static let wheel: UInt8 = 0x13
    static let hiRes: UInt8 = 0x12
    static let smartShift: UInt8 = 0x11

    static func ping(_ slot: UInt8) -> [UInt8] { [0x10, slot, 0x00, 0x1a, 0x00, 0x00, 0x5a] }
    static func emptySlot(_ slot: UInt8) -> [UInt8] { [0x10, slot, 0x8f, 0x00, 0x1a, 0x09, 0x00] }
    static func lookup(_ feature: UInt16, slot: UInt8 = device) -> [UInt8] {
        [0x10, slot, 0x00, 0x0a, UInt8(feature >> 8), UInt8(feature & 0xff), 0x00]
    }
    static func lookupReply(_ index: UInt8, slot: UInt8 = device) -> [UInt8] { bytes(0x11, slot, 0x00, 0x0a, index) }

    /// A control the mouse lists without analytics key events (flags2 `0x03`, like the probe's 0xd7).
    static let unwatchable = CID(rawValue: 0xD7)
    /// Per control: flags (byte 4 of its info) and flags2 (byte 8; bit 0x04 = analytics key events).
    static let controls: [(CID, flags: UInt8, flags2: UInt8)] = [
        (.hapticPanel, 0x31, 0x05), (.gesture, 0x31, 0x05), (.left, 0x01, 0x04), (.back, 0x31, 0x05),
        (unwatchable, 0x01, 0x03), (.smartShift, 0x31, 0x05),
    ]

    static func divert(_ cid: CID) -> [UInt8] {
        [0x10, device, reprog, 0x3a, UInt8(cid.rawValue >> 8), UInt8(cid.rawValue & 0xff), 0x03]
    }
    static func release(_ cid: CID) -> [UInt8] {
        [0x10, device, reprog, 0x3a, UInt8(cid.rawValue >> 8), UInt8(cid.rawValue & 0xff), 0x02]
    }
    /// `setControlReporting` with the analytics bit: a long report (`cid_hi cid_lo 00 00 00 03|02`).
    static func watch(_ cid: CID, on: Bool = true) -> [UInt8] {
        bytes(0x11, device, reprog, 0x3a, UInt8(cid.rawValue >> 8), UInt8(cid.rawValue & 0xff), 0x00, 0x00, 0x00,
              on ? 0x03 : 0x02)
    }
    static func unwatch(_ cid: CID) -> [UInt8] { watch(cid, on: false) }
    /// The reply: the CID, divert flags, remap, and byte 5 = 01 (on) / 00 (off).
    static func watchReply(_ cid: CID, on: Bool = true) -> [UInt8] {
        bytes(0x11, device, reprog, 0x3a, UInt8(cid.rawValue >> 8), UInt8(cid.rawValue & 0xff), 0x00, 0x00, 0x00,
              on ? 0x01 : 0x00)
    }
    /// An analytics key event of the SmartShift button (function 2: `00 c4 01` pressed, `00 c4 00` released).
    static func smartShiftKey(pressed: Bool) -> [UInt8] {
        bytes(0x11, device, reprog, 0x20, 0x00, 0xc4, pressed ? 0x01 : 0x00)
    }
    static let wheelDivert: [UInt8] = [0x10, device, wheel, 0x2a, 0x01, 0x00, 0x00]
    static let wheelRelease: [UInt8] = [0x10, device, wheel, 0x2a, 0x00, 0x00, 0x00]
    static func play(_ pattern: UInt8) -> [UInt8] { [0x10, device, haptic, 0x4a, pattern, 0x00, 0x00] }
    /// `0x19B0` function 2: enabled, `strength`.
    static func writeStrength(_ strength: UInt8) -> [UInt8] { [0x10, device, haptic, 0x2a, 0x01, strength, 0x00] }
    static func strengthWritten(_ strength: UInt8) -> [UInt8] { bytes(0x11, device, haptic, 0x2a, 0x01, strength) }
    /// `0x19C0` function 3: button 0, `value`.
    static func writeForce(_ value: UInt16) -> [UInt8] {
        [0x10, device, force, 0x3a, 0x00, UInt8(value >> 8), UInt8(value & 0xff)]
    }
    static let readForceCount: [UInt8] = [0x10, device, force, 0x0a, 0x00, 0x00, 0x00]
    static let readForceInfo: [UInt8] = [0x10, device, force, 0x1a, 0x00, 0x00, 0x00]
    static let readForceCurrent: [UInt8] = [0x10, device, force, 0x2a, 0x00, 0x00, 0x00]
    static let readHapticConfig: [UInt8] = [0x10, device, haptic, 0x1a, 0x00, 0x00, 0x00]
    static func hapticConfig(strength: UInt8) -> [UInt8] { bytes(0x11, device, haptic, 0x1a, 0x01, strength) }
    static let readControlCount: [UInt8] = [0x10, device, reprog, 0x0a, 0x00, 0x00, 0x00]
    static let controlCountReply = bytes(0x11, device, reprog, 0x0a, UInt8(controls.count))
    static let wheelInfoRequest: [UInt8] = [0x10, device, wheel, 0x0a, 0x00, 0x00, 0x00]
    /// `0x2121` function 1 (getMode) and its reply; function 2 (setMode) with a mode byte and its reply.
    static let readHiResMode: [UInt8] = [0x10, device, hiRes, 0x1a, 0x00, 0x00, 0x00]
    static func hiResMode(_ mode: UInt8) -> [UInt8] { bytes(0x11, device, hiRes, 0x1a, mode) }
    static func setHiResMode(_ mode: UInt8) -> [UInt8] { [0x10, device, hiRes, 0x2a, mode, 0x00, 0x00] }
    static func hiResModeSet(_ mode: UInt8) -> [UInt8] { bytes(0x11, device, hiRes, 0x2a, mode) }
    /// An HID++ 2.0 error reply to setMode (code 5, busy).
    static let setHiResModeError = bytes(0x11, device, 0xff, hiRes, 0x2a, 0x05)
    /// An HID++ 2.0 error reply to getMode (code 5, busy).
    static let readHiResModeError = bytes(0x11, device, 0xff, hiRes, 0x1a, 0x05)
    /// `0x2111` function 1 (read the mode) and its reply `mode threshold torque`; function 2 (write the mode, the
    /// threshold and torque 0 = kept) and its reply, the whole mode.
    static let readWheelMode: [UInt8] = [0x10, device, smartShift, 0x1a, 0x00, 0x00, 0x00]
    static func wheelMode(_ mode: UInt8) -> [UInt8] { bytes(0x11, device, smartShift, 0x1a, mode, 0x0c, 0x4b) }
    static func writeWheelMode(_ mode: UInt8) -> [UInt8] { [0x10, device, smartShift, 0x2a, mode, 0x00, 0x00] }
    static func wheelModeWritten(_ mode: UInt8) -> [UInt8] { bytes(0x11, device, smartShift, 0x2a, mode, 0x0c, 0x4b) }
    /// An HID++ 2.0 error reply to a SmartShift write (code 5, busy).
    static let writeWheelModeError = bytes(0x11, device, 0xff, smartShift, 0x2a, 0x05)
    /// The receiver's notification flags (register 0x00): read, write, and a read reply with `flags` (3 bytes).
    static let readNotificationFlags: [UInt8] = [0x10, 0xff, 0x81, 0x00, 0x00, 0x00, 0x00]
    static func notificationFlags(_ flags: [UInt8]) -> [UInt8] { [0x10, 0xff, 0x81, 0x00] + flags }
    static func writeNotificationFlags(_ flags: [UInt8]) -> [UInt8] { [0x10, 0xff, 0x80, 0x00] + flags }
    static let notificationFlagsWritten: [UInt8] = [0x10, 0xff, 0x80, 0x00, 0x00, 0x00, 0x00]

    /// Scripts every request LogiMouse makes of the mouse and its receiver (whose wireless notifications are on).
    /// `hiResMode`: the wheel mode getMode reads (default 0, as on the user's mouse); nil: the mouse has no `0x2121`.
    /// `smartShiftMode`: the SmartShift mode function 1 reads (1 free spin, 2 ratchet); nil, the default: the mouse
    /// has no `0x2111`.
    static func script(_ fake: some ScriptedReceiver, hapticConfig: [UInt8] = Fixtures.hapticConfig,
                       wheelInfo: [UInt8] = Fixtures.thumbWheelInfo, forceInfo: [UInt8] = Fixtures.forceInfo,
                       hiResMode: UInt8? = 0x00, smartShiftMode: UInt8? = nil) {
        fake.script(readNotificationFlags, replies: [notificationFlags([0x00, 0x01, 0x00])])
        for slot: UInt8 in [1, 3, 4, 5, 6] { fake.script(ping(slot), replies: [emptySlot(slot)]) }
        fake.script(ping(device), replies: [bytes(0x11, device, 0x00, 0x1a, 0x04, 0x05, 0x5a)])
        fake.script(lookup(ReprogControls.featureID), replies: [lookupReply(reprog)])
        fake.script(lookup(Haptics.featureID), replies: [lookupReply(haptic)])
        fake.script(lookup(ThumbWheel.featureID), replies: [lookupReply(wheel)])
        fake.script(lookup(ForceSensing.featureID), replies: [lookupReply(force)])
        fake.script(lookup(HiResWheel.featureID), replies: [lookupReply(hiResMode == nil ? 0 : hiRes)])
        if let hiResMode { fake.script(readHiResMode, replies: [Self.hiResMode(hiResMode)]) }
        for mode: UInt8 in 0...7 { fake.script(setHiResMode(mode), replies: [hiResModeSet(mode)]) }
        fake.script(lookup(SmartShift.featureID), replies: [lookupReply(smartShiftMode == nil ? 0 : smartShift)])
        if let smartShiftMode {
            fake.script(readWheelMode, replies: [wheelMode(smartShiftMode)])
            for mode: UInt8 in 1...2 { fake.script(writeWheelMode(mode), replies: [wheelModeWritten(mode)]) }
        }
        fake.script(readControlCount, replies: [controlCountReply])
        for (index, control) in controls.enumerated() {
            let raw = control.0.rawValue
            fake.script([0x10, device, reprog, 0x1a, UInt8(index), 0x00, 0x00],
                        replies: [bytes(0x11, device, reprog, 0x1a, UInt8(raw >> 8), UInt8(raw & 0xff), 0x00, 0x00,
                                        control.flags, 0x00, 0x00, 0x00, control.flags2)])
            fake.script(divert(control.0), replies: [bytes(0x11, device, reprog, 0x3a, UInt8(raw >> 8), UInt8(raw & 0xff), 0x03)])
            fake.script(release(control.0), replies: [bytes(0x11, device, reprog, 0x3a, UInt8(raw >> 8), UInt8(raw & 0xff), 0x02)])
            fake.script(watch(control.0), replies: [watchReply(control.0)])
            fake.script(unwatch(control.0), replies: [watchReply(control.0, on: false)])
        }
        fake.script(wheelInfoRequest, replies: [wheelInfo])
        fake.script([0x10, device, haptic, 0x1a, 0x00, 0x00, 0x00], replies: [hapticConfig])
        fake.script(wheelDivert, replies: [Fixtures.thumbWheelSetReply])
        fake.script(wheelRelease, replies: [Fixtures.thumbWheelSetReply])
        fake.script(readForceCount, replies: [Fixtures.forceButtonCount])
        fake.script(readForceInfo, replies: [forceInfo])
        fake.script(readForceCurrent, replies: [Fixtures.forceCurrent])
        for strength: UInt8 in 0...100 { fake.script(writeStrength(strength), replies: [strengthWritten(strength)]) }
        for value: UInt16 in [3799, 4000, 4749, 6316] {
            fake.script(writeForce(value),
                        replies: [bytes(0x11, device, force, 0x3a, 0x00, UInt8(value >> 8), UInt8(value & 0xff))])
        }
    }
}

/// A keyboard on slot 1 of the same receiver: it answers pings and has REPROG_CONTROLS_V4 (index 8, no controls) but
/// neither haptics nor a thumb wheel.
private enum Keyboard {
    static let slot: UInt8 = 1
    static let reprog: UInt8 = 0x08
    static let readControlCount: [UInt8] = [0x10, slot, reprog, 0x0a, 0x00, 0x00, 0x00]

    static func script(_ fake: FakeTransport) {
        fake.script(MX4.ping(slot), replies: [bytes(0x11, slot, 0x00, 0x1a, 0x04, 0x05, 0x5a)])
        fake.script(MX4.lookup(ReprogControls.featureID, slot: slot), replies: [MX4.lookupReply(reprog, slot: slot)])
        fake.script(MX4.lookup(Haptics.featureID, slot: slot), replies: [MX4.lookupReply(0, slot: slot)])
        fake.script(MX4.lookup(ThumbWheel.featureID, slot: slot), replies: [MX4.lookupReply(0, slot: slot)])
        fake.script(MX4.lookup(ForceSensing.featureID, slot: slot), replies: [MX4.lookupReply(0, slot: slot)])
        fake.script(MX4.lookup(HiResWheel.featureID, slot: slot), replies: [MX4.lookupReply(0, slot: slot)])
        fake.script(MX4.lookup(SmartShift.featureID, slot: slot), replies: [MX4.lookupReply(0, slot: slot)])
        fake.script(readControlCount, replies: [bytes(0x11, slot, reprog, 0x0a, 0x00)])
    }

    /// The receiver's notice that a device on `slot` linked.
    static func linked(_ slot: UInt8) -> [UInt8] { [0x10, slot, 0x41, 0x10, 0x02, 0x42, 0xb0] }
}

/// A `LogiMouse` on fake transports and a test clock, with every event it emits collected.
@MainActor
private final class Rig {
    let clock = TestClock()
    let mouse: LogiMouse
    /// The mouse's hi-res marker ("this app turned the wheel to high resolution").
    let marker: MemoryHiResMarker
    /// The mouse's wheel-mode marker (the mode the mouse had before this app wrote its own).
    let wheelModeMarker: MemoryWheelModeMarker
    private let arrivals: AsyncStream<any HIDPPTransport>.Continuation
    private let received = EventLog()
    private let reader: Task<Void, Never>

    init(requestTimeout: Duration = .seconds(2), softwareID: UInt8 = 0x0A,
         hiResMarker: MemoryHiResMarker = MemoryHiResMarker(),
         wheelModeMarker: MemoryWheelModeMarker = MemoryWheelModeMarker()) {
        let (stream, continuation) = AsyncStream.makeStream(of: (any HIDPPTransport).self)
        arrivals = continuation
        marker = hiResMarker
        self.wheelModeMarker = wheelModeMarker
        mouse = LogiMouse(transports: stream, clock: clock, requestTimeout: requestTimeout, softwareID: softwareID,
                          hiResMarker: hiResMarker, wheelModeMarker: wheelModeMarker)
        let events = mouse.events
        reader = Task { [received] in
            for await event in events { received.append(event) }
        }
        mouse.start()
    }

    deinit {
        reader.cancel()
    }

    func plug(_ transport: any HIDPPTransport) {
        arrivals.yield(transport)
    }

    /// A scripted MX Master 4 receiver, plugged in, once `.connected` arrived.
    func connectedMouse(hapticConfig: [UInt8] = Fixtures.hapticConfig, wheelInfo: [UInt8] = Fixtures.thumbWheelInfo,
                        forceInfo: [UInt8] = Fixtures.forceInfo, hiResMode: UInt8? = 0x00,
                        smartShiftMode: UInt8? = nil) async throws -> FakeTransport {
        let fake = FakeTransport()
        MX4.script(fake, hapticConfig: hapticConfig, wheelInfo: wheelInfo, forceInfo: forceInfo, hiResMode: hiResMode,
                   smartShiftMode: smartShiftMode)
        let before = count(.connected)
        plug(fake)
        try #require(await eventually { self.count(.connected) == before + 1 })
        return fake
    }

    /// Events with their times zeroed (synthesised releases carry the current time).
    var events: [MouseEvent] { timedEvents.map(\.untimed) }

    var timedEvents: [MouseEvent] { received.all }

    func count(_ event: MouseEvent) -> Int { events.filter { $0 == event }.count }
}

private final class EventLog: Sendable {
    private let events = Mutex<[MouseEvent]>([])

    func append(_ event: MouseEvent) { events.withLock { $0.append(event) } }
    var all: [MouseEvent] { events.withLock { $0 } }
}

private extension MouseEvent {
    var untimed: MouseEvent {
        switch self {
        case .pressed(let cid, _): .pressed(cid, at: 0)
        case .released(let cid, _): .released(cid, at: 0)
        case .thumbWheel(let delta, let touching, let phase, _): .thumbWheel(delta: delta, touching: touching, phase: phase, at: 0)
        case .connected, .disconnected, .highResolutionWheel, .wheelMode: self
        }
    }
}

private extension [UInt8] {
    /// A request of the fixtures (software ID 0x0A) as a process with software ID 0x0B sends it.
    var stampedB: [UInt8] { HIDPPReport(bytes: self)!.stamped(softwareID: 0x0B).bytes }
}

private extension FakeTransport {
    func count(_ report: [UInt8]) -> Int { sent.filter { $0.bytes == report }.count }
    func firstIndex(_ report: [UInt8]) -> Int? { sent.firstIndex { $0.bytes == report } }
    func lastIndex(_ report: [UInt8]) -> Int? { sent.lastIndex { $0.bytes == report } }
    var plays: [[UInt8]] { sent.map(\.bytes).filter { $0[2] == MX4.haptic && $0[3] == 0x4a } }
    /// Haptic-strength writes (`0x19B0` function 2) and panel-force writes (`0x19C0` function 3), as sent.
    var strengthWrites: [[UInt8]] { sent.map(\.bytes).filter { $0[2] == MX4.haptic && $0[3] == 0x2a } }
    var forceWrites: [[UInt8]] { sent.map(\.bytes).filter { $0[2] == MX4.force && $0[3] == 0x3a } }
    /// The sent haptic commands (strength writes and plays), in order.
    var hapticCommands: [[UInt8]] {
        sent.map(\.bytes).filter { $0[2] == MX4.haptic && ($0[3] == 0x2a || $0[3] == 0x4a) }
    }
    var diverts: Int { sent.filter { $0.bytes[2] == MX4.reprog && $0.bytes[3] == 0x3a && $0.bytes[6] == 0x03 }.count }
    /// The mode bytes of the hi-res setMode requests (`0x2121` function 2), in order.
    var hiResWrites: [UInt8] { sent.map(\.bytes).filter { $0[2] == MX4.hiRes && $0[3] == 0x2a }.map { $0[4] } }
    /// The mode bytes of the SmartShift mode writes (`0x2111` function 2), in order.
    var wheelModeWrites: [UInt8] {
        sent.map(\.bytes).filter { $0[2] == MX4.smartShift && $0[3] == 0x2a }.map { $0[4] }
    }
    /// Every `0x2111` request sent (reads and writes; not the root lookup of its index).
    var smartShiftRequests: Int { sent.filter { $0.bytes[2] == MX4.smartShift }.count }
}

/// Lets queued main-actor tasks and fake replies run, for checks that something did NOT happen.
private func settle() async {
    try? await Task.sleep(for: .milliseconds(50))
}

@MainActor @Suite struct LogiMouseTests {
    // MARK: - Discovery

    @Test func discoveryPicksSlotTwoAndEmitsConnected() async throws {
        let rig = Rig()
        let fake = FakeTransport()
        MX4.script(fake)
        #expect(rig.mouse.isConnected == false)

        rig.plug(fake)

        #expect(await eventually { rig.events == [.connected] })
        #expect(rig.mouse.isConnected)
        #expect(rig.mouse.controls == [Control(cid: .hapticPanel, divertable: true, watchable: true),
                                       Control(cid: .gesture, divertable: true, watchable: true),
                                       Control(cid: .left, divertable: false, watchable: true),
                                       Control(cid: .back, divertable: true, watchable: true),
                                       Control(cid: MX4.unwatchable, divertable: false, watchable: false),
                                       Control(cid: .smartShift, divertable: true, watchable: true)])
        #expect(rig.mouse.stepsPerRevolution == 120)
        #expect(Set(fake.sent.filter { $0.bytes[2] == 0x00 && $0.bytes[3] == 0x1a }.map(\.deviceIndex)) == [1, 2, 3, 4, 5, 6])
    }

    @Test func discoverySkipsADeviceWithoutReprogControls() async throws {
        let rig = Rig()
        let fake = FakeTransport()
        MX4.script(fake)
        fake.script(MX4.ping(1), replies: [bytes(0x11, 0x01, 0x00, 0x1a, 0x04, 0x05, 0x5a)])
        fake.script(MX4.lookup(ReprogControls.featureID, slot: 1), replies: [MX4.lookupReply(0, slot: 1)])

        rig.plug(fake)

        #expect(await eventually { rig.events == [.connected] })
        #expect(fake.count(MX4.lookup(ReprogControls.featureID, slot: 1)) == 1)
        #expect(fake.count(MX4.readControlCount) == 1)
    }

    @Test func zeroDivertedResolutionGivesNoStepsPerRevolution() async throws {
        let rig = Rig()
        var info = Fixtures.thumbWheelInfo
        info[6] = 0
        info[7] = 0
        _ = try await rig.connectedMouse(wheelInfo: info)
        #expect(rig.mouse.stepsPerRevolution == nil)
    }

    @Test func aFailedSetupIsRetriedFiveSecondsLater() async throws {
        let rig = Rig()
        let fake = FakeTransport()
        MX4.script(fake)
        fake.script(MX4.readControlCount, replies: [bytes(0x11, MX4.device, 0xff, MX4.reprog, 0x0a, 0x05)])

        rig.plug(fake)
        #expect(await eventually { fake.count(MX4.readControlCount) == 1 && rig.clock.sleeperCount == 1 })
        #expect(rig.mouse.isConnected == false)

        fake.script(MX4.readControlCount, replies: [MX4.controlCountReply])
        rig.clock.advance(by: .seconds(4))
        await settle()
        #expect(fake.count(MX4.readControlCount) == 1)

        rig.clock.advance(by: .seconds(1))
        #expect(await eventually { rig.events == [.connected] })
        #expect(fake.count(MX4.lookup(ReprogControls.featureID)) == 2)   // forgotten before the retry
    }

    @Test func discoveryPrefersAMouseOverAKeyboard() async throws {
        let rig = Rig()
        let fake = FakeTransport()
        MX4.script(fake)
        Keyboard.script(fake)

        rig.plug(fake)

        #expect(await eventually { rig.events == [.connected] })
        #expect(fake.count(MX4.readControlCount) == 1)
        #expect(fake.count(Keyboard.readControlCount) == 0)
    }

    @Test func noticesDuringTheSearchDoNotCancelIt() async throws {
        let rig = Rig()
        let fake = FakeTransport()
        MX4.script(fake)
        Keyboard.script(fake)
        fake.push(Keyboard.linked(MX4.device))   // read by the channel right after the search starts
        fake.push(Keyboard.linked(Keyboard.slot))

        rig.plug(fake)

        #expect(await eventually { rig.events == [.connected] })
        await settle()
        #expect(rig.events == [.connected])
        #expect(fake.count(MX4.readControlCount) >= 1)
        #expect(fake.count(Keyboard.readControlCount) == 0)
    }

    @Test func aNoticeForASlotWithoutAMouseFallsBackToDiscovery() async throws {
        let rig = Rig()
        let fake = FakeTransport()
        MX4.script(fake)
        fake.script(MX4.ping(MX4.device), replies: [MX4.emptySlot(MX4.device)])   // off during the first search
        rig.plug(fake)
        #expect(await eventually { fake.count(MX4.ping(6)) == 1 })
        await settle()
        #expect(rig.events.isEmpty)

        fake.script(MX4.ping(MX4.device), replies: [bytes(0x11, MX4.device, 0x00, 0x1a, 0x04, 0x05, 0x5a)])
        fake.script(MX4.lookup(ReprogControls.featureID, slot: 4), replies: [[0x10, 0x04, 0x8f, 0x00, 0x0a, 0x09, 0x00]])
        fake.push(Keyboard.linked(4))

        #expect(await eventually { rig.events == [.connected] })
        #expect(fake.count(MX4.ping(MX4.device)) == 2)
    }

    @Test func aKeyboardIsTheFallbackUntilTheMouseLinks() async throws {
        let rig = Rig()
        let fake = FakeTransport()
        MX4.script(fake)
        Keyboard.script(fake)
        fake.script(MX4.ping(MX4.device), replies: [MX4.emptySlot(MX4.device)])   // the mouse is off
        rig.plug(fake)
        #expect(await eventually { rig.events == [.connected] })
        #expect(fake.count(Keyboard.readControlCount) == 1)
        #expect(rig.mouse.controls.isEmpty)

        fake.push(Fixtures.connectionUp)   // the mouse switched on

        #expect(await eventually { rig.events == [.connected, .disconnected, .connected] })
        #expect(fake.count(MX4.readControlCount) == 1)
        #expect(rig.mouse.stepsPerRevolution == 120)
    }

    @Test func failingOptionalReadsLeaveTheirFeatureAbsent() async throws {
        let rig = Rig()
        rig.mouse.setActive(true)
        let fake = FakeTransport()
        MX4.script(fake)
        fake.script(MX4.wheelInfoRequest, replies: [bytes(0x11, MX4.device, 0xff, MX4.wheel, 0x0a, 0x05)])
        fake.script([0x10, MX4.device, MX4.haptic, 0x1a, 0x00, 0x00, 0x00],
                    replies: [bytes(0x11, MX4.device, 0xff, MX4.haptic, 0x1a, 0x05)])

        rig.plug(fake)

        #expect(await eventually { rig.events == [.connected] })
        #expect(rig.mouse.stepsPerRevolution == nil)
        rig.mouse.play(haptic: try #require(HapticPattern(2)))
        await settle()
        #expect(fake.plays.isEmpty)
    }

    // MARK: - Foreground rule

    @Test func startupReleasesWantedControlsBeforeAnyDivert() async throws {
        let rig = Rig()
        rig.mouse.divert([.hapticPanel, .gesture])
        rig.mouse.divertThumbWheel(true)
        rig.mouse.setActive(true)

        let fake = try await rig.connectedMouse()

        #expect(await eventually { fake.count(MX4.divert(.hapticPanel)) == 1 && fake.count(MX4.wheelDivert) == 1 })
        let firstDivert = try #require(fake.sent.firstIndex { $0.bytes[6] == 0x03 && $0.bytes[2] == MX4.reprog && $0.bytes[3] == 0x3a })
        for release in [MX4.release(.hapticPanel), MX4.release(.gesture), MX4.wheelRelease] {
            let index = try #require(fake.firstIndex(release))
            #expect(index < firstDivert)
            #expect(index < fake.firstIndex(MX4.wheelDivert)!)
        }
        let connectedAt = try #require(rig.events.firstIndex(of: .connected))
        #expect(connectedAt == 0)
    }

    @Test func inactiveStartupReleasesButDoesNotDivert() async throws {
        let rig = Rig()
        rig.mouse.divert([.hapticPanel])
        let fake = try await rig.connectedMouse()
        await settle()
        #expect(fake.count(MX4.release(.hapticPanel)) == 1)
        #expect(fake.diverts == 0)
    }

    @Test func activationDivertsAndAgainAfter300ms() async throws {
        let rig = Rig()
        rig.mouse.divert([.hapticPanel, .left])   // .left is not divertable: never sent
        rig.mouse.divertThumbWheel(true)
        let fake = try await rig.connectedMouse()

        rig.mouse.setActive(true)
        #expect(await eventually { fake.count(MX4.divert(.hapticPanel)) == 1 && fake.count(MX4.wheelDivert) == 1 })

        rig.clock.advance(by: .milliseconds(299))
        await settle()
        #expect(fake.count(MX4.divert(.hapticPanel)) == 1)

        rig.clock.advance(by: .milliseconds(1))
        #expect(await eventually { fake.count(MX4.divert(.hapticPanel)) == 2 && fake.count(MX4.wheelDivert) == 2 })
        #expect(fake.count(MX4.divert(.left)) == 0)
    }

    @Test func deactivationWithin300msReleasesAndCancelsTheReapply() async throws {
        let rig = Rig()
        rig.mouse.divert([.hapticPanel])
        rig.mouse.divertThumbWheel(true)
        let fake = try await rig.connectedMouse()

        rig.mouse.setActive(true)
        #expect(await eventually { fake.count(MX4.divert(.hapticPanel)) == 1 && fake.count(MX4.wheelDivert) == 1 })
        rig.clock.advance(by: .milliseconds(100))
        rig.mouse.setActive(false)
        #expect(await eventually { fake.count(MX4.release(.hapticPanel)) == 2 && fake.count(MX4.wheelRelease) == 2 })

        rig.clock.advance(by: .milliseconds(500))
        await settle()
        #expect(fake.count(MX4.divert(.hapticPanel)) == 1)
        #expect(fake.count(MX4.wheelDivert) == 1)
        #expect(fake.lastIndex(MX4.release(.hapticPanel))! > fake.lastIndex(MX4.divert(.hapticPanel))!)
    }

    @Test func reactivationRestartsTheReapplyWindow() async throws {
        let rig = Rig()
        rig.mouse.divert([.hapticPanel])
        let fake = try await rig.connectedMouse()

        rig.mouse.setActive(true)                              // t = 0: reapply due at 300
        #expect(await eventually { fake.count(MX4.divert(.hapticPanel)) == 1 })
        rig.clock.advance(by: .milliseconds(100))
        rig.mouse.setActive(false)                             // t = 100: cancels it
        #expect(await eventually { fake.count(MX4.release(.hapticPanel)) == 2 })
        rig.clock.advance(by: .milliseconds(100))
        rig.mouse.setActive(true)                              // t = 200: reapply due at 500
        #expect(await eventually { fake.count(MX4.divert(.hapticPanel)) == 2 })

        rig.clock.advance(by: .milliseconds(150))              // t = 350: the first activation's reapply is gone
        await settle()
        #expect(fake.count(MX4.divert(.hapticPanel)) == 2)

        rig.clock.advance(by: .milliseconds(150))              // t = 500
        #expect(await eventually { fake.count(MX4.divert(.hapticPanel)) == 3 })
    }

    @Test func aSecondBindingSendsNoLeftoverReleaseWhileInactive() async throws {
        let rig = Rig()
        rig.mouse.divert([.hapticPanel])
        let first = try await rig.connectedMouse()
        #expect(first.count(MX4.release(.hapticPanel)) == 1)

        first.push(Fixtures.connectionLost)
        first.push(Fixtures.connectionUp)
        #expect(await eventually { rig.events == [.connected, .disconnected, .connected] })
        first.pushRemoved()
        let second = try await rig.connectedMouse()
        await settle()

        #expect(first.count(MX4.release(.hapticPanel)) == 1)
        #expect(second.count(MX4.release(.hapticPanel)) == 0)
    }

    @Test func anActiveRebindingReappliesAfter300ms() async throws {
        let rig = Rig()
        rig.mouse.divert([.hapticPanel])
        rig.mouse.setActive(true)
        let fake = try await rig.connectedMouse()
        #expect(await eventually { fake.count(MX4.divert(.hapticPanel)) == 1 })
        rig.clock.advance(by: .milliseconds(300))
        #expect(await eventually { fake.count(MX4.divert(.hapticPanel)) == 2 })

        fake.push(Fixtures.connectionLost)
        fake.push(Fixtures.connectionUp)
        #expect(await eventually { fake.count(MX4.divert(.hapticPanel)) == 3 })
        rig.clock.advance(by: .milliseconds(299))
        await settle()
        #expect(fake.count(MX4.divert(.hapticPanel)) == 3)
        rig.clock.advance(by: .milliseconds(1))
        #expect(await eventually { fake.count(MX4.divert(.hapticPanel)) == 4 })
    }

    @Test func aLostDivertReplyDoesNotDelayLaterWrites() async throws {
        let rig = Rig(requestTimeout: .milliseconds(300))
        rig.mouse.setActive(true)
        let fake = try await rig.connectedMouse()
        fake.script(MX4.divert(.hapticPanel), replies: [])   // this reply is lost
        rig.mouse.divert([.hapticPanel, .gesture])           // gesture (0xC3) is written first, then the panel
        #expect(await eventually { fake.count(MX4.divert(.hapticPanel)) == 1 })
        try await Task.sleep(for: .milliseconds(400))        // the panel divert timed out: a tombstone for 5 s

        rig.mouse.setActive(false)                           // releases: gesture, then panel

        #expect(await eventually(.milliseconds(150)) { fake.count(MX4.release(.hapticPanel)) == 1 })
    }

    @Test func aReleaseAwaitingItsReplyIsSentAgainAtExit() async throws {
        let rig = Rig()
        rig.mouse.setActive(true)
        let fake = try await rig.connectedMouse()
        rig.mouse.divert([.hapticPanel])
        #expect(await eventually { fake.count(MX4.divert(.hapticPanel)) == 1 })
        fake.script(MX4.release(.hapticPanel), replies: [])   // the release's reply has not come yet
        rig.mouse.setActive(false)
        #expect(await eventually { fake.count(MX4.release(.hapticPanel)) == 1 })

        rig.mouse.releaseAllSync()

        #expect(fake.count(MX4.release(.hapticPanel)) == 2)
    }

    @Test func nothingIsWrittenWhileARelinkedMouseIsSetUp() async throws {
        let rig = Rig()
        rig.mouse.setActive(true)
        let fake = try await rig.connectedMouse()
        rig.mouse.divert([.hapticPanel])
        #expect(await eventually { fake.count(MX4.divert(.hapticPanel)) == 1 })
        fake.script(MX4.readControlCount, replies: [])   // setup stalls on this read

        fake.push(Fixtures.connectionUp)                 // a second "linked" while connected
        #expect(await eventually { fake.count(MX4.readControlCount) == 2 })
        rig.mouse.divert([.hapticPanel, .gesture])
        await settle()

        #expect(fake.count(MX4.divert(.gesture)) == 0)
    }

    @Test func connectionNoticesAfterReleaseAllSyncAreIgnored() async throws {
        let rig = Rig()
        let fake = try await rig.connectedMouse()
        rig.mouse.releaseAllSync()
        let sent = fake.sent.count

        fake.push(Fixtures.connectionLost)
        fake.push(Fixtures.connectionUp)
        await settle()

        #expect(fake.sent.count == sent)
        #expect(rig.events == [.connected])
    }

    @Test func changingTheWantedSetReleasesDroppedControls() async throws {
        let rig = Rig()
        rig.mouse.setActive(true)
        let fake = try await rig.connectedMouse()
        rig.mouse.divert([.hapticPanel, .gesture])
        #expect(await eventually { fake.count(MX4.divert(.gesture)) == 1 && fake.count(MX4.divert(.hapticPanel)) == 1 })

        rig.mouse.divert([.hapticPanel])

        #expect(await eventually { fake.count(MX4.release(.gesture)) == 1 })
        #expect(fake.count(MX4.release(.hapticPanel)) == 0)
    }

    @Test func releaseAllReleasesAndClearsTheWantedState() async throws {
        let rig = Rig()
        rig.mouse.setActive(true)
        let fake = try await rig.connectedMouse()
        rig.mouse.divert([.hapticPanel])
        rig.mouse.divertThumbWheel(true)
        #expect(await eventually { fake.count(MX4.divert(.hapticPanel)) == 1 && fake.count(MX4.wheelDivert) == 1 })

        rig.mouse.releaseAll()

        #expect(await eventually { fake.count(MX4.release(.hapticPanel)) == 1 && fake.count(MX4.wheelRelease) == 1 })
        rig.clock.advance(by: .seconds(1))
        await settle()
        #expect(fake.count(MX4.divert(.hapticPanel)) == 1)
    }

    @Test func releaseAllSyncReleasesBeforeReturningAndWritesNothingAfter() async throws {
        let rig = Rig()
        rig.mouse.divert([.hapticPanel])
        rig.mouse.divertThumbWheel(true)
        rig.mouse.setActive(true)
        let fake = try await rig.connectedMouse()
        #expect(await eventually { fake.count(MX4.divert(.hapticPanel)) == 1 && fake.count(MX4.wheelDivert) == 1 })
        let releasesBefore = fake.count(MX4.release(.hapticPanel))

        rig.mouse.releaseAllSync()

        #expect(fake.count(MX4.release(.hapticPanel)) == releasesBefore + 1)   // no await in between
        #expect(fake.count(MX4.wheelRelease) == 2)
        let sentAfter = fake.sent.count
        rig.clock.advance(by: .seconds(1))
        rig.mouse.setActive(false)
        rig.mouse.setActive(true)
        rig.mouse.play(haptic: try #require(HapticPattern(1)))
        await settle()
        #expect(fake.sent.count == sentAfter)
    }

    // MARK: - Buttons and the thumb wheel

    @Test func panelPressAndRelease() async throws {
        let rig = Rig()
        rig.mouse.divert([.hapticPanel])
        rig.mouse.setActive(true)
        let fake = try await rig.connectedMouse()

        fake.push(Fixtures.panelPressed, at: 10)
        fake.push(Fixtures.allReleased, at: 11)

        #expect(await eventually { rig.events.count == 3 })
        #expect(rig.events == [.connected, .pressed(.hapticPanel, at: 0), .released(.hapticPanel, at: 0)])
    }

    @Test func pressTimesComeFromTheReports() async throws {
        let rig = Rig()
        rig.mouse.divert([.hapticPanel])
        rig.mouse.setActive(true)
        let fake = try await rig.connectedMouse()

        fake.push(Fixtures.panelPressed, at: 10)
        fake.push(Fixtures.allReleased, at: 11)

        #expect(await eventually { rig.timedEvents.count == 3 })
        #expect(rig.timedEvents == [.connected, .pressed(.hapticPanel, at: 10), .released(.hapticPanel, at: 11)])
    }

    @Test func aHeldControlLeavingTheWantedSetIsReleased() async throws {
        let rig = Rig()
        rig.mouse.divert([.hapticPanel, .gesture])
        rig.mouse.setActive(true)
        let fake = try await rig.connectedMouse()
        fake.push(bytes(0x11, MX4.device, MX4.reprog, 0x00, 0x01, 0xa0, 0x00, 0xc3))   // panel and gesture held
        #expect(await eventually { rig.events.count == 3 })

        rig.mouse.divert([.hapticPanel, .back])

        #expect(await eventually { rig.events.count == 4 })
        #expect(rig.events == [.connected, .pressed(.hapticPanel, at: 0), .pressed(.gesture, at: 0),
                               .released(.gesture, at: 0)])
    }

    @Test func eventsAreDroppedWhileInactive() async throws {
        let rig = Rig()
        rig.mouse.divert([.hapticPanel])
        rig.mouse.divertThumbWheel(true)
        let fake = try await rig.connectedMouse()

        fake.push(Fixtures.panelPressed)
        fake.push(Fixtures.thumbWheelStartPlus)
        fake.push(Fixtures.allReleased)
        await settle()

        #expect(rig.events == [.connected])
    }

    @Test func deactivationReleasesHeldControls() async throws {
        let rig = Rig()
        rig.mouse.divert([.hapticPanel])
        rig.mouse.setActive(true)
        let fake = try await rig.connectedMouse()
        fake.push(Fixtures.panelPressed)
        #expect(await eventually { rig.events.count == 2 })

        rig.mouse.setActive(false)

        #expect(await eventually { rig.events.count == 3 })
        #expect(rig.events == [.connected, .pressed(.hapticPanel, at: 0), .released(.hapticPanel, at: 0)])
    }

    @Test func thumbWheelEventsCarryTheirPhases() async throws {
        let rig = Rig()
        rig.mouse.divertThumbWheel(true)
        rig.mouse.setActive(true)
        let fake = try await rig.connectedMouse()

        for report in [Fixtures.thumbWheelTouch, Fixtures.thumbWheelStartPlus, Fixtures.thumbWheelActivePlus,
                       Fixtures.thumbWheelStop, Fixtures.thumbWheelStartMinus, Fixtures.thumbWheelActiveMinus,
                       Fixtures.thumbWheelLift] {
            fake.push(report)
        }

        #expect(await eventually { rig.events.count == 8 })
        #expect(Array(rig.events.dropFirst()) == [
            .thumbWheel(delta: 0, touching: true, phase: .changed, at: 0),
            .thumbWheel(delta: 1, touching: true, phase: .began, at: 0),
            .thumbWheel(delta: 1, touching: true, phase: .changed, at: 0),
            .thumbWheel(delta: 0, touching: false, phase: .ended, at: 0),
            .thumbWheel(delta: -1, touching: true, phase: .began, at: 0),
            .thumbWheel(delta: -1, touching: true, phase: .changed, at: 0),
            .thumbWheel(delta: 0, touching: false, phase: .changed, at: 0),
        ])
    }

    @Test func thumbWheelEventsNeedTheWheelWanted() async throws {
        let rig = Rig()
        rig.mouse.setActive(true)
        let fake = try await rig.connectedMouse()
        fake.push(Fixtures.thumbWheelStartPlus)
        await settle()
        #expect(rig.events == [.connected])
    }

    // MARK: - Disconnect and reconnect

    @Test func disconnectMidPressReleasesThenDisconnects() async throws {
        let rig = Rig()
        rig.mouse.divert([.hapticPanel])
        rig.mouse.setActive(true)
        let fake = try await rig.connectedMouse()
        fake.push(Fixtures.panelPressed)
        #expect(await eventually { rig.events.count == 2 })

        fake.push(Fixtures.connectionLost)

        #expect(await eventually { rig.events.count == 4 })
        #expect(rig.events == [.connected, .pressed(.hapticPanel, at: 0), .released(.hapticPanel, at: 0), .disconnected])
        #expect(rig.mouse.isConnected == false)
    }

    @Test func reconnectReReadsFeaturesAndDivertsAgain() async throws {
        let rig = Rig()
        rig.mouse.divert([.hapticPanel])
        rig.mouse.divertThumbWheel(true)
        rig.mouse.setActive(true)
        let fake = try await rig.connectedMouse()
        #expect(await eventually { fake.count(MX4.divert(.hapticPanel)) == 1 && fake.count(MX4.wheelDivert) == 1 })
        let lookups = fake.count(MX4.lookup(ReprogControls.featureID))
        let reads = fake.count(MX4.readControlCount)

        fake.push(Fixtures.connectionLost)
        #expect(await eventually { rig.events == [.connected, .disconnected] })
        fake.push(Fixtures.connectionUp)

        #expect(await eventually { rig.events == [.connected, .disconnected, .connected] })
        #expect(await eventually { fake.count(MX4.divert(.hapticPanel)) == 2 && fake.count(MX4.wheelDivert) == 2 })
        #expect(fake.count(MX4.lookup(ReprogControls.featureID)) == lookups + 1)
        #expect(fake.count(MX4.lookup(Haptics.featureID)) == 2)
        #expect(fake.count(MX4.lookup(ThumbWheel.featureID)) == 2)
        #expect(fake.count(MX4.readControlCount) == reads + 1)
        #expect(fake.count(MX4.wheelInfoRequest) == 2)
        #expect(rig.mouse.isConnected)
    }

    @Test func aMouseSwitchedOnAfterStartIsFound() async throws {
        let rig = Rig()
        let fake = FakeTransport()
        MX4.script(fake)
        fake.script(MX4.ping(MX4.device), replies: [MX4.emptySlot(MX4.device)])   // switched off
        rig.plug(fake)
        #expect(await eventually { fake.sent.count >= 6 })
        await settle()
        #expect(rig.events.isEmpty)

        fake.push(Fixtures.connectionUp)

        #expect(await eventually { rig.events == [.connected] })
    }

    @Test func receiverRemovalMidPressAndReplug() async throws {
        let rig = Rig()
        rig.mouse.divert([.hapticPanel])
        rig.mouse.setActive(true)
        let first = try await rig.connectedMouse()
        first.push(Fixtures.panelPressed)
        #expect(await eventually { rig.events.count == 2 })

        first.pushRemoved()

        #expect(await eventually { rig.events.count == 4 })
        #expect(rig.events == [.connected, .pressed(.hapticPanel, at: 0), .released(.hapticPanel, at: 0), .disconnected])
        #expect(rig.mouse.isConnected == false)

        let second = try await rig.connectedMouse()
        #expect(await eventually { second.count(MX4.divert(.hapticPanel)) == 1 })
        #expect(rig.mouse.isConnected)
    }

    // MARK: - Watching (analytics key events)

    @Test func watchIsAppliedOnlyWhileActive() async throws {
        let rig = Rig()
        rig.mouse.watch([.back])
        let fake = try await rig.connectedMouse()
        await settle()
        #expect(fake.count(MX4.unwatch(.back)) == 1)   // the startup release; nothing is switched on
        #expect(fake.count(MX4.watch(.back)) == 0)
        #expect(rig.mouse.watching.isEmpty)

        rig.mouse.setActive(true)
        #expect(await eventually { fake.count(MX4.watch(.back)) == 1 })
        #expect(await eventually { rig.mouse.watching == [.back] })

        rig.clock.advance(by: .milliseconds(299))
        await settle()
        #expect(fake.count(MX4.watch(.back)) == 1)
        rig.clock.advance(by: .milliseconds(1))
        #expect(await eventually { fake.count(MX4.watch(.back)) == 2 })
        #expect(rig.mouse.watching == [.back])
        #expect(fake.diverts == 0)
    }

    @Test func startupSwitchesOffWatchedControlsBeforeAnyWatch() async throws {
        let rig = Rig()
        rig.mouse.watch([.back, .forward, MX4.unwatchable])   // .forward is not listed; the other is not watchable
        rig.mouse.setActive(true)

        let fake = try await rig.connectedMouse()

        #expect(await eventually { fake.count(MX4.watch(.back)) == 1 })
        let off = try #require(fake.firstIndex(MX4.unwatch(.back)))
        #expect(off < fake.firstIndex(MX4.watch(.back))!)
        #expect(fake.sent.filter { $0.bytes[2] == MX4.reprog && $0.bytes[3] == 0x3a && $0.bytes[5] != 0x53 }.isEmpty)
    }

    @Test func controlsThatAreNotWatchableAreIgnored() async throws {
        let rig = Rig()
        rig.mouse.setActive(true)
        let fake = try await rig.connectedMouse()

        rig.mouse.watch([MX4.unwatchable, .forward, .back])

        #expect(await eventually { fake.count(MX4.watch(.back)) == 1 })
        await settle()
        #expect(fake.count(MX4.watch(MX4.unwatchable)) == 0)
        #expect(fake.count(MX4.unwatch(MX4.unwatchable)) == 0)
        #expect(rig.mouse.watching == [.back])
    }

    @Test func watchedPressesComeOutAsPressedAndReleased() async throws {
        let rig = Rig()
        rig.mouse.watch([.back, .forward])
        rig.mouse.setActive(true)
        let fake = try await rig.connectedMouse()

        fake.push(Fixtures.backPressedAnalytics, at: 10)
        fake.push(Fixtures.backReleasedAnalytics, at: 11)

        #expect(await eventually { rig.timedEvents.count == 3 })
        #expect(rig.timedEvents == [.connected, .pressed(.back, at: 10), .released(.back, at: 11)])
    }

    @Test func aReportCanCarryTwoWatchedKeys() async throws {
        let rig = Rig()
        rig.mouse.watch([.back, .hapticPanel])
        rig.mouse.setActive(true)
        let fake = try await rig.connectedMouse()

        fake.push(bytes(0x11, MX4.device, MX4.reprog, 0x20, 0x00, 0x53, 0x01, 0x01, 0xa0, 0x01))
        fake.push(bytes(0x11, MX4.device, MX4.reprog, 0x20, 0x01, 0xa0, 0x00, 0x00, 0x53, 0x00))

        #expect(await eventually { rig.events.count == 5 })
        #expect(rig.events == [.connected, .pressed(.back, at: 0), .pressed(.hapticPanel, at: 0),
                               .released(.hapticPanel, at: 0), .released(.back, at: 0)])
    }

    @Test func aRepeatedPressOrAnUnmatchedReleaseEmitsNothing() async throws {
        let rig = Rig()
        rig.mouse.watch([.back])
        rig.mouse.setActive(true)
        let fake = try await rig.connectedMouse()

        fake.push(Fixtures.backReleasedAnalytics)   // no press seen
        fake.push(Fixtures.backPressedAnalytics)
        fake.push(Fixtures.backPressedAnalytics)
        fake.push(Fixtures.backReleasedAnalytics)
        #expect(await eventually { rig.events.count == 3 })
        await settle()

        #expect(rig.events == [.connected, .pressed(.back, at: 0), .released(.back, at: 0)])
    }

    @Test func eventsOfControlsNotWatchedAreIgnored() async throws {
        let rig = Rig()
        rig.mouse.watch([.back])
        rig.mouse.setActive(true)
        let fake = try await rig.connectedMouse()

        fake.push(Fixtures.forwardPressedAnalytics)
        fake.push(Fixtures.forwardReleasedAnalytics)
        await settle()

        #expect(rig.events == [.connected])
    }

    @Test func analyticsEventsWhileInactiveAreIgnored() async throws {
        let rig = Rig()
        rig.mouse.watch([.back])
        let fake = try await rig.connectedMouse()

        fake.push(Fixtures.backPressedAnalytics)
        fake.push(Fixtures.backReleasedAnalytics)
        await settle()

        #expect(rig.events == [.connected])
    }

    @Test func deactivationSwitchesOffAndReleasesAHeldWatchedControl() async throws {
        let rig = Rig()
        rig.mouse.watch([.back])
        rig.mouse.setActive(true)
        let fake = try await rig.connectedMouse()
        #expect(await eventually { rig.mouse.watching == [.back] })
        fake.push(Fixtures.backPressedAnalytics)
        #expect(await eventually { rig.events.count == 2 })

        rig.mouse.setActive(false)

        #expect(rig.mouse.watching.isEmpty)
        #expect(await eventually { rig.events.count == 3 })
        #expect(rig.events == [.connected, .pressed(.back, at: 0), .released(.back, at: 0)])
        #expect(await eventually { fake.count(MX4.unwatch(.back)) == 2 })   // the startup release and this one
        rig.clock.advance(by: .seconds(1))
        await settle()
        #expect(fake.count(MX4.watch(.back)) == 1)

        fake.push(Fixtures.backReleasedAnalytics)   // a late release while inactive
        await settle()
        #expect(rig.events.count == 3)
    }

    @Test func watchIsAppliedAgainAfterAReconnect() async throws {
        let rig = Rig()
        rig.mouse.watch([.back])
        rig.mouse.setActive(true)
        let fake = try await rig.connectedMouse()
        #expect(await eventually { rig.mouse.watching == [.back] })
        fake.push(Fixtures.backPressedAnalytics)
        #expect(await eventually { rig.events.count == 2 })

        fake.push(Fixtures.connectionLost)
        #expect(await eventually { rig.events == [.connected, .pressed(.back, at: 0), .released(.back, at: 0), .disconnected] })
        #expect(rig.mouse.watching.isEmpty)
        fake.push(Fixtures.connectionUp)

        #expect(await eventually { rig.events.last == .connected && rig.events.count == 5 })
        #expect(await eventually { fake.count(MX4.watch(.back)) == 2 })
        #expect(await eventually { rig.mouse.watching == [.back] })
    }

    @Test func releaseAllSyncSendsTheOffReportsOfWatchedControls() async throws {
        let rig = Rig()
        rig.mouse.watch([.back, .hapticPanel])
        rig.mouse.setActive(true)
        let fake = try await rig.connectedMouse()
        #expect(await eventually { fake.count(MX4.watch(.back)) == 1 && fake.count(MX4.watch(.hapticPanel)) == 1 })
        fake.push(Fixtures.backPressedAnalytics)
        #expect(await eventually { rig.events.count == 2 })
        let before = fake.count(MX4.unwatch(.back))

        rig.mouse.releaseAllSync()

        #expect(fake.count(MX4.unwatch(.back)) == before + 1)   // no await in between
        #expect(fake.lastIndex(MX4.unwatch(.hapticPanel))! > fake.lastIndex(MX4.watch(.hapticPanel))!)
        #expect(fake.lastIndex(MX4.unwatch(.back))! > fake.lastIndex(MX4.watch(.back))!)
        #expect(rig.mouse.watching.isEmpty)
        #expect(await eventually { rig.events.count == 3 })
        #expect(rig.events.last == .released(.back, at: 0))
        let sent = fake.sent.count
        rig.clock.advance(by: .seconds(1))
        rig.mouse.setActive(false)
        rig.mouse.setActive(true)
        await settle()
        #expect(fake.sent.count == sent)
    }

    @Test func releaseAllSwitchesOffAndClearsTheWatchSet() async throws {
        let rig = Rig()
        rig.mouse.watch([.back])
        rig.mouse.setActive(true)
        let fake = try await rig.connectedMouse()
        #expect(await eventually { rig.mouse.watching == [.back] })

        rig.mouse.releaseAll()

        #expect(await eventually { fake.count(MX4.unwatch(.back)) == 2 })
        #expect(rig.mouse.watching.isEmpty)
        rig.clock.advance(by: .seconds(1))
        await settle()
        #expect(fake.count(MX4.watch(.back)) == 1)
    }

    @Test func aDivertedControlIsNotAlsoWatched() async throws {
        let rig = Rig()
        rig.mouse.divert([.back])
        rig.mouse.watch([.back, .hapticPanel])
        rig.mouse.setActive(true)
        let fake = try await rig.connectedMouse()
        #expect(await eventually { fake.count(MX4.divert(.back)) == 1 && fake.count(MX4.watch(.hapticPanel)) == 1 })
        await settle()
        #expect(fake.count(MX4.watch(.back)) == 0)
        #expect(rig.mouse.watching == [.hapticPanel])

        fake.push(Fixtures.backPressedAnalytics)   // not expected, and ignored if it comes
        await settle()
        #expect(rig.events == [.connected])

        // The diverted control's own report still works.
        fake.push(bytes(0x11, MX4.device, MX4.reprog, 0x00, 0x00, 0x53))
        #expect(await eventually { rig.events.count == 2 })
        #expect(rig.events == [.connected, .pressed(.back, at: 0)])
    }

    @Test func dropFromTheDivertSetTurnsAWatchOn() async throws {
        let rig = Rig()
        rig.mouse.divert([.back])
        rig.mouse.watch([.back])
        rig.mouse.setActive(true)
        let fake = try await rig.connectedMouse()
        #expect(await eventually { fake.count(MX4.divert(.back)) == 1 })

        rig.mouse.divert([])

        #expect(await eventually { fake.count(MX4.release(.back)) == 2 && fake.count(MX4.watch(.back)) == 1 })
        #expect(await eventually { rig.mouse.watching == [.back] })
    }

    @Test func aDivertTakingAHeldWatchedControlReleasesIt() async throws {
        let rig = Rig()
        rig.mouse.watch([.back])
        rig.mouse.setActive(true)
        let fake = try await rig.connectedMouse()
        fake.push(Fixtures.backPressedAnalytics)
        #expect(await eventually { rig.events.count == 2 })

        rig.mouse.divert([.back])

        #expect(await eventually { rig.events.count == 3 })
        #expect(rig.events.last == .released(.back, at: 0))
        #expect(rig.mouse.watching.isEmpty)
        #expect(await eventually { fake.count(MX4.unwatch(.back)) == 2 && fake.count(MX4.divert(.back)) == 1 })
    }

    @Test func leavingTheWatchSetReleasesAHeldControlAndSwitchesItOff() async throws {
        let rig = Rig()
        rig.mouse.watch([.back, .hapticPanel])
        rig.mouse.setActive(true)
        let fake = try await rig.connectedMouse()
        #expect(await eventually { rig.mouse.watching == [.back, .hapticPanel] })
        fake.push(Fixtures.backPressedAnalytics)
        #expect(await eventually { rig.events.count == 2 })

        rig.mouse.watch([.hapticPanel])

        #expect(await eventually { rig.events.count == 3 })
        #expect(rig.events == [.connected, .pressed(.back, at: 0), .released(.back, at: 0)])
        #expect(rig.mouse.watching == [.hapticPanel])
        #expect(await eventually { fake.count(MX4.unwatch(.back)) == 2 })
        fake.push(Fixtures.backReleasedAnalytics)
        await settle()
        #expect(rig.events.count == 3)
    }

    @Test func watchingIsOnlyWhatTheMouseConfirmed() async throws {
        let rig = Rig(requestTimeout: .milliseconds(200))
        rig.mouse.setActive(true)
        let fake = try await rig.connectedMouse()
        fake.script(MX4.watch(.back), replies: [])   // this reply is lost

        rig.mouse.watch([.back, .hapticPanel])

        #expect(await eventually { rig.mouse.watching == [.hapticPanel] })
        #expect(fake.count(MX4.watch(.back)) == 1)
        try await Task.sleep(for: .milliseconds(300))
        #expect(rig.mouse.watching == [.hapticPanel])
    }

    @Test func anEventOfAWantedButUnconfirmedControlConfirmsItAndIsEmitted() async throws {
        let rig = Rig(requestTimeout: .milliseconds(200))
        rig.mouse.setActive(true)
        let fake = try await rig.connectedMouse()
        fake.script(MX4.watch(.back), replies: [])   // the reply is lost: the mouse has analytics on, we never heard

        rig.mouse.watch([.back])
        #expect(await eventually { fake.count(MX4.watch(.back)) == 1 })
        try await Task.sleep(for: .milliseconds(300))
        #expect(rig.mouse.watching.isEmpty)

        fake.push(Fixtures.backPressedAnalytics, at: 5)

        #expect(await eventually { rig.mouse.watching == [.back] })
        #expect(await eventually { rig.timedEvents == [.connected, .pressed(.back, at: 5)] })
    }

    @Test func anEventOfAnUnwantedControlConfirmsNothing() async throws {
        let rig = Rig()
        rig.mouse.watch([.back])
        rig.mouse.setActive(true)
        let fake = try await rig.connectedMouse()
        #expect(await eventually { rig.mouse.watching == [.back] })

        fake.push(Fixtures.forwardPressedAnalytics)
        fake.push(Fixtures.forwardReleasedAnalytics)
        await settle()

        #expect(rig.mouse.watching == [.back])
        #expect(rig.events == [.connected])
    }

    @Test func aReSetupClearsWatchingAndRestoresIt() async throws {
        let rig = Rig()
        rig.mouse.watch([.back])
        rig.mouse.setActive(true)
        let fake = try await rig.connectedMouse()
        #expect(await eventually { rig.mouse.watching == [.back] })
        // The second "linked" notice: setup fails once (an error reply), so it waits for its retry.
        fake.script(MX4.readControlCount, replies: [bytes(0x11, MX4.device, 0xff, MX4.reprog, 0x0a, 0x05)])

        fake.push(Fixtures.connectionUp)
        // The retry's sleep, not the reapply the first setup left pending: advancing before the retry sleeps would
        // leave it waiting for good.
        #expect(await eventually { rig.mouse.watching.isEmpty && rig.clock.hasSleeper(for: LogiMouse.setupRetryDelay) })

        // The analytics are still on in the mouse: a press during the re-setup is heard and confirms the control.
        fake.push(Fixtures.backPressedAnalytics)
        #expect(await eventually { rig.mouse.watching == [.back] && rig.events.count == 2 })
        fake.push(Fixtures.backReleasedAnalytics)
        #expect(await eventually { rig.events.count == 3 })

        fake.script(MX4.readControlCount, replies: [MX4.controlCountReply])
        rig.clock.advance(by: .seconds(5))
        #expect(await eventually { fake.count(MX4.watch(.back)) >= 2 })
        #expect(await eventually { rig.mouse.watching == [.back] })
    }

    @Test func aReSetupRestoresWatchingFromTheReply() async throws {
        let rig = Rig()
        rig.mouse.watch([.back])
        rig.mouse.setActive(true)
        let fake = try await rig.connectedMouse()
        #expect(await eventually { rig.mouse.watching == [.back] })
        fake.script(MX4.readControlCount, replies: [bytes(0x11, MX4.device, 0xff, MX4.reprog, 0x0a, 0x05)])

        fake.push(Fixtures.connectionUp)
        // The retry's sleep, not the reapply the first setup left pending: advancing before the retry sleeps would
        // leave it waiting for good.
        #expect(await eventually { rig.mouse.watching.isEmpty && rig.clock.hasSleeper(for: LogiMouse.setupRetryDelay) })
        let ons = fake.count(MX4.watch(.back))
        fake.script(MX4.readControlCount, replies: [MX4.controlCountReply])
        rig.clock.advance(by: .seconds(5))

        #expect(await eventually { fake.count(MX4.watch(.back)) > ons })
        #expect(await eventually { rig.mouse.watching == [.back] })
    }

    @Test func aWatchReplyArrivingAfterDeactivationDoesNotLandInWatching() async throws {
        let rig = Rig()
        rig.mouse.setActive(true)
        let fake = try await rig.connectedMouse()
        fake.script(MX4.watch(.back), replies: [])   // the reply comes later, by hand

        rig.mouse.watch([.back])
        #expect(await eventually { fake.count(MX4.watch(.back)) == 1 })
        rig.mouse.setActive(false)
        fake.push(MX4.watchReply(.back))
        await settle()

        #expect(rig.mouse.watching.isEmpty)
    }

    @Test func divertedEventsKeepWorkingBesideWatchedOnes() async throws {
        let rig = Rig()
        rig.mouse.divert([.hapticPanel])
        rig.mouse.watch([.back])
        rig.mouse.setActive(true)
        let fake = try await rig.connectedMouse()

        fake.push(Fixtures.panelPressed, at: 1)
        fake.push(Fixtures.backPressedAnalytics, at: 2)
        fake.push(Fixtures.allReleased, at: 3)            // releases the panel only: the back button is still held
        fake.push(Fixtures.backReleasedAnalytics, at: 4)

        #expect(await eventually { rig.timedEvents.count == 5 })
        #expect(rig.timedEvents == [.connected, .pressed(.hapticPanel, at: 1), .pressed(.back, at: 2),
                                    .released(.hapticPanel, at: 3), .released(.back, at: 4)])
    }

    @Test func aKeyboardFallbackIsNeverWatched() async throws {
        let rig = Rig()
        rig.mouse.watch([.gesture])
        rig.mouse.setActive(true)
        let fake = FakeTransport()
        MX4.script(fake)
        Keyboard.script(fake)
        fake.script(MX4.ping(MX4.device), replies: [MX4.emptySlot(MX4.device)])   // the mouse is off
        fake.script(Keyboard.readControlCount, replies: [bytes(0x11, Keyboard.slot, Keyboard.reprog, 0x0a, 0x01)])
        fake.script([0x10, Keyboard.slot, Keyboard.reprog, 0x1a, 0x00, 0x00, 0x00],
                    replies: [bytes(0x11, Keyboard.slot, Keyboard.reprog, 0x1a, 0x00, 0xc3, 0x00, 0x00, 0x31,
                                    0x00, 0x00, 0x00, 0x05)])
        // Only the startup release (analytics off) is sent to the keyboard.
        fake.script(bytes(0x11, Keyboard.slot, Keyboard.reprog, 0x3a, 0x00, 0xc3, 0x00, 0x00, 0x00, 0x02),
                    replies: [bytes(0x11, Keyboard.slot, Keyboard.reprog, 0x3a, 0x00, 0xc3, 0x00, 0x00, 0x00, 0x00)])

        rig.plug(fake)
        #expect(await eventually { rig.events == [.connected] })
        #expect(rig.mouse.controls == [Control(cid: .gesture, divertable: true, watchable: true)])
        rig.clock.advance(by: .seconds(1))
        await settle()

        #expect(!fake.sent.contains { $0.deviceIndex == Keyboard.slot && $0.function == 3 && $0.bytes[9] == 0x03 })
        #expect(rig.mouse.watching.isEmpty)
    }

    // MARK: - Haptics

    @Test func aBurstOfPlaysSendsTheInFlightOneAndTheLast() async throws {
        let rig = Rig()
        rig.mouse.setActive(true)
        let fake = try await rig.connectedMouse()

        for raw: UInt8 in 1...10 { rig.mouse.play(haptic: try #require(HapticPattern(raw))) }

        #expect(await eventually { fake.plays.count == 2 })
        await settle()
        #expect(fake.plays == [MX4.play(1), MX4.play(10)])
    }

    @Test func playWhileInactiveIsDropped() async throws {
        let rig = Rig()
        let fake = try await rig.connectedMouse()
        rig.mouse.play(haptic: try #require(HapticPattern(3)))
        await settle()
        #expect(fake.plays.isEmpty)
    }

    @Test func playWithHapticsDisabledIsDropped() async throws {
        let rig = Rig()
        rig.mouse.setActive(true)
        let fake = try await rig.connectedMouse(hapticConfig: bytes(0x11, 0x02, 0x0b, 0x1a, 0x00, 0x19))
        rig.mouse.play(haptic: try #require(HapticPattern(3)))
        await settle()
        #expect(fake.plays.isEmpty)
    }

    @Test func playWhileDisconnectedIsDropped() async throws {
        let rig = Rig()
        rig.mouse.setActive(true)
        let fake = try await rig.connectedMouse()
        fake.push(Fixtures.connectionLost)
        #expect(await eventually { rig.mouse.isConnected == false })
        rig.mouse.play(haptic: try #require(HapticPattern(3)))
        await settle()
        #expect(fake.plays.isEmpty)
    }

    // MARK: - Haptic strength and panel force

    /// The mouse's haptic config: enabled, strength 35 (the user's setting).
    private static let strength35 = bytes(0x11, 0x02, 0x0b, 0x1a, 0x01, 0x23)

    @Test func settingsAreReadAtConnectAndNothingIsWrittenUnasked() async throws {
        let rig = Rig()
        rig.mouse.divert([.hapticPanel])
        rig.mouse.setActive(true)
        let fake = try await rig.connectedMouse()
        #expect(rig.mouse.hapticStrength == 25)
        let force = try #require(rig.mouse.panelForce)
        #expect(force.current == 4749)
        #expect(force.info == ForceSensing.Info(changeable: true, defaultValue: 4749, range: 3799...6316))

        rig.mouse.play(haptic: .subtleCollision)
        rig.mouse.play(haptic: .sharpCollision, strength: 25)   // the normal strength: a plain play
        #expect(await eventually { fake.plays.count == 2 })
        rig.clock.advance(by: .seconds(1))
        fake.push(Fixtures.connectionLost)
        fake.push(Fixtures.connectionUp)
        #expect(await eventually { rig.events == [.connected, .disconnected, .connected] })
        rig.mouse.setActive(false)
        await settle()
        rig.mouse.releaseAllSync()

        #expect(fake.strengthWrites.isEmpty)
        #expect(fake.forceWrites.isEmpty)
        #expect(fake.plays == [MX4.play(0x04), MX4.play(0x02)])
    }

    @Test func aStrongPlayWritesTheStrengthPlaysAndRestores() async throws {
        let rig = Rig()
        rig.mouse.setActive(true)
        let fake = try await rig.connectedMouse(hapticConfig: Self.strength35)
        #expect(rig.mouse.hapticStrength == 35)

        rig.mouse.play(haptic: .sharpCollision, strength: 80)

        #expect(await eventually { fake.hapticCommands.count == 3 })
        await settle()
        #expect(fake.hapticCommands == [MX4.writeStrength(80), MX4.play(0x02), MX4.writeStrength(35)])
        #expect(rig.mouse.hapticStrength == 35)
    }

    @Test func aNewerPlayReplacesABlockThatHasNotStarted() async throws {
        let rig = Rig()
        rig.mouse.setActive(true)
        let fake = try await rig.connectedMouse(hapticConfig: Self.strength35)

        rig.mouse.play(haptic: .sharpStateChange, strength: 80)   // starts at once
        rig.mouse.play(haptic: .dampStateChange, strength: 90)    // waits …
        rig.mouse.play(haptic: .sharpCollision, strength: 70)     // … and is replaced

        #expect(await eventually { fake.hapticCommands.count == 6 })
        await settle()
        #expect(fake.hapticCommands == [MX4.writeStrength(80), MX4.play(0x00), MX4.writeStrength(35),
                                        MX4.writeStrength(70), MX4.play(0x02), MX4.writeStrength(35)])
    }

    @Test func aPlainPlayReplacesAWaitingBlock() async throws {
        let rig = Rig()
        rig.mouse.setActive(true)
        let fake = try await rig.connectedMouse(hapticConfig: Self.strength35)

        rig.mouse.play(haptic: .sharpStateChange)
        rig.mouse.play(haptic: .dampStateChange, strength: 90)
        rig.mouse.play(haptic: .sharpCollision)

        #expect(await eventually { fake.plays.count == 2 })
        await settle()
        #expect(fake.hapticCommands == [MX4.play(0x00), MX4.play(0x02)])
    }

    @Test func deactivationMidBlockStillRestoresTheNormalStrength() async throws {
        let rig = Rig()
        rig.mouse.setActive(true)
        let fake = try await rig.connectedMouse(hapticConfig: Self.strength35)

        rig.mouse.play(haptic: .sharpCollision, strength: 80)   // taken by the lane …
        rig.mouse.setActive(false)                              // … before it runs

        #expect(await eventually { fake.count(MX4.writeStrength(35)) == 1 })
        await settle()
        // Inactive: the pattern is not played, but the block ends with the normal strength.
        #expect(fake.hapticCommands == [MX4.writeStrength(80), MX4.writeStrength(35)])
    }

    @Test func deactivationAfterAFailedRestoreWritesTheNormalStrength() async throws {
        let rig = Rig(requestTimeout: .milliseconds(200))
        rig.mouse.setActive(true)
        let fake = try await rig.connectedMouse(hapticConfig: Self.strength35)
        fake.script(MX4.writeStrength(35), replies: [])   // the restore's reply is lost

        rig.mouse.play(haptic: .sharpCollision, strength: 80)
        #expect(await eventually { fake.count(MX4.writeStrength(35)) == 1 })
        try await Task.sleep(for: .milliseconds(300))      // the restore timed out
        fake.script(MX4.writeStrength(35), replies: [MX4.strengthWritten(35)])

        rig.mouse.setActive(false)

        #expect(await eventually { fake.count(MX4.writeStrength(35)) == 2 })
    }

    @Test func deactivationAfterARestoredBlockWritesNothing() async throws {
        let rig = Rig()
        rig.mouse.setActive(true)
        let fake = try await rig.connectedMouse(hapticConfig: Self.strength35)
        rig.mouse.play(haptic: .sharpCollision, strength: 80)
        #expect(await eventually { fake.count(MX4.writeStrength(35)) == 1 })
        await settle()

        rig.mouse.setActive(false)
        await settle()
        rig.mouse.releaseAllSync()

        #expect(fake.count(MX4.writeStrength(35)) == 1)
    }

    @Test func releaseAllSyncRestoresTheStrengthOfAnUnconfirmedBlock() async throws {
        let rig = Rig()
        rig.mouse.setActive(true)
        let fake = try await rig.connectedMouse(hapticConfig: Self.strength35)
        fake.script(MX4.writeStrength(35), replies: [])   // the restore is not confirmed yet

        rig.mouse.play(haptic: .sharpCollision, strength: 80)
        #expect(await eventually { fake.count(MX4.writeStrength(35)) == 1 })

        rig.mouse.releaseAllSync()

        #expect(fake.count(MX4.writeStrength(35)) == 2)   // no await in between
        #expect(fake.hapticCommands == [MX4.writeStrength(80), MX4.play(0x02), MX4.writeStrength(35),
                                        MX4.writeStrength(35)])
    }

    @Test func aBlockNotYetRunAtReleaseAllSyncWritesNothing() async throws {
        let rig = Rig()
        rig.mouse.setActive(true)
        let fake = try await rig.connectedMouse(hapticConfig: Self.strength35)
        rig.mouse.play(haptic: .sharpCollision, strength: 80)
        rig.mouse.releaseAllSync()
        await settle()
        #expect(fake.hapticCommands.isEmpty)
    }

    @Test func aLostReplyDoesNotDelayTheNextPlay() async throws {
        let rig = Rig()   // requests time out after 2 s
        rig.mouse.setActive(true)
        let fake = try await rig.connectedMouse(hapticConfig: Self.strength35)
        fake.script(MX4.writeStrength(80), replies: [])   // every strength reply is lost
        fake.script(MX4.writeStrength(35), replies: [])

        rig.mouse.play(haptic: .sharpCollision, strength: 80)
        #expect(await eventually(.milliseconds(300)) { fake.hapticCommands.count == 3 })
        rig.mouse.play(haptic: .subtleCollision)
        #expect(await eventually(.milliseconds(300)) { fake.hapticCommands.count == 4 })
        rig.mouse.play(haptic: .dampCollision, strength: 80)   // the same echoes again: no tombstone wait

        #expect(await eventually(.milliseconds(300)) { fake.hapticCommands.count == 7 })
        #expect(fake.hapticCommands == [MX4.writeStrength(80), MX4.play(0x02), MX4.writeStrength(35),
                                        MX4.play(0x04),
                                        MX4.writeStrength(80), MX4.play(0x03), MX4.writeStrength(35)])
    }

    @Test func aStrongPlayDuringAReSetupWaitsForIt() async throws {
        let rig = Rig()
        rig.mouse.setActive(true)
        let fake = try await rig.connectedMouse(hapticConfig: Self.strength35)
        fake.script(MX4.readHapticConfig, replies: [])     // the re-setup stalls on the haptic config
        fake.push(Fixtures.connectionUp)                     // a second "linked" while connected
        #expect(await eventually { fake.count(MX4.readHapticConfig) == 2 })

        rig.mouse.play(haptic: .sharpCollision, strength: 80)
        await settle()
        #expect(fake.hapticCommands.isEmpty)                 // held while setup runs

        fake.push(MX4.hapticConfig(strength: 35))
        #expect(await eventually { fake.hapticCommands.count == 3 })
        #expect(fake.hapticCommands == [MX4.writeStrength(80), MX4.play(0x02), MX4.writeStrength(35)])
        #expect(rig.mouse.hapticStrength == 35)
    }

    @Test func aPlainPlayDuringAReSetupGoesAndReplacesAHeldBlock() async throws {
        let rig = Rig()
        rig.mouse.setActive(true)
        let fake = try await rig.connectedMouse(hapticConfig: Self.strength35)
        fake.script(MX4.readHapticConfig, replies: [])
        fake.push(Fixtures.connectionUp)
        #expect(await eventually { fake.count(MX4.readHapticConfig) == 2 })

        rig.mouse.play(haptic: .sharpCollision, strength: 80)
        rig.mouse.play(haptic: .subtleCollision)

        #expect(await eventually { fake.plays.count == 1 })
        fake.push(MX4.hapticConfig(strength: 35))
        await settle()
        #expect(fake.hapticCommands == [MX4.play(0x04)])
    }

    @Test func aStrengthReadWhileARestoreWasOwedIsIgnored() async throws {
        let rig = Rig()
        rig.mouse.setActive(true)
        let fake = try await rig.connectedMouse(hapticConfig: Self.strength35)
        fake.script(MX4.writeStrength(35), replies: [])     // the restore is not confirmed yet
        rig.mouse.play(haptic: .sharpCollision, strength: 80)
        #expect(await eventually { fake.count(MX4.writeStrength(35)) == 1 })
        fake.script(MX4.readHapticConfig, replies: [])
        fake.push(Fixtures.connectionUp)                     // a re-setup begins while the restore is owed
        #expect(await eventually { fake.count(MX4.readHapticConfig) == 2 })

        fake.push(MX4.strengthWritten(35))                   // the restore is confirmed during setup …
        await settle()
        fake.push(MX4.hapticConfig(strength: 80))            // … but setup read the strong strength before it

        #expect(await eventually { rig.mouse.isConnected && fake.count(MX4.readHapticConfig) == 2 })
        await settle()
        #expect(rig.mouse.hapticStrength == 35)
        fake.script(MX4.writeStrength(35), replies: [MX4.strengthWritten(35)])
        rig.mouse.play(haptic: .dampCollision, strength: 80)
        #expect(await eventually { fake.hapticCommands.count == 6 })
        #expect(Array(fake.hapticCommands.suffix(3)) == [MX4.writeStrength(80), MX4.play(0x03), MX4.writeStrength(35)])
    }

    @Test func aDisconnectMidBlockRestoresTheNormalStrengthOnReconnect() async throws {
        let rig = Rig()
        rig.mouse.setActive(true)
        let fake = try await rig.connectedMouse(hapticConfig: Self.strength35)
        fake.script(MX4.writeStrength(35), replies: [])     // the restore is not confirmed …
        rig.mouse.play(haptic: .sharpCollision, strength: 80)
        #expect(await eventually { fake.count(MX4.writeStrength(35)) == 1 })

        fake.push(Fixtures.connectionLost)                   // … when the mouse goes
        #expect(await eventually { rig.events == [.connected, .disconnected] })
        // It comes back still strong. The old write's waiter takes the first reply, the new write the second.
        fake.script(MX4.readHapticConfig, replies: [MX4.hapticConfig(strength: 80)])
        fake.script(MX4.writeStrength(35), replies: [MX4.strengthWritten(35), MX4.strengthWritten(35)])
        fake.push(Fixtures.connectionUp)

        #expect(await eventually { rig.events == [.connected, .disconnected, .connected] })
        #expect(await eventually { fake.count(MX4.writeStrength(35)) == 2 })
        #expect(rig.mouse.hapticStrength == 35)
    }

    @Test func anOwedRestoreIsNotWrittenToTheNextBinding() async throws {
        let rig = Rig()
        rig.mouse.setActive(true)
        let first = try await rig.connectedMouse(hapticConfig: Self.strength35)
        first.script(MX4.writeStrength(35), replies: [])    // the restore is not confirmed …
        rig.mouse.play(haptic: .sharpCollision, strength: 80)
        #expect(await eventually { first.count(MX4.writeStrength(35)) == 1 })

        first.pushRemoved()                                  // … when the receiver goes
        #expect(await eventually { rig.events == [.connected, .disconnected] })
        let second = try await rig.connectedMouse(hapticConfig: MX4.hapticConfig(strength: 60))
        await settle()

        #expect(second.strengthWrites.isEmpty)
        #expect(rig.mouse.hapticStrength == 60)
    }


    @Test func aStrongPlayWhileInactiveIsDropped() async throws {
        let rig = Rig()
        let fake = try await rig.connectedMouse(hapticConfig: Self.strength35)
        rig.mouse.play(haptic: .sharpCollision, strength: 80)
        await settle()
        #expect(fake.hapticCommands.isEmpty)
    }

    @Test func theAppsStrengthIsWrittenAtConnectAndUsedForRestores() async throws {
        let rig = Rig()
        rig.mouse.setHapticStrength(50)
        rig.mouse.setActive(true)
        let fake = try await rig.connectedMouse(hapticConfig: Self.strength35)
        #expect(await eventually { fake.count(MX4.writeStrength(50)) == 1 })
        #expect(await eventually { rig.mouse.hapticStrength == 50 })

        rig.mouse.play(haptic: .sharpCollision, strength: 80)
        rig.mouse.play(haptic: .subtleCollision, strength: 50)   // equal to the normal: plain

        #expect(await eventually { fake.hapticCommands.count == 5 })
        await settle()
        #expect(fake.hapticCommands == [MX4.writeStrength(50), MX4.writeStrength(80), MX4.play(0x02),
                                        MX4.writeStrength(50), MX4.play(0x04)])
    }

    @Test func theAppsStrengthIsWrittenAgainAfterAReconnect() async throws {
        let rig = Rig()
        rig.mouse.setHapticStrength(50)
        let fake = try await rig.connectedMouse(hapticConfig: Self.strength35)   // inactive: written all the same
        #expect(await eventually { fake.count(MX4.writeStrength(50)) == 1 })

        fake.push(Fixtures.connectionLost)
        fake.push(Fixtures.connectionUp)

        #expect(await eventually { fake.count(MX4.writeStrength(50)) == 2 })
    }

    @Test func setHapticStrengthWhileConnectedWritesNowClampedTo100() async throws {
        let rig = Rig()
        let fake = try await rig.connectedMouse(hapticConfig: Self.strength35)
        rig.mouse.setHapticStrength(60)
        #expect(await eventually { fake.count(MX4.writeStrength(60)) == 1 && rig.mouse.hapticStrength == 60 })
        rig.mouse.setHapticStrength(250)
        #expect(await eventually { fake.count(MX4.writeStrength(100)) == 1 })
        #expect(fake.strengthWrites == [MX4.writeStrength(60), MX4.writeStrength(100)])
    }

    @Test func theStrengthIsNotWrittenWithHapticsSwitchedOff() async throws {
        let rig = Rig()
        rig.mouse.setHapticStrength(50)
        let fake = try await rig.connectedMouse(hapticConfig: bytes(0x11, 0x02, 0x0b, 0x1a, 0x00, 0x23))
        await settle()
        #expect(fake.strengthWrites.isEmpty)   // `01 NN` would switch them on
    }

    @Test func thePanelForceIsClampedAndWrittenAtConnectAndAfterAReconnect() async throws {
        let rig = Rig()
        rig.mouse.setPanelForce(1000)
        let fake = try await rig.connectedMouse()
        #expect(await eventually { fake.count(MX4.writeForce(3799)) == 1 })
        #expect(await eventually { rig.mouse.panelForce?.current == 3799 })

        fake.push(Fixtures.connectionLost)
        fake.push(Fixtures.connectionUp)

        #expect(await eventually { fake.count(MX4.writeForce(3799)) == 2 })
        #expect(fake.forceWrites == [MX4.writeForce(3799), MX4.writeForce(3799)])
    }

    @Test func setPanelForceWhileConnectedWritesNow() async throws {
        let rig = Rig()
        let fake = try await rig.connectedMouse()
        rig.mouse.setPanelForce(4000)
        #expect(await eventually { fake.count(MX4.writeForce(4000)) == 1 && rig.mouse.panelForce?.current == 4000 })
        rig.mouse.setPanelForce(9000)
        #expect(await eventually { fake.count(MX4.writeForce(6316)) == 1 })
    }

    @Test func aPanelForceThatIsNotChangeableIsNotWritten() async throws {
        let rig = Rig()
        rig.mouse.setPanelForce(4000)
        let fake = try await rig.connectedMouse(forceInfo: bytes(0x11, 0x02, 0x0c, 0x1a, 0x00, 0x00, 0x12, 0x8d,
                                                                 0x18, 0xac, 0x0e, 0xd7))
        #expect(rig.mouse.panelForce?.info.changeable == false)
        await settle()
        #expect(fake.forceWrites.isEmpty)
    }

    // MARK: - Re-setup of a connected mouse

    @Test func deactivationDuringARelinkedReSetupReleasesAfterIt() async throws {
        let rig = Rig()
        rig.mouse.setActive(true)
        let fake = try await rig.connectedMouse()
        rig.mouse.divert([.hapticPanel])
        #expect(await eventually { fake.count(MX4.divert(.hapticPanel)) == 1 })
        fake.script(MX4.readControlCount, replies: [])   // the re-setup waits on this read
        fake.push(Fixtures.connectionUp)                 // a second "linked" while connected (the mouse kept its diverts)
        #expect(await eventually { fake.count(MX4.readControlCount) == 2 })

        rig.mouse.setActive(false)
        await settle()
        #expect(fake.count(MX4.release(.hapticPanel)) == 0)   // nothing is written during setup
        fake.push(MX4.controlCountReply)                       // the re-setup goes on

        // Sent, and its reply in: until then the control still counts as diverted, and releaseAllSync would (rightly)
        // send the release again.
        #expect(await eventually { fake.count(MX4.release(.hapticPanel)) == 1 && rig.mouse.divertedInMouse.isEmpty })
        rig.mouse.releaseAllSync()
        #expect(fake.count(MX4.release(.hapticPanel)) == 1)   // released once: nothing left to release at exit
    }

    @Test func aStateChangeDuringAFailedReSetupIsWrittenAfterIt() async throws {
        let rig = Rig()
        rig.mouse.setActive(true)
        let fake = try await rig.connectedMouse()
        rig.mouse.divert([.hapticPanel])
        rig.clock.advance(by: .seconds(1))   // the re-apply after the first setup
        #expect(await eventually { fake.count(MX4.divert(.hapticPanel)) == 2 })
        await settle()
        fake.script(MX4.readControlCount, replies: [bytes(0x11, MX4.device, 0xff, MX4.reprog, 0x0a, 0x05)])
        fake.push(Fixtures.connectionUp)
        #expect(await eventually { fake.count(MX4.readControlCount) == 2 && rig.clock.sleeperCount == 1 })

        rig.mouse.divert([.hapticPanel, .gesture])   // during the attempts: not written yet
        rig.clock.advance(by: .seconds(5))
        #expect(await eventually { fake.count(MX4.readControlCount) == 3 && rig.clock.sleeperCount == 1 })
        #expect(fake.count(MX4.divert(.gesture)) == 0)
        rig.clock.advance(by: .seconds(5))

        // The last attempt failed: the change is written, and once more 300 ms later.
        #expect(await eventually { fake.count(MX4.divert(.gesture)) == 1 && fake.count(MX4.divert(.hapticPanel)) == 3 })
        #expect(fake.count(MX4.readControlCount) == 4)
        rig.clock.advance(by: .milliseconds(300))
        #expect(await eventually { fake.count(MX4.divert(.gesture)) == 2 && fake.count(MX4.divert(.hapticPanel)) == 4 })
    }

    @Test func aKeyboardFallbackIsNeverDiverted() async throws {
        let rig = Rig()
        rig.mouse.divert([.gesture])
        rig.mouse.setActive(true)
        let fake = FakeTransport()
        MX4.script(fake)
        Keyboard.script(fake)
        fake.script(MX4.ping(MX4.device), replies: [MX4.emptySlot(MX4.device)])   // the mouse is off
        fake.script(Keyboard.readControlCount, replies: [bytes(0x11, Keyboard.slot, Keyboard.reprog, 0x0a, 0x01)])
        fake.script([0x10, Keyboard.slot, Keyboard.reprog, 0x1a, 0x00, 0x00, 0x00],
                    replies: [bytes(0x11, Keyboard.slot, Keyboard.reprog, 0x1a, 0x00, 0xc3, 0x00, 0x00, 0x31)])
        fake.script([0x10, Keyboard.slot, Keyboard.reprog, 0x3a, 0x00, 0xc3, 0x02],
                    replies: [bytes(0x11, Keyboard.slot, Keyboard.reprog, 0x3a, 0x00, 0xc3, 0x02)])

        rig.plug(fake)
        #expect(await eventually { rig.events == [.connected] })
        #expect(rig.mouse.controls == [Control(cid: .gesture, divertable: true)])
        rig.clock.advance(by: .seconds(1))
        await settle()

        #expect(!fake.sent.contains { $0.deviceIndex == Keyboard.slot && $0.function == 3 && $0.params[2] == 0x03 })
    }

    // MARK: - Receiver notifications

    @Test func aClearWirelessNotificationFlagIsSetKeepingTheOthers() async throws {
        let rig = Rig()
        let fake = FakeTransport()
        MX4.script(fake)
        fake.script(MX4.readNotificationFlags, replies: [MX4.notificationFlags([0x08, 0x00, 0x09])])
        fake.script(MX4.writeNotificationFlags([0x08, 0x01, 0x09]), replies: [MX4.notificationFlagsWritten])

        rig.plug(fake)

        #expect(await eventually { rig.events == [.connected] })
        #expect(await eventually { fake.count(MX4.writeNotificationFlags([0x08, 0x01, 0x09])) == 1 })
        #expect(fake.sent.filter { $0.featureIndex == 0x80 }.count == 1)
    }

    @Test func aSetWirelessNotificationFlagIsLeftAlone() async throws {
        let rig = Rig()
        let fake = try await rig.connectedMouse()   // the script's flags have the wireless bit set
        await settle()
        #expect(fake.count(MX4.readNotificationFlags) == 1)
        #expect(fake.sent.filter { $0.featureIndex == 0x80 }.isEmpty)
    }

    @Test func anUnreadableNotificationFlagIsNotFatal() async throws {
        let rig = Rig()
        let fake = FakeTransport()
        MX4.script(fake)
        fake.script(MX4.readNotificationFlags, replies: [[0x10, 0xff, 0x8f, 0x81, 0x00, 0x02, 0x00]])

        rig.plug(fake)

        #expect(await eventually { rig.events == [.connected] })
        await settle()
        #expect(fake.count(MX4.readNotificationFlags) == 1)
        #expect(fake.sent.filter { $0.featureIndex == 0x80 }.isEmpty)
    }

    @Test func systemDidWakeChecksTheFlagAgainAndReapplies() async throws {
        let rig = Rig()
        rig.mouse.setActive(true)
        let fake = try await rig.connectedMouse()
        rig.mouse.divert([.hapticPanel])
        rig.clock.advance(by: .seconds(1))   // the re-apply after setup
        #expect(await eventually { fake.count(MX4.divert(.hapticPanel)) == 2 })
        await settle()

        rig.mouse.systemDidWake()

        #expect(await eventually { fake.count(MX4.readNotificationFlags) == 2 && fake.count(MX4.divert(.hapticPanel)) == 3 })
        rig.clock.advance(by: .milliseconds(300))
        #expect(await eventually { fake.count(MX4.divert(.hapticPanel)) == 4 })
    }

    // MARK: - Precision Scroll (0x2121)

    @Test func hiResTurnsOnWhileActiveAndWanted() async throws {
        let rig = Rig()
        let fake = try await rig.connectedMouse()
        #expect(rig.mouse.isHighResolution == false)

        rig.mouse.wantHighResolutionWheel(true)
        await settle()
        #expect(fake.hiResWrites.isEmpty)                    // inactive: nothing written

        rig.mouse.setActive(true)

        #expect(await eventually { rig.mouse.isHighResolution })
        #expect(fake.hiResWrites == [0x02])
        #expect(await eventually { rig.events == [.connected, .highResolutionWheel(true)] })
        #expect(rig.marker.isSet)
        rig.clock.advance(by: .milliseconds(300))            // the re-apply: the mode is already on
        await settle()
        #expect(fake.hiResWrites == [0x02])
    }

    @Test func hiResOffOnDeactivation() async throws {
        let rig = Rig()
        rig.mouse.wantHighResolutionWheel(true)
        rig.mouse.setActive(true)
        let fake = try await rig.connectedMouse()
        #expect(await eventually { rig.mouse.isHighResolution })

        rig.mouse.setActive(false)

        #expect(await eventually { rig.mouse.isHighResolution == false })
        #expect(fake.hiResWrites == [0x02, 0x00])
        #expect(await eventually {
            rig.events == [.connected, .highResolutionWheel(true), .highResolutionWheel(false)]
        })
        #expect(rig.marker.isSet == false)
    }

    @Test func onlyTheHiResBitIsWritten() async throws {
        let rig = Rig()
        rig.mouse.wantHighResolutionWheel(true)
        rig.mouse.setActive(true)
        let fake = try await rig.connectedMouse(hiResMode: 0x01)   // divert bit set by someone else
        #expect(await eventually { fake.hiResWrites == [0x03] })

        rig.mouse.setActive(false)

        #expect(await eventually { fake.hiResWrites == [0x03, 0x01] })
    }

    @Test func usersOwnHiResIsNeverWritten() async throws {
        let rig = Rig()
        let fake = try await rig.connectedMouse(hiResMode: 0x02)   // e.g. LinearMouse, for the whole system
        #expect(rig.mouse.isHighResolution)
        #expect(await eventually { rig.events == [.connected, .highResolutionWheel(true)] })

        rig.mouse.wantHighResolutionWheel(true)
        rig.mouse.setActive(true)
        rig.clock.advance(by: .milliseconds(300))
        await settle()
        rig.mouse.wantHighResolutionWheel(false)
        await settle()
        rig.mouse.wantHighResolutionWheel(true)
        rig.mouse.setActive(false)
        await settle()
        rig.mouse.setActive(true)
        await settle()
        rig.mouse.releaseAllSync()

        #expect(fake.hiResWrites.isEmpty)
        #expect(rig.mouse.isHighResolution)
        #expect(rig.marker.isSet == false)
    }

    @Test func leftoverOfACrashIsTurnedOff() async throws {
        let rig = Rig(hiResMarker: MemoryHiResMarker(true))   // an earlier run turned it on and did not give it back
        let fake = try await rig.connectedMouse(hiResMode: 0x06)

        #expect(await eventually { fake.hiResWrites == [0x04] })   // only the hi-res bit: invert stays
        #expect(await eventually { rig.marker.isSet == false })
        #expect(rig.mouse.isHighResolution == false)
        #expect(await eventually {
            rig.events == [.connected, .highResolutionWheel(true), .highResolutionWheel(false)]
        })
    }

    @Test func aMarkerWithTheModeAlreadyOffIsClearedWithoutAWrite() async throws {
        let rig = Rig(hiResMarker: MemoryHiResMarker(true))   // the mouse slept since: it lost the mode
        let fake = try await rig.connectedMouse()
        await settle()
        #expect(fake.hiResWrites.isEmpty)
        #expect(rig.marker.isSet == false)
    }

    @Test func aMarkedWheelFoundOnStaysOnWhileWantedAndIsGivenBackAfter() async throws {
        let rig = Rig(hiResMarker: MemoryHiResMarker(true))
        rig.mouse.wantHighResolutionWheel(true)
        rig.mouse.setActive(true)
        let fake = try await rig.connectedMouse(hiResMode: 0x02)   // ours from an earlier run, not the user's
        rig.clock.advance(by: .milliseconds(300))
        await settle()
        #expect(fake.hiResWrites.isEmpty)
        #expect(rig.mouse.isHighResolution)

        rig.mouse.setActive(false)

        #expect(await eventually { fake.hiResWrites == [0x00] })
        #expect(await eventually { rig.marker.isSet == false })
    }

    @Test func failedRestoreIsRetried() async throws {
        let rig = Rig()
        rig.mouse.wantHighResolutionWheel(true)
        rig.mouse.setActive(true)
        let fake = try await rig.connectedMouse()
        #expect(await eventually { rig.mouse.isHighResolution })
        rig.clock.advance(by: .milliseconds(300))            // the re-apply is done
        await settle()
        fake.script(MX4.setHiResMode(0x00), replies: [MX4.setHiResModeError])

        rig.mouse.setActive(false)
        #expect(await eventually { fake.hiResWrites == [0x02, 0x00] && rig.clock.sleeperCount == 1 })
        #expect(rig.marker.isSet)

        rig.clock.advance(by: .milliseconds(999))
        await settle()
        #expect(fake.hiResWrites == [0x02, 0x00])
        rig.clock.advance(by: .milliseconds(1))
        #expect(await eventually { fake.hiResWrites == [0x02, 0x00, 0x00] && rig.clock.sleeperCount == 1 })
        #expect(rig.marker.isSet)
        #expect(rig.mouse.isHighResolution)

        fake.script(MX4.setHiResMode(0x00), replies: [MX4.hiResModeSet(0x00)])
        rig.clock.advance(by: .seconds(1))

        #expect(await eventually { rig.marker.isSet == false })
        #expect(fake.hiResWrites == [0x02, 0x00, 0x00, 0x00])
        #expect(rig.mouse.isHighResolution == false)
        rig.clock.advance(by: .seconds(5))
        await settle()
        #expect(fake.hiResWrites.count == 4)                  // given back: no more retries
    }

    @Test func aRetryStopsWhenTheModeIsWantedAgain() async throws {
        let rig = Rig()
        rig.mouse.wantHighResolutionWheel(true)
        rig.mouse.setActive(true)
        let fake = try await rig.connectedMouse()
        #expect(await eventually { rig.mouse.isHighResolution })
        fake.script(MX4.setHiResMode(0x00), replies: [MX4.setHiResModeError])
        rig.mouse.wantHighResolutionWheel(false)
        #expect(await eventually { fake.hiResWrites == [0x02, 0x00] })

        rig.mouse.wantHighResolutionWheel(true)              // the mode is still on in the mouse: nothing to write
        rig.clock.advance(by: .seconds(3))
        await settle()

        #expect(fake.hiResWrites == [0x02, 0x00])
        #expect(rig.mouse.isHighResolution)
        #expect(rig.marker.isSet)
    }

    /// High resolution wanted and turned on, then the reply to the off-write of `wantHighResolutionWheel(false)` is
    /// lost: the write times out (100 ms) and the hi-res wheel rests for 5 s on the test clock (from t = 0.3 s).
    private func lostOffWrite(_ rig: Rig) async throws -> FakeTransport {
        rig.mouse.wantHighResolutionWheel(true)
        rig.mouse.setActive(true)
        let fake = try await rig.connectedMouse()
        #expect(await eventually { rig.mouse.isHighResolution })
        rig.clock.advance(by: .milliseconds(300))            // the re-apply is done
        await settle()
        fake.script(MX4.setHiResMode(0x00), replies: [])     // the mouse does not answer
        rig.mouse.wantHighResolutionWheel(false)
        #expect(await eventually { fake.hiResWrites == [0x02, 0x00] })
        try await Task.sleep(for: .milliseconds(200))        // timed out: its tombstone would take the next reply
        return fake
    }

    @Test func aTimedOutWriteRestsThenReadsTheRealModeAndWritesWhatItNeeds() async throws {
        let rig = Rig(requestTimeout: .milliseconds(100))
        let fake = try await lostOffWrite(rig)

        // Inside the rest: the wish toggles (FrameScrub's pointer), other writes start passes, a recheck is asked for.
        for on in [true, false, true, false, true] {
            rig.mouse.wantHighResolutionWheel(on)
            rig.mouse.divert(on ? [.hapticPanel] : [])
            await settle()
        }
        rig.mouse.recheckHighResolutionWheel()
        rig.clock.advance(by: .seconds(4))
        await settle()
        #expect(fake.hiResWrites == [0x02, 0x00])            // no setMode during the rest
        #expect(fake.count(MX4.readHiResMode) == 1)          // nor a read: only the setup's
        #expect(fake.count(MX4.divert(.hapticPanel)) == 3)   // the other writes went on
        #expect(rig.mouse.isHighResolution)                  // the last known mode

        fake.push(MX4.hiResModeSet(0x00))                    // the off-write did get through: its reply comes late
        rig.clock.advance(by: .seconds(1))                   // the rest ends: read the real mode, then act on it

        #expect(await eventually { fake.hiResWrites == [0x02, 0x00, 0x02] })
        #expect(fake.count(MX4.readHiResMode) == 2)
        #expect(fake.lastIndex(MX4.readHiResMode)! < fake.lastIndex(MX4.setHiResMode(0x02))!)
        #expect(await eventually { rig.mouse.isHighResolution })
        #expect(await eventually {
            Array(rig.events.suffix(2)) == [.highResolutionWheel(false), .highResolutionWheel(true)]
        })
        #expect(rig.marker.isSet)
    }

    @Test func aTimedOutRestoreWhoseModeReadsBackOffIsGivenBackWithoutAWrite() async throws {
        let rig = Rig(requestTimeout: .milliseconds(100))
        let fake = try await lostOffWrite(rig)
        rig.mouse.setActive(false)                           // a pass inside the rest
        rig.clock.advance(by: .seconds(1))                   // no 1 s retry after a timeout
        await settle()
        #expect(fake.hiResWrites == [0x02, 0x00])
        #expect(rig.marker.isSet)
        #expect(rig.mouse.isHighResolution)

        rig.clock.advance(by: .seconds(4))                   // the rest ends; the read comes also while inactive

        #expect(await eventually { fake.count(MX4.readHiResMode) == 2 })
        #expect(await eventually { rig.marker.isSet == false && rig.mouse.isHighResolution == false })
        await settle()
        #expect(fake.hiResWrites == [0x02, 0x00])            // the mode is off already: nothing to write
    }

    @Test func aTimedOutOnWriteRestsToo() async throws {
        let rig = Rig(requestTimeout: .milliseconds(100))
        rig.mouse.setActive(true)
        let fake = try await rig.connectedMouse()
        fake.script(MX4.setHiResMode(0x02), replies: [])     // the mouse does not answer
        rig.mouse.wantHighResolutionWheel(true)
        #expect(await eventually { fake.hiResWrites == [0x02] })
        try await Task.sleep(for: .milliseconds(200))        // timed out at t = 0: the rest lasts until t = 5 s

        rig.clock.advance(by: .milliseconds(300))            // the re-apply, inside the rest
        rig.mouse.wantHighResolutionWheel(false)
        rig.mouse.wantHighResolutionWheel(true)
        await settle()
        #expect(fake.hiResWrites == [0x02])
        #expect(rig.mouse.isHighResolution == false)

        fake.script(MX4.readHiResMode, replies: [MX4.hiResMode(0x02)])   // it did get through
        rig.clock.advance(by: .seconds(5))

        #expect(await eventually { fake.count(MX4.readHiResMode) == 2 && rig.mouse.isHighResolution })
        await settle()
        #expect(fake.hiResWrites == [0x02])                  // on already: nothing more to write
        #expect(rig.marker.isSet)                            // ours: given back on deactivation
    }

    @Test func aTimedOutSetupReadRestsThenReadsAndWritesTheWantedMode() async throws {
        let rig = Rig(requestTimeout: .milliseconds(100))
        rig.mouse.wantHighResolutionWheel(true)
        rig.mouse.setActive(true)
        let fake = FakeTransport()
        MX4.script(fake)
        fake.script(MX4.readHiResMode, replies: [])          // the mouse does not answer the setup's read
        rig.plug(fake)
        try #require(await eventually { rig.count(.connected) == 1 })

        rig.mouse.recheckHighResolutionWheel()               // inside the rest: no read
        rig.clock.advance(by: .milliseconds(300))            // the re-apply, inside the rest
        await settle()
        #expect(fake.hiResWrites.isEmpty)                    // the mode is unknown: nothing written
        #expect(fake.count(MX4.readHiResMode) == 1)
        #expect(rig.mouse.isHighResolution == false)

        fake.push(MX4.hiResMode(0x00))                       // the setup's reply comes late: its tombstone takes it
        fake.script(MX4.readHiResMode, replies: [MX4.hiResMode(0x00)])
        rig.clock.advance(by: .seconds(5))                   // the rest ends: read the mode, then write the wanted one

        #expect(await eventually { fake.hiResWrites == [0x02] })
        #expect(fake.count(MX4.readHiResMode) == 2)
        #expect(fake.lastIndex(MX4.readHiResMode)! < fake.lastIndex(MX4.setHiResMode(0x02))!)
        #expect(await eventually { rig.mouse.isHighResolution })
        #expect(rig.marker.isSet)
    }

    @Test func aFailedSetupReadIsRetriedAndAMarkedLeftoverTurnedOff() async throws {
        let rig = Rig(hiResMarker: MemoryHiResMarker(true))   // an earlier run turned it on and did not give it back
        let fake = FakeTransport()
        MX4.script(fake)
        fake.script(MX4.readHiResMode, replies: [])
        rig.plug(fake)
        try #require(await eventually { fake.count(MX4.readHiResMode) == 1 })
        fake.script(MX4.readHiResMode, replies: [MX4.hiResMode(0x02)])
        fake.push(MX4.readHiResModeError)                    // the setup's read is refused (busy)

        #expect(await eventually { fake.hiResWrites == [0x00] })   // read again, then the leftover turned off
        #expect(fake.count(MX4.readHiResMode) == 2)
        #expect(fake.lastIndex(MX4.readHiResMode)! < fake.lastIndex(MX4.setHiResMode(0x00))!)
        #expect(await eventually { rig.marker.isSet == false })
        #expect(rig.mouse.isHighResolution == false)
        #expect(rig.events.first == .connected)
    }

    @Test func aFailedSetupReadLeavesTheWheelToRecheck() async throws {
        let rig = Rig()
        let fake = FakeTransport()
        MX4.script(fake)
        fake.script(MX4.readHiResMode, replies: [MX4.readHiResModeError])   // refused at setup and right after
        rig.plug(fake)
        try #require(await eventually { rig.count(.connected) == 1 })
        #expect(await eventually { fake.count(MX4.readHiResMode) == 2 })
        await settle()
        #expect(fake.count(MX4.readHiResMode) == 2)          // no retry loop

        fake.script(MX4.readHiResMode, replies: [MX4.hiResMode(0x00)])
        rig.mouse.wantHighResolutionWheel(true)
        rig.mouse.setActive(true)
        rig.mouse.recheckHighResolutionWheel()               // Precision Scroll still works on this connection

        #expect(await eventually { fake.hiResWrites == [0x02] })
        #expect(fake.lastIndex(MX4.readHiResMode)! < fake.lastIndex(MX4.setHiResMode(0x02))!)
        #expect(await eventually { rig.mouse.isHighResolution })
    }

    @Test func releaseAllSyncTurnsItOff() async throws {
        let rig = Rig()
        rig.mouse.divert([.hapticPanel])
        rig.mouse.wantHighResolutionWheel(true)
        rig.mouse.setActive(true)
        let fake = try await rig.connectedMouse(hiResMode: 0x01)
        #expect(await eventually { rig.mouse.isHighResolution && fake.count(MX4.divert(.hapticPanel)) == 1 })

        rig.mouse.releaseAllSync()

        #expect(fake.hiResWrites == [0x03, 0x01])            // no await in between
        #expect(fake.lastIndex(MX4.setHiResMode(0x01))! > fake.lastIndex(MX4.release(.hapticPanel))!)
        #expect(rig.marker.isSet)                            // not confirmed: the next start reads the mode again
        let sent = fake.sent.count
        rig.clock.advance(by: .seconds(5))
        await settle()
        #expect(fake.sent.count == sent)
    }

    @Test func releaseAllTurnsItOffAndClearsTheWish() async throws {
        let rig = Rig()
        rig.mouse.wantHighResolutionWheel(true)
        rig.mouse.setActive(true)
        let fake = try await rig.connectedMouse()
        #expect(await eventually { rig.mouse.isHighResolution })

        rig.mouse.releaseAll()

        #expect(await eventually { fake.hiResWrites == [0x02, 0x00] && rig.marker.isSet == false })
        rig.clock.advance(by: .seconds(1))
        await settle()
        #expect(fake.hiResWrites == [0x02, 0x00])
    }

    @Test func reconnectAppliesAgain() async throws {
        let rig = Rig()
        rig.mouse.wantHighResolutionWheel(true)
        rig.mouse.setActive(true)
        let fake = try await rig.connectedMouse()
        #expect(await eventually { rig.mouse.isHighResolution })
        rig.clock.advance(by: .milliseconds(300))
        await settle()

        fake.push(Fixtures.connectionLost)
        #expect(await eventually { rig.events.last == .disconnected })
        #expect(rig.mouse.isHighResolution == false)
        fake.push(Fixtures.connectionUp)                     // it comes back in its default mode

        #expect(await eventually { fake.hiResWrites == [0x02, 0x02] })
        #expect(fake.count(MX4.readHiResMode) == 2)
        #expect(await eventually { rig.mouse.isHighResolution })
        #expect(await eventually {
            rig.events == [.connected, .highResolutionWheel(true), .highResolutionWheel(false), .disconnected,
                           .connected, .highResolutionWheel(true)]
        })
        #expect(rig.marker.isSet)
    }

    @Test func reconnectWhileInactiveWritesNothing() async throws {
        let rig = Rig()
        rig.mouse.wantHighResolutionWheel(true)
        let fake = try await rig.connectedMouse()
        fake.push(Fixtures.connectionLost)
        fake.push(Fixtures.connectionUp)
        #expect(await eventually { rig.events == [.connected, .disconnected, .connected] })
        await settle()
        #expect(fake.hiResWrites.isEmpty)
    }

    @Test func recheckFixesADriftedMode() async throws {
        let rig = Rig()
        rig.mouse.wantHighResolutionWheel(true)
        rig.mouse.setActive(true)
        let fake = try await rig.connectedMouse()
        #expect(await eventually { fake.hiResWrites == [0x02] })
        rig.clock.advance(by: .milliseconds(300))
        await settle()

        fake.script(MX4.readHiResMode, replies: [MX4.hiResMode(0x02)])
        rig.mouse.recheckHighResolutionWheel()               // still on: nothing to write
        #expect(await eventually { fake.count(MX4.readHiResMode) == 2 })
        await settle()
        #expect(fake.hiResWrites == [0x02])

        fake.script(MX4.readHiResMode, replies: [MX4.hiResMode(0x00)])   // BetterMouse rewrote it
        rig.mouse.recheckHighResolutionWheel()

        #expect(await eventually { fake.hiResWrites == [0x02, 0x02] })
        #expect(fake.count(MX4.readHiResMode) == 3)
        #expect(rig.mouse.isHighResolution)
        #expect(rig.marker.isSet)
    }

    @Test func aRecheckRightAfterATimedOutReadIsSkipped() async throws {
        let rig = Rig(requestTimeout: .milliseconds(100))
        rig.mouse.setActive(true)
        let fake = try await rig.connectedMouse()
        fake.script(MX4.readHiResMode, replies: [])          // the mouse does not answer
        rig.mouse.recheckHighResolutionWheel()
        #expect(await eventually { fake.count(MX4.readHiResMode) == 2 })
        try await Task.sleep(for: .milliseconds(200))        // timed out: its tombstone would take the next reply

        rig.mouse.recheckHighResolutionWheel()
        rig.clock.advance(by: .seconds(4))
        await settle()
        #expect(fake.count(MX4.readHiResMode) == 2)

        fake.push(MX4.hiResMode(0x00))                       // the lost read's late reply: taken by its tombstone
        fake.script(MX4.readHiResMode, replies: [MX4.hiResMode(0x00)])
        rig.clock.advance(by: .seconds(1))                   // the rest ends with a read

        #expect(await eventually { fake.count(MX4.readHiResMode) == 3 })
    }

    @Test func recheckWhileInactiveDoesNothing() async throws {
        let rig = Rig()
        let fake = try await rig.connectedMouse()
        rig.mouse.recheckHighResolutionWheel()
        await settle()
        #expect(fake.count(MX4.readHiResMode) == 1)          // the setup's read only
    }

    @Test func aWheelThatLostTheUsersModeAndWasTurnedOnByUsIsGivenBack() async throws {
        let rig = Rig()
        rig.mouse.wantHighResolutionWheel(true)
        rig.mouse.setActive(true)
        let fake = try await rig.connectedMouse(hiResMode: 0x02)   // the user's own
        rig.clock.advance(by: .milliseconds(300))
        await settle()
        #expect(fake.hiResWrites.isEmpty)

        fake.script(MX4.readHiResMode, replies: [MX4.hiResMode(0x00)])   // the user's tool switched it off
        rig.mouse.recheckHighResolutionWheel()
        #expect(await eventually { fake.hiResWrites == [0x02] })   // turned on by us now: ours

        rig.mouse.setActive(false)

        #expect(await eventually { fake.hiResWrites == [0x02, 0x00] })
        #expect(rig.marker.isSet == false)
    }

    @Test func noHiResFeatureNoWrites() async throws {
        let rig = Rig(hiResMarker: MemoryHiResMarker(true))
        rig.mouse.wantHighResolutionWheel(true)
        rig.mouse.setActive(true)
        let fake = try await rig.connectedMouse(hiResMode: nil)
        rig.clock.advance(by: .milliseconds(300))
        rig.mouse.recheckHighResolutionWheel()
        await settle()
        rig.mouse.setActive(false)
        await settle()
        rig.mouse.releaseAllSync()

        #expect(fake.hiResWrites.isEmpty)
        #expect(fake.count(MX4.readHiResMode) == 0)
        #expect(rig.mouse.isHighResolution == false)
        #expect(await eventually { rig.events == [.connected] })
    }

    // MARK: - SmartShift (0x2111)

    @Test func wantedModeIsWrittenWhileActiveAndGivenBackOnDeactivation() async throws {
        let rig = Rig()
        let fake = try await rig.connectedMouse(smartShiftMode: 0x02)
        #expect(rig.mouse.wheelMode == .ratchet)

        rig.mouse.wantWheelMode(.freeSpin)
        await settle()
        #expect(fake.wheelModeWrites.isEmpty)                // inactive: nothing written

        rig.mouse.setActive(true)

        #expect(await eventually { rig.mouse.wheelMode == .freeSpin })
        #expect(fake.wheelModeWrites == [0x01])
        #expect(rig.wheelModeMarker.saved == .ratchet)       // the mouse's own, saved before the write
        #expect(await eventually {
            rig.events == [.connected, .wheelMode(.ratchet, byButton: false), .wheelMode(.freeSpin, byButton: false)]
        })
        rig.clock.advance(by: .milliseconds(300))            // the re-apply: the mode is already free spin
        await settle()
        #expect(fake.wheelModeWrites == [0x01])

        rig.mouse.setActive(false)

        #expect(await eventually { fake.wheelModeWrites == [0x01, 0x02] && rig.wheelModeMarker.saved == nil })
        #expect(rig.mouse.wheelMode == .ratchet)
        #expect(await eventually { rig.events.last == .wheelMode(.ratchet, byButton: false) })
    }

    @Test func theMousesOwnModeEqualToTheWantedOneIsNotWritten() async throws {
        let rig = Rig()
        let fake = try await rig.connectedMouse(smartShiftMode: 0x02)
        rig.mouse.wantWheelMode(.ratchet)
        rig.mouse.setActive(true)
        rig.clock.advance(by: .milliseconds(300))
        await settle()

        #expect(fake.wheelModeWrites.isEmpty)
        #expect(rig.wheelModeMarker.saved == nil)
        #expect(rig.mouse.wheelMode == .ratchet)
    }

    @Test func aMarkerFromACrashIsGivenBackWhileInactive() async throws {
        let rig = Rig(wheelModeMarker: MemoryWheelModeMarker(.ratchet))   // an earlier run wrote free spin
        let fake = try await rig.connectedMouse(smartShiftMode: 0x01)

        #expect(await eventually { fake.wheelModeWrites == [0x02] && rig.wheelModeMarker.saved == nil })
        #expect(rig.mouse.wheelMode == .ratchet)
    }

    @Test func aMarkerMatchingTheMouseIsClearedWithoutAWrite() async throws {
        let rig = Rig(wheelModeMarker: MemoryWheelModeMarker(.ratchet))   // the mouse is back in its own mode
        let fake = try await rig.connectedMouse(smartShiftMode: 0x02)

        #expect(await eventually { rig.wheelModeMarker.saved == nil })
        await settle()
        #expect(fake.wheelModeWrites.isEmpty)
    }

    @Test func reconnectReadsAndWritesTheWantedModeAgain() async throws {
        let rig = Rig()
        rig.mouse.wantWheelMode(.freeSpin)
        rig.mouse.setActive(true)
        let fake = try await rig.connectedMouse(smartShiftMode: 0x02)
        #expect(await eventually { fake.wheelModeWrites == [0x01] })
        rig.clock.advance(by: .milliseconds(300))
        await settle()

        fake.push(Fixtures.connectionLost)
        #expect(await eventually { rig.events.last == .disconnected })
        #expect(rig.mouse.wheelMode == nil)
        fake.push(Fixtures.connectionUp)                     // it comes back in ratchet (the read says 0x02)

        #expect(await eventually { fake.wheelModeWrites == [0x01, 0x01] })
        #expect(fake.count(MX4.readWheelMode) == 2)
        #expect(await eventually { rig.mouse.wheelMode == .freeSpin })
        #expect(await eventually {
            rig.events == [.connected, .wheelMode(.ratchet, byButton: false), .wheelMode(.freeSpin, byButton: false),
                           .disconnected,
                           .connected, .wheelMode(.ratchet, byButton: false), .wheelMode(.freeSpin, byButton: false)]
        })
        #expect(rig.wheelModeMarker.saved == .ratchet)
    }

    @Test func aTimedOutWriteRestsThenReadsAndWrites() async throws {
        let rig = Rig(requestTimeout: .milliseconds(100))
        rig.mouse.setActive(true)
        let fake = try await rig.connectedMouse(smartShiftMode: 0x02)
        fake.script(MX4.writeWheelMode(0x01), replies: [])   // the mouse does not answer
        rig.mouse.wantWheelMode(.freeSpin)
        #expect(await eventually { fake.wheelModeWrites == [0x01] })
        try await Task.sleep(for: .milliseconds(200))        // timed out at t = 0: the rest lasts until t = 5 s
        let requests = fake.smartShiftRequests

        // Inside the rest: the re-apply, the wish dropped (a give-back pass) and wanted again, a recheck.
        rig.clock.advance(by: .milliseconds(300))
        rig.mouse.wantWheelMode(nil)
        await settle()
        rig.mouse.wantWheelMode(.freeSpin)
        rig.mouse.recheckWheelMode()
        rig.clock.advance(by: .seconds(4))
        await settle()
        #expect(fake.smartShiftRequests == requests)         // no 0x2111 request during the rest
        #expect(rig.mouse.wheelMode == .ratchet)             // the last known mode
        #expect(rig.wheelModeMarker.saved == .ratchet)       // the write may have got through: still owed

        fake.push(MX4.writeWheelModeError)                   // the lost write's late refusal: its tombstone takes it
        fake.script(MX4.writeWheelMode(0x01), replies: [MX4.wheelModeWritten(0x01)])
        rig.clock.advance(by: .milliseconds(700))            // t = 5 s: the rest ends with a read (still 0x02)

        #expect(await eventually { fake.wheelModeWrites == [0x01, 0x01] })
        #expect(fake.count(MX4.readWheelMode) == 2)
        #expect(fake.lastIndex(MX4.readWheelMode)! < fake.lastIndex(MX4.writeWheelMode(0x01))!)
        #expect(await eventually { rig.mouse.wheelMode == .freeSpin })
        #expect(rig.wheelModeMarker.saved == .ratchet)
    }

    @Test func releaseAllSyncWritesTheSavedModeAndClearsTheMarker() async throws {
        let rig = Rig()
        rig.mouse.wantWheelMode(.freeSpin)
        rig.mouse.setActive(true)
        let fake = try await rig.connectedMouse(smartShiftMode: 0x02)
        #expect(await eventually { rig.mouse.wheelMode == .freeSpin })

        rig.mouse.releaseAllSync()

        #expect(fake.sent.last?.bytes == [0x10, 0x02, 0x11, 0x2a, 0x02, 0x00, 0x00])   // no await in between
        // Sent without a transport error: the next launch must not give a stale mode back over a later choice.
        #expect(rig.wheelModeMarker.saved == nil)
        let sent = fake.sent.count
        rig.clock.advance(by: .seconds(5))
        await settle()
        #expect(fake.sent.count == sent)
    }

    @Test func aGiveBackAtExitThatFailsToSendKeepsTheMarker() async throws {
        let rig = Rig()
        rig.mouse.wantWheelMode(.freeSpin)
        rig.mouse.setActive(true)
        let fake = try await rig.connectedMouse(smartShiftMode: 0x02)
        #expect(await eventually { rig.mouse.wheelMode == .freeSpin })
        fake.failSends(with: .disconnected)

        rig.mouse.releaseAllSync()

        #expect(rig.wheelModeMarker.saved == .ratchet)       // the next launch gives it back
    }

    @Test func activationReadsTheModeFirstSoAChoiceMadeElsewhereIsKept() async throws {
        let rig = Rig()
        rig.mouse.wantWheelMode(.freeSpin)
        rig.mouse.setActive(true)
        let fake = try await rig.connectedMouse(smartShiftMode: 0x02)   // the mouse's own: ratchet
        #expect(await eventually { fake.wheelModeWrites == [0x01] })
        rig.clock.advance(by: .milliseconds(300))
        await settle()
        rig.mouse.setActive(false)                           // ratchet given back
        #expect(await eventually { fake.wheelModeWrites == [0x01, 0x02] && rig.wheelModeMarker.saved == nil })
        // In another app the user presses SmartShift (not watched while inactive): free spin is the mouse's own now.
        fake.script(MX4.readWheelMode, replies: [MX4.wheelMode(0x01)])
        let reads = fake.count(MX4.readWheelMode)
        let hiResReads = fake.count(MX4.readHiResMode)
        rig.mouse.recheckWheelMode()                         // FrameScrub's edge recheck runs first: still inactive

        rig.mouse.setActive(true)

        #expect(await eventually { fake.count(MX4.readWheelMode) == reads + 1 && rig.mouse.wheelMode == .freeSpin })
        #expect(fake.count(MX4.readHiResMode) == hiResReads + 1)   // the hi-res mode is read again too
        rig.clock.advance(by: .milliseconds(300))
        await settle()
        #expect(fake.wheelModeWrites == [0x01, 0x02])        // already free spin: nothing written
        #expect(rig.wheelModeMarker.saved == nil)

        rig.mouse.setActive(false)
        await settle()

        #expect(fake.wheelModeWrites == [0x01, 0x02])        // the user's own free spin stays
        #expect(rig.mouse.wheelMode == .freeSpin)
    }

    @Test func aRefusedGiveBackIsRetriedEverySecond() async throws {
        let rig = Rig()
        rig.mouse.wantWheelMode(.freeSpin)
        rig.mouse.setActive(true)
        let fake = try await rig.connectedMouse(smartShiftMode: 0x02)
        #expect(await eventually { fake.wheelModeWrites == [0x01] })
        rig.clock.advance(by: .milliseconds(300))            // the re-apply is done
        await settle()
        fake.script(MX4.writeWheelMode(0x02), replies: [MX4.writeWheelModeError])

        rig.mouse.setActive(false)
        #expect(await eventually { fake.wheelModeWrites == [0x01, 0x02] && rig.clock.sleeperCount == 1 })
        #expect(rig.wheelModeMarker.saved == .ratchet)

        rig.clock.advance(by: .milliseconds(999))
        await settle()
        #expect(fake.wheelModeWrites == [0x01, 0x02])
        rig.clock.advance(by: .milliseconds(1))
        #expect(await eventually { fake.wheelModeWrites == [0x01, 0x02, 0x02] && rig.clock.sleeperCount == 1 })
        #expect(rig.wheelModeMarker.saved == .ratchet)
        #expect(rig.mouse.wheelMode == .freeSpin)

        fake.script(MX4.writeWheelMode(0x02), replies: [MX4.wheelModeWritten(0x02)])
        rig.clock.advance(by: .seconds(1))

        #expect(await eventually { rig.wheelModeMarker.saved == nil })
        #expect(fake.wheelModeWrites == [0x01, 0x02, 0x02, 0x02])
        #expect(rig.mouse.wheelMode == .ratchet)
        rig.clock.advance(by: .seconds(5))
        await settle()
        #expect(fake.wheelModeWrites.count == 4)             // given back: no more retries
    }

    @Test func noSmartShiftFeatureNoWrites() async throws {
        let rig = Rig(wheelModeMarker: MemoryWheelModeMarker(.ratchet))
        rig.mouse.wantWheelMode(.freeSpin)
        rig.mouse.setActive(true)
        let fake = try await rig.connectedMouse()
        rig.clock.advance(by: .milliseconds(300))
        rig.mouse.recheckWheelMode()
        await settle()
        rig.mouse.setActive(false)
        await settle()
        rig.mouse.releaseAllSync()

        #expect(fake.count(MX4.lookup(SmartShift.featureID)) == 1)
        #expect(fake.smartShiftRequests == 0)
        #expect(rig.mouse.wheelMode == nil)
        #expect(await eventually { rig.events == [.connected] })
    }

    // MARK: - SmartShift button

    @Test func aSmartShiftPressIsReadAndAdopted() async throws {
        let rig = Rig()
        rig.mouse.wantWheelMode(.freeSpin)
        rig.mouse.setActive(true)
        let fake = try await rig.connectedMouse(smartShiftMode: 0x02)
        #expect(await eventually { fake.wheelModeWrites == [0x01] && fake.count(MX4.watch(.smartShift)) == 1 })
        let reads = fake.count(MX4.readWheelMode)   // the read still replies 0x02: the press switches to ratchet

        fake.push(MX4.smartShiftKey(pressed: true))
        await settle()
        #expect(fake.count(MX4.readWheelMode) == reads)   // not on the press
        fake.push(MX4.smartShiftKey(pressed: false))

        #expect(await eventually { rig.events.last == .wheelMode(.ratchet, byButton: true) })
        #expect(fake.count(MX4.readWheelMode) == reads + 1)
        #expect(rig.mouse.wheelMode == .ratchet)
        rig.clock.advance(by: .milliseconds(300))            // the re-apply: ratchet is the wanted mode now
        await settle()
        #expect(fake.wheelModeWrites == [0x01])
        #expect(!rig.mouse.watching.contains(.smartShift))
        #expect(!rig.events.contains(.pressed(.smartShift, at: 0)))
        #expect(!rig.events.contains(.released(.smartShift, at: 0)))
        #expect(rig.events.filter { $0 == .wheelMode(.ratchet, byButton: false) }.count == 1)   // only the setup's
    }

    @Test func theSmartShiftWatchFollowsTheWantedMode() async throws {
        let rig = Rig()
        rig.mouse.setActive(true)
        let fake = try await rig.connectedMouse(smartShiftMode: 0x02)
        await settle()
        #expect(fake.count(MX4.watch(.smartShift)) == 0)   // nothing wanted: not watched
        let watchOn = bytes(0x11, MX4.device, MX4.reprog, 0x3a, 0x00, 0xc4, 0x00, 0x00, 0x00, 0x03)
        let watchOff = bytes(0x11, MX4.device, MX4.reprog, 0x3a, 0x00, 0xc4, 0x00, 0x00, 0x00, 0x02)

        rig.mouse.wantWheelMode(.freeSpin)
        #expect(await eventually { fake.count(watchOn) == 1 })
        rig.mouse.wantWheelMode(nil)
        #expect(await eventually { fake.count(watchOff) == 1 })

        rig.mouse.wantWheelMode(.freeSpin)
        #expect(await eventually { fake.count(watchOn) == 2 })
        rig.mouse.setActive(false)                           // switched off on deactivation
        #expect(await eventually { fake.count(watchOff) == 2 })

        rig.mouse.setActive(true)
        #expect(await eventually { fake.count(watchOn) == 3 })
        rig.mouse.releaseAllSync()                           // and at exit, before returning
        #expect(fake.count(watchOff) == 3)
        #expect(rig.mouse.watching.isEmpty)
    }

    @Test func aDivertedSmartShiftIsNotWatched() async throws {
        let rig = Rig()
        rig.mouse.divert([.smartShift])
        rig.mouse.wantWheelMode(.freeSpin)
        rig.mouse.setActive(true)
        let fake = try await rig.connectedMouse(smartShiftMode: 0x02)
        #expect(await eventually { fake.count(MX4.divert(.smartShift)) == 1 && fake.wheelModeWrites == [0x01] })
        rig.clock.advance(by: .milliseconds(300))
        #expect(await eventually { fake.count(MX4.divert(.smartShift)) == 2 })
        await settle()
        #expect(fake.count(MX4.watch(.smartShift)) == 0)
        let reads = fake.count(MX4.readWheelMode)

        fake.push(bytes(0x11, MX4.device, MX4.reprog, 0x00, 0x00, 0xc4))   // a diverted press
        fake.push(Fixtures.allReleased)

        #expect(await eventually {
            rig.events.suffix(2) == [.pressed(.smartShift, at: 0), .released(.smartShift, at: 0)]
        })
        await settle()
        #expect(fake.count(MX4.readWheelMode) == reads)

        rig.mouse.divert([])                                 // handed back: now it is watched
        #expect(await eventually { fake.count(MX4.watch(.smartShift)) == 1 })
    }

    @Test func aPressAdoptedWithoutAnyWriteIsGivenBackOnDeactivation() async throws {
        let rig = Rig()
        rig.mouse.wantWheelMode(.freeSpin)
        rig.mouse.setActive(true)
        let fake = try await rig.connectedMouse(smartShiftMode: 0x01)   // already free spin: nothing written
        #expect(await eventually { fake.count(MX4.watch(.smartShift)) == 1 })
        rig.clock.advance(by: .milliseconds(300))
        await settle()
        #expect(fake.wheelModeWrites.isEmpty)
        #expect(rig.wheelModeMarker.saved == nil)
        fake.script(MX4.readWheelMode, replies: [MX4.wheelMode(0x02)])   // the press switched to ratchet

        fake.push(MX4.smartShiftKey(pressed: true))
        fake.push(MX4.smartShiftKey(pressed: false))
        #expect(await eventually { rig.events.last == .wheelMode(.ratchet, byButton: true) })
        #expect(rig.wheelModeMarker.saved == .freeSpin)      // the mouse's own, saved before the adoption

        rig.mouse.setActive(false)

        #expect(await eventually { fake.wheelModeWrites == [0x01] && rig.wheelModeMarker.saved == nil })
        #expect(await eventually { rig.mouse.wheelMode == .freeSpin })
    }

    @Test func twoQuickPressesEndOnTheLastReadMode() async throws {
        let rig = Rig()
        rig.mouse.wantWheelMode(.freeSpin)
        rig.mouse.setActive(true)
        let fake = try await rig.connectedMouse(smartShiftMode: 0x02)
        #expect(await eventually { fake.wheelModeWrites == [0x01] })
        rig.clock.advance(by: .milliseconds(300))
        await settle()
        let reads = fake.count(MX4.readWheelMode)
        fake.script(MX4.readWheelMode, replies: [])         // the first read's reply comes later, by hand

        fake.push(MX4.smartShiftKey(pressed: true))
        fake.push(MX4.smartShiftKey(pressed: false))
        #expect(await eventually { fake.count(MX4.readWheelMode) == reads + 1 })
        fake.push(MX4.smartShiftKey(pressed: true))          // the second press while the first read is out
        fake.push(MX4.smartShiftKey(pressed: false))
        await settle()
        fake.script(MX4.readWheelMode, replies: [MX4.wheelMode(0x01)])   // the second read: free spin again
        fake.push(MX4.wheelMode(0x02))                       // the first read's reply: ratchet

        #expect(await eventually { rig.events.last == .wheelMode(.freeSpin, byButton: true) })
        #expect(fake.count(MX4.readWheelMode) == reads + 2)
        #expect(rig.events.suffix(2) == [.wheelMode(.ratchet, byButton: true), .wheelMode(.freeSpin, byButton: true)])
        await settle()
        #expect(fake.wheelModeWrites == [0x01])              // free spin adopted last: no write of ratchet back
        #expect(rig.mouse.wheelMode == .freeSpin)
    }

    @Test(arguments: [0x01, 0x02] as [UInt8])
    func aReadAfterDeactivationIsNotAdopted(read: UInt8) async throws {
        let rig = Rig()
        rig.mouse.wantWheelMode(.freeSpin)
        rig.mouse.setActive(true)
        let fake = try await rig.connectedMouse(smartShiftMode: 0x02)
        #expect(await eventually { fake.wheelModeWrites == [0x01] })
        rig.clock.advance(by: .milliseconds(300))
        await settle()
        let reads = fake.count(MX4.readWheelMode)
        fake.script(MX4.readWheelMode, replies: [])         // the reply comes later, by hand

        fake.push(MX4.smartShiftKey(pressed: false))
        #expect(await eventually { fake.count(MX4.readWheelMode) == reads + 1 })
        rig.mouse.setActive(false)
        fake.push(MX4.wheelMode(read))

        // Given back: written only if the read mode is not the saved one (ratchet).
        #expect(await eventually {
            rig.wheelModeMarker.saved == nil && rig.events.last == .wheelMode(.ratchet, byButton: false)
        })
        await settle()
        #expect(fake.wheelModeWrites == (read == 0x02 ? [0x01] : [0x01, 0x02]))
        #expect(!rig.events.contains { if case .wheelMode(_, byButton: true) = $0 { true } else { false } })
        #expect(await eventually { fake.count(MX4.unwatch(.smartShift)) == 1 })

        fake.script(MX4.readWheelMode, replies: [MX4.wheelMode(0x02)])
        rig.mouse.setActive(true)                            // free spin is still the wanted mode
        #expect(await eventually { fake.wheelModeWrites.last == 0x01 && rig.mouse.wheelMode == .freeSpin })
    }

    @Test func anAppWatchOfTheSmartShiftButtonKeepsItsEventsBesideTheRead() async throws {
        let rig = Rig()
        rig.mouse.watch([.smartShift])
        rig.mouse.wantWheelMode(.freeSpin)
        rig.mouse.setActive(true)
        let fake = try await rig.connectedMouse(smartShiftMode: 0x02)
        #expect(await eventually { rig.mouse.watching == [.smartShift] && fake.wheelModeWrites == [0x01] })

        fake.push(MX4.smartShiftKey(pressed: true), at: 1)
        fake.push(MX4.smartShiftKey(pressed: false), at: 2)

        #expect(await eventually {
            rig.timedEvents.suffix(3) == [.pressed(.smartShift, at: 1), .released(.smartShift, at: 2),
                                          .wheelMode(.ratchet, byButton: true)]
        })
        rig.mouse.wantWheelMode(nil)                         // the app's own watch stays on
        rig.clock.advance(by: .milliseconds(300))
        await settle()
        #expect(fake.count(MX4.unwatch(.smartShift)) == 1)   // the startup release only
        #expect(rig.mouse.watching == [.smartShift])
    }

    @Test func aRecheckWhileTheButtonIsDownAdoptsThePressAndWritesNothingBack() async throws {
        let rig = Rig()
        rig.mouse.wantWheelMode(.freeSpin)
        rig.mouse.setActive(true)
        let fake = try await rig.connectedMouse(smartShiftMode: 0x02)
        #expect(await eventually { fake.wheelModeWrites == [0x01] && fake.count(MX4.watch(.smartShift)) == 1 })
        rig.clock.advance(by: .milliseconds(300))
        await settle()
        let reads = fake.count(MX4.readWheelMode)   // the read still replies 0x02: the press switches to ratchet

        fake.push(MX4.smartShiftKey(pressed: true))
        await settle()
        rig.mouse.recheckWheelMode()                         // FrameScrub's 2 s recheck lands before the release
        #expect(await eventually { fake.count(MX4.readWheelMode) == reads + 1 })
        await settle()
        #expect(fake.wheelModeWrites == [0x01])              // free spin is not written back under the user's finger
        #expect(rig.events.last == .wheelMode(.ratchet, byButton: true))

        fake.push(MX4.smartShiftKey(pressed: false))
        #expect(await eventually { fake.count(MX4.readWheelMode) == reads + 2 })
        await settle()
        #expect(rig.events.last == .wheelMode(.ratchet, byButton: true))
        rig.mouse.recheckWheelMode()                         // a later recheck: ratchet is the wanted mode now
        #expect(await eventually { fake.count(MX4.readWheelMode) == reads + 3 })
        await settle()

        #expect(fake.wheelModeWrites == [0x01])
        #expect(rig.mouse.wheelMode == .ratchet)
        #expect(rig.wheelModeMarker.saved == .ratchet)       // the mouse's own, saved before the first write
    }

    @Test func aPressWithoutAReleaseIsReadAsAPressAfterOneSecond() async throws {
        let rig = Rig()
        rig.mouse.wantWheelMode(.freeSpin)
        rig.mouse.setActive(true)
        let fake = try await rig.connectedMouse(smartShiftMode: 0x02)
        #expect(await eventually { fake.wheelModeWrites == [0x01] && fake.count(MX4.watch(.smartShift)) == 1 })
        rig.clock.advance(by: .milliseconds(300))
        await settle()
        let reads = fake.count(MX4.readWheelMode)

        fake.push(MX4.smartShiftKey(pressed: true))          // its release is lost
        await settle()
        rig.clock.advance(by: .milliseconds(999))
        await settle()
        #expect(fake.count(MX4.readWheelMode) == reads)
        rig.clock.advance(by: .milliseconds(1))

        #expect(await eventually { rig.events.last == .wheelMode(.ratchet, byButton: true) })
        #expect(fake.count(MX4.readWheelMode) == reads + 1)
        await settle()
        #expect(fake.wheelModeWrites == [0x01])
        rig.mouse.recheckWheelMode()                         // no longer held: a recheck is an ordinary read again
        #expect(await eventually { fake.count(MX4.readWheelMode) == reads + 2 })
        await settle()
        #expect(fake.wheelModeWrites == [0x01])              // ratchet was adopted
    }

    // MARK: - Two processes on one receiver

    @Test func twoProcessesOnOneReceiverEachSetUpTheMouseWithTheirOwnReplies() async throws {
        let receiver = SharedReceiver()
        MX4.script(receiver)
        let a = Rig(softwareID: 0x0A)
        let b = Rig(softwareID: 0x0B)
        let aEnd = receiver.endpoint()
        let bEnd = receiver.endpoint()
        a.mouse.setActive(true)
        b.mouse.setActive(true)
        a.mouse.divert([.hapticPanel])
        b.mouse.divert([.gesture])

        a.plug(aEnd)
        b.plug(bEnd)

        #expect(await eventually { a.events == [.connected] && b.events == [.connected] })
        let expected = [Control(cid: .hapticPanel, divertable: true, watchable: true),
                        Control(cid: .gesture, divertable: true, watchable: true),
                        Control(cid: .left, divertable: false, watchable: true),
                        Control(cid: .back, divertable: true, watchable: true),
                        Control(cid: MX4.unwatchable, divertable: false, watchable: false),
                        Control(cid: .smartShift, divertable: true, watchable: true)]
        for rig in [a, b] {
            #expect(rig.mouse.controls == expected)
            #expect(rig.mouse.stepsPerRevolution == 120)
        }
        #expect(await eventually {
            aEnd.sent.contains { $0.bytes == MX4.divert(.hapticPanel) }
                && bEnd.sent.contains { $0.bytes == MX4.divert(.gesture).stampedB }
        })
        #expect(aEnd.sent.filter { $0.featureIndex < 0x80 }.allSatisfy { $0.softwareID == 0x0A })
        #expect(bEnd.sent.filter { $0.featureIndex < 0x80 }.allSatisfy { $0.softwareID == 0x0B })
    }
}
