import Foundation
import Testing
@testable import LogiHIDPP

/// Tests against the real mouse on a Bolt / Unifying receiver. Skipped unless `LOGI_HARDWARE=1`; run them with the mouse
/// switched on and nothing else diverting its buttons.
// Serialized: the tests share this process's software ID on one receiver, so in parallel they could take each other's
// replies (and a wrong feature index could turn a read into a write).
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["LOGI_HARDWARE"] == "1"))
struct HardwareTests {
    /// The receivers present now: arrivals within half a second.
    private func presentReceivers() async -> [IOKitTransport] {
        let collector = Task {
            var found: [IOKitTransport] = []
            for await transport in IOKitTransport.receivers() { found.append(transport) }
            return found
        }
        try? await Task.sleep(for: .milliseconds(500))
        collector.cancel()
        return await collector.value
    }

    /// A channel and slot of a device with REPROG_CONTROLS_V4 and haptics: the MX Master 4.
    private func findMouse() async -> (channel: HIDPPChannel, device: UInt8)? {
        for transport in await presentReceivers() {
            let channel = HIDPPChannel(transport: transport)
            for device in await channel.discover() {
                guard (try? await channel.featureIndex(ReprogControls.featureID, device: device)) != nil,
                      (try? await channel.featureIndex(Haptics.featureID, device: device)) != nil else { continue }
                return (channel, device)
            }
        }
        return nil
    }

    @Test func receiverAnswersPing() async throws {
        let receivers = await presentReceivers()
        try #require(!receivers.isEmpty, "no Logitech receiver found")
        let channel = HIDPPChannel(transport: receivers[0])
        let devices = await channel.discover()
        let device = try #require(devices.first, "no device answered a ping")
        let version = try await channel.ping(device: device)
        #expect(version.major >= 2)
    }

    @MainActor @Test func controlsContainTheHapticPanel() async throws {
        let mouse = LogiMouse()
        mouse.start()
        defer { mouse.releaseAllSync() }
        try await waitConnected(mouse)
        #expect(mouse.controls.contains { $0.cid == .hapticPanel })
    }

    /// Read-only: setup reads the haptic strength and the panel force. The test asks for neither setting, so nothing
    /// is written to the mouse.
    @MainActor @Test func hapticStrengthAndPanelForceAreRead() async throws {
        let mouse = LogiMouse()
        mouse.start()
        defer { mouse.releaseAllSync() }
        try await waitConnected(mouse)
        let strength = try #require(mouse.hapticStrength, "the haptic strength was not read")
        #expect((0...100).contains(strength))
        let force = try #require(mouse.panelForce, "the panel force was not read")
        #expect(force.info.range.contains(force.current))
        #expect(force.info.range.contains(force.info.defaultValue))
    }

    /// Read-only: the hi-res wheel mode (`0x2121` getMode) parses, and setup reports the same high-resolution bit.
    /// The test never wants high resolution, and its marker is in memory: nothing is written to the mouse.
    @MainActor @Test func hiResWheelModeIsRead() async throws {
        let (channel, device) = try #require(await findMouse(), "no mouse with 0x1B04 and haptics found")
        let reply = try await channel.call(HiResWheel.featureID, device: device, function: HiResWheel.getMode)
        let mode = try #require(reply.first, "empty getMode reply")
        #expect(mode & 0xF8 == 0, "unknown bits in the wheel mode \(mode)")

        let mouse = LogiMouse(softwareID: channel.softwareID == 0x0B ? 0x0C : 0x0B, hiResMarker: MemoryHiResMarker())
        mouse.start()
        defer { mouse.releaseAllSync() }
        try await waitConnected(mouse)
        #expect(mouse.isHighResolution == (mode & HiResWheel.highResolution != 0))
    }

    /// Diverts the haptic panel and releases it again with confirmed requests (the error would be thrown), then once
    /// more through `LogiMouse`, which logs errors instead of throwing; reads the panel's reporting back after the
    /// divert and after `releaseAllSync()`.
    @MainActor @Test func divertAndReleaseWithoutError() async throws {
        let (channel, device) = try #require(await findMouse(), "no mouse with 0x1B04 and haptics found")
        let feature = ReprogControls.featureID
        let release = ReprogControls.divertParams(.hapticPanel, divert: false)
        func send(_ params: [UInt8]) async throws {
            _ = try await channel.call(feature, device: device, function: 3, params: params, echo: Array(params.prefix(2)))
        }
        do {
            try await send(ReprogControls.divertParams(.hapticPanel, divert: true))
            try await send(release)
        } catch {
            try? await send(release)   // never leave the panel diverted
            throw error
        }

        // The mouse gets its own software ID: `channel` (this process's ID) reads the panel's reporting beside it.
        let mouse = LogiMouse(softwareID: channel.softwareID == 0x0B ? 0x0C : 0x0B)
        mouse.divert([.hapticPanel])
        mouse.start()
        mouse.setActive(true)
        defer { mouse.releaseAllSync() }   // also when a wait or an expectation below fails
        try await waitConnected(mouse)
        try await Task.sleep(for: .milliseconds(500))   // the divert is written one request at a time
        #expect(mouse.isConnected)
        #expect(try await panelDiverted(channel, device: device), "LogiMouse did not divert the panel")

        // The exit path: releases fired without waiting for replies must all reach the mouse.
        mouse.releaseAllSync()
        try await Task.sleep(for: .milliseconds(200))
        #expect(try await !panelDiverted(channel, device: device), "the panel is still diverted after releaseAllSync")
    }

    /// `0x1B04` function 2 (getControlReporting) for the haptic panel: whether its divert flag (bit 0 of the flags
    /// byte after the CID) is set.
    private func panelDiverted(_ channel: HIDPPChannel, device: UInt8) async throws -> Bool {
        let cid = CID.hapticPanel.rawValue
        let reply = try await channel.call(ReprogControls.featureID, device: device, function: 2,
                                           params: [UInt8(cid >> 8), UInt8(cid & 0xFF)], echo: [UInt8(cid >> 8), UInt8(cid & 0xFF)])
        return reply[2] & 0x01 != 0
    }

    @MainActor private func waitConnected(_ mouse: LogiMouse) async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while !mouse.isConnected {
            try #require(ContinuousClock.now < deadline, "the mouse was not set up within 10 s")
            try await Task.sleep(for: .milliseconds(50))
        }
    }
}
