import Foundation
import LogiHIDPP

// `list` is read-only on the mouse (root, feature set, getControlInfo, getControlReporting); `raw` only listens.
// `listen`, `watch`, `thumbwheel`, `haptic` and `haptic-all` run on `LogiMouse` (the probe is its own foreground app: it calls
// `setActive(true)`); `release` talks to the channel directly, to clear every divert, whoever set it; so do `force`,
// `strength`, `hires` and `smartshift`, so that "written" means a confirmed write that reads back.
let usage = """
    usage: logi-probe <command>

    Talks HID++ 2.0 to a Logitech mouse on a Bolt / Unifying receiver (no Logi Options+ needed).

      list                    receivers, devices, HID++ version, features, buttons and what is diverted
      raw <seconds>           print every incoming HID++ report with a timestamp
      listen [cid…]           divert buttons (hex CIDs; none = every divertable one except left/right) and print presses
      watch [cid…]            listen to buttons without taking them (hex CIDs, default 53 56) and print presses;
                              macOS still gets the buttons
      thumbwheel              divert the thumb wheel and print its steps
      haptic <N|name> [s]     play a haptic pattern by number (0…14, 0x1b) or name (whisper-collision); with s
                              (0-100), as a strong play: strength s for this pattern, then the normal one again
      haptic-all [pause]      play every haptic pattern in turn, announcing each (pause in seconds, default 2)
      force [value]           show the haptic panel's force; with a value, write it (clamped to the mouse's range)
      strength [0-100]        show the haptic strength; with a value, write it
      hires [on|off]          show the vertical wheel's mode (0x2121, Precision Scroll); with on / off, write the
                              high-resolution bit (the others stay) and read it back
      smartshift [free|ratchet]
                              show the wheel mode (0x2111: free spin or ratchet, the auto-disengage threshold, the
                              torque); with free / ratchet, write the mode and read it back
      release                 hand every divertable control and the thumb wheel back to the mouse

    listen and thumbwheel release what they diverted, and watch switches off what it watched, on Ctrl-C and on exit.
    After a crash of an app that diverted controls, run `logi-probe release` (or let the mouse sleep).
    """

/// How long to collect receiver arrivals: present receivers are reported on the HID thread's first run-loop pass.
let arrivalWindow: Duration = .milliseconds(500)

enum Feature {
    static let featureSet: UInt16 = 0x0001
}

func hex(_ value: some BinaryInteger, width: Int) -> String {
    let digits = String(value, radix: 16)
    return String(repeating: "0", count: max(0, width - digits.count)) + digits
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("logi-probe: \(message)\n".utf8))
    exit(1)
}

/// The receivers present now (arrivals within `arrivalWindow`).
func presentReceivers() async -> [IOKitTransport] {
    let collector = Task {
        var found: [IOKitTransport] = []
        for await transport in IOKitTransport.receivers() { found.append(transport) }
        return found
    }
    try? await Task.sleep(for: arrivalWindow)
    collector.cancel()
    return await collector.value
}

func describe(_ transport: IOKitTransport) -> String {
    "\(transport.productName) (046d:\(hex(transport.productID, width: 4)))"
}

// MARK: - list

func list() async {
    let receivers = await presentReceivers()
    guard !receivers.isEmpty else { fail("no Logitech receiver with a HID++ interface (page 0xFF00, usage 1)") }
    for transport in receivers {
        print("receiver \(describe(transport))")
        let channel = HIDPPChannel(transport: transport)
        let devices = await channel.discover()
        if devices.isEmpty { print("  no device answered a ping") }
        for device in devices {
            await listDevice(device, on: channel)
        }
    }
}

func listDevice(_ device: UInt8, on channel: HIDPPChannel) async {
    do {
        let version = try await channel.ping(device: device)
        print("  device \(device): HID++ \(version.major).\(version.minor)")

        let count = try await channel.call(Feature.featureSet, device: device, function: 0)[0]
        print("  features: \(count) (+ root)")
        for index in 0...count {
            // getFeatureID: feature ID (2), type, version.
            let info = try await channel.call(Feature.featureSet, device: device, function: 1, params: [index])
            let id = UInt16(info[0]) << 8 | UInt16(info[1])
            print("    \(hex(index, width: 2)) \(hex(id, width: 4))  type \(hex(info[2], width: 2)) v\(info[3])")
        }

        let reprog: UInt8
        do {
            reprog = try await channel.featureIndex(ReprogControls.featureID, device: device)
        } catch HIDPPError.featureMissing {
            print("  no 0x1b04 (REPROG_CONTROLS_V4)")
            return
        }
        let controls = try await channel.call(ReprogControls.featureID, device: device, function: 0)[0]
        print("  0x1b04 at \(reprog): \(controls) controls")
        for index in 0..<controls {
            // getControlInfo: cid (2), tid (2), flags, pos, group, gmask, additional flags.
            let info = try await channel.call(ReprogControls.featureID, device: device, function: 1, params: [index])
            let cid = UInt16(info[0]) << 8 | UInt16(info[1])
            let tid = UInt16(info[2]) << 8 | UInt16(info[3])
            // getControlReporting: cid (2), reporting flags, remap cid (2), additional reporting flags.
            let reporting = try await channel.call(ReprogControls.featureID, device: device, function: 2,
                                                   params: [info[0], info[1]])
            let remap = UInt16(reporting[3]) << 8 | UInt16(reporting[4])
            let diverted = reporting[2] & 0x01 != 0 ? "  DIVERTED" : ""
            print("    cid \(hex(cid, width: 4)) tid \(hex(tid, width: 4)) flags \(hex(info[4], width: 2))"
                  + " pos \(hex(info[5], width: 2)) group \(hex(info[6], width: 2)) gmask \(hex(info[7], width: 2))"
                  + " flags2 \(hex(info[8], width: 2))"
                  + " | reporting \(hex(reporting[2], width: 2)) remap \(hex(remap, width: 4))"
                  + " flags2 \(hex(reporting[5], width: 2))\(diverted)")
        }
    } catch {
        print("  device \(device): \(error)")
    }
}

// MARK: - raw

func raw(seconds: Double) async {
    let receivers = await presentReceivers()
    guard !receivers.isEmpty else { fail("no Logitech receiver with a HID++ interface (page 0xFF00, usage 1)") }
    let start = IOKitTransport.currentTime
    for transport in receivers { print("listening on \(describe(transport))") }
    print("for \(seconds) s; time is seconds since the start (absolute: seconds since boot)")
    fflush(stdout)
    await withTaskGroup(of: Void.self) { group in
        for (number, transport) in receivers.enumerated() {
            let events = transport.events
            let tag = receivers.count > 1 ? "r\(number) " : ""
            group.addTask {
                for await event in events {
                    switch event {
                    case .report(let report, let time):
                        print(String(format: "%@%10.6f  (%.6f)  ", tag, time - start, time) + report.description)
                    case .removed:
                        print("\(tag)removed")
                    }
                    fflush(stdout)
                }
            }
        }
        try? await Task.sleep(for: .seconds(seconds))
        group.cancelAll()
    }
}

// MARK: - LogiMouse commands

/// Written once at startup: the probe's process time zero for event timestamps.
let probeStart = IOKitTransport.currentTime

func timestamp(_ time: Double = IOKitTransport.currentTime) -> String {
    String(format: "%10.6f", time - probeStart)
}

func line(_ text: String, at time: Double = IOKitTransport.currentTime) {
    print("\(timestamp(time))  \(text)")
    fflush(stdout)
}

func cidText(_ cid: CID) -> String { "0x" + hex(cid.rawValue, width: 4) }

func describe(_ event: MouseEvent) -> String {
    switch event {
    case .pressed(let cid, _): "pressed  \(cidText(cid))"
    case .released(let cid, _): "released \(cidText(cid))"
    case .thumbWheel(let delta, let touching, let phase, _):
        "thumbwheel delta \(delta >= 0 ? "+" : "")\(delta)  \(touching ? "touching" : "off-wheel")  \(phase)"
    case .connected: "connected"
    case .disconnected: "disconnected"
    case .highResolutionWheel(let on): "wheel high resolution \(on ? "on" : "off")"
    case .wheelMode(let mode, let byButton): "wheel mode \(mode)\(byButton ? " (SmartShift button)" : "")"
    }
}

func time(of event: MouseEvent) -> Double {
    switch event {
    case .pressed(_, let at), .released(_, let at), .thumbWheel(_, _, _, let at): at
    case .connected, .disconnected, .highResolutionWheel, .wheelMode: IOKitTransport.currentTime
    }
}

/// Releases what this process diverted (at most ~100 ms) and exits. The probe's only way out once a mouse is started.
@MainActor func shutdown(_ mouse: LogiMouse, code: Int32) -> Never {
    mouse.releaseAllSync()
    exit(code)
}

/// Ctrl-C, `kill` and a closed terminal release what the probe diverted before the process goes. SIGINT's default action is ignored first,
/// so the dispatch source gets it; the handler runs on the main queue, outside any signal context.
@MainActor func installSignalHandlers(for mouse: LogiMouse) {
    for number in [SIGINT, SIGTERM, SIGHUP] {
        signal(number, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
        source.setEventHandler {
            MainActor.assumeIsolated {
                print("\nreleasing…")
                fflush(stdout)
                shutdown(mouse, code: 128 + number)
            }
        }
        source.resume()
        signalSources.append(source)
    }
}

var signalSources: [any DispatchSourceSignal] = []

/// A started `LogiMouse` of this process, active, with Ctrl-C releasing what it diverted.
@MainActor func startMouse(divertingBefore setup: (LogiMouse) -> Void = { _ in }) -> LogiMouse {
    let mouse = LogiMouse()
    installSignalHandlers(for: mouse)
    setup(mouse)
    mouse.start()
    mouse.setActive(true)
    return mouse
}

/// Waits for the mouse to be set up; false after `timeout` (the mouse answers late after a long idle).
@MainActor func waitConnected(_ mouse: LogiMouse, timeout: Duration = .seconds(10)) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while !mouse.isConnected {
        guard ContinuousClock.now < deadline else { return false }
        try? await Task.sleep(for: .milliseconds(50))
    }
    return true
}

func parseCID(_ text: String) -> CID {
    var digits = Substring(text.lowercased())
    if digits.hasPrefix("0x") { digits = digits.dropFirst(2) }
    guard let value = UInt16(digits, radix: 16), value != 0 else { fail("not a hex control ID: \(text)") }
    return CID(rawValue: value)
}

/// Prints events until the process is stopped. `onConnected` runs on every `.connected`, after its line is printed.
@MainActor func printEvents(of mouse: LogiMouse, onConnected: (LogiMouse) -> Void) async -> Never {
    let hint = Task { @MainActor in
        try? await Task.sleep(for: .seconds(5))
        if !mouse.isConnected && !Task.isCancelled { line("no mouse connected yet; still looking (switch it on)") }
    }
    for await event in mouse.events {
        line(describe(event), at: time(of: event))
        if event == .connected {
            hint.cancel()
            onConnected(mouse)
        }
    }
    shutdown(mouse, code: 0)
}

@MainActor func listen(_ cids: [CID]) async -> Never {
    let requested = Set(cids)
    let mouse = startMouse { if !requested.isEmpty { $0.divert(requested) } }
    print("listening; Ctrl-C releases everything")
    await printEvents(of: mouse) { mouse in
        let divertable = Set(mouse.controls.filter(\.divertable).map(\.cid))
        let all = mouse.controls.map { cidText($0.cid) + ($0.divertable ? "" : " (not divertable)") }
        line("controls: " + all.joined(separator: ", "))
        for cid in requested.subtracting(divertable).sorted(by: { $0.rawValue < $1.rawValue }) {
            line("\(cidText(cid)) is not a divertable control of this mouse; ignored")
        }
        // Without arguments never left and right: diverted, they would stop clicking until the probe exits.
        let wanted = requested.isEmpty ? divertable.subtracting([.left, .right]) : requested
        if requested.isEmpty, !divertable.isDisjoint(with: [.left, .right]) {
            line("left and right (0x0050, 0x0051) are divertable but skipped; name them to divert them")
        }
        mouse.divert(wanted)
        line("diverting " + wanted.intersection(divertable).sorted(by: { $0.rawValue < $1.rawValue })
                .map(cidText).joined(separator: ", "))
    }
}

/// Like `listen`, but the buttons are only watched (analytics key events): they keep working in macOS and in any other
/// app that owns them, e.g. Mac Mouse Fix.
@MainActor func watch(_ cids: [CID]) async -> Never {
    let requested = Set(cids.isEmpty ? [.back, .forward] : cids)
    let mouse = startMouse { $0.watch(requested) }
    print("watching; the buttons keep working in macOS; Ctrl-C switches it off")
    await printEvents(of: mouse) { mouse in
        let watchable = Set(mouse.controls.filter(\.watchable).map(\.cid))
        let all = mouse.controls.map { cidText($0.cid) + ($0.watchable ? "" : " (not watchable)") }
        line("controls: " + all.joined(separator: ", "))
        for cid in requested.subtracting(watchable).sorted(by: { $0.rawValue < $1.rawValue }) {
            line("\(cidText(cid)) is not a watchable control of this mouse; ignored")
        }
        line("watching " + requested.intersection(watchable).sorted(by: { $0.rawValue < $1.rawValue })
                .map(cidText).joined(separator: ", "))
    }
}

@MainActor func thumbwheel() async -> Never {
    let mouse = startMouse { $0.divertThumbWheel(true) }
    print("listening to the thumb wheel; Ctrl-C releases it")
    await printEvents(of: mouse) { mouse in
        if let steps = mouse.stepsPerRevolution {
            line("thumb wheel diverted, \(steps) steps per revolution")
        } else {
            line("this mouse reports no thumb wheel resolution (no thumb wheel?)")
        }
    }
}

/// A pattern by decimal or 0x-hex number, or by name ("whisper-collision").
func parsePattern(_ text: String) -> HapticPattern? {
    let number = text.lowercased().hasPrefix("0x") ? UInt8(text.dropFirst(2), radix: 16) : UInt8(text)
    return number.flatMap { HapticPattern($0) } ?? HapticPattern(named: text)
}

@MainActor func haptic(_ patterns: [HapticPattern], pause: Duration, strength: UInt8? = nil) async -> Never {
    let mouse = startMouse()
    guard await waitConnected(mouse) else {
        fail("no mouse connected within 10 s (switch it on and move it)")
    }
    for (number, pattern) in patterns.enumerated() {
        if number > 0 { try? await Task.sleep(for: pause) }
        let strong = strength.map { "  at strength \($0) (normal \(mouse.hapticStrength.map(String.init) ?? "?"))" }
        line("pattern " + String(format: "0x%02X", pattern.rawValue) + "  " + pattern.name + (strong ?? ""))
        mouse.play(haptic: pattern, strength: strength)
    }
    // `play` posts without waiting; give the last command time to leave (nothing plays if haptics are off in the mouse).
    try? await Task.sleep(for: .milliseconds(500))
    shutdown(mouse, code: 0)
}

// MARK: - Settings

private enum HapticConfig {
    static let read: UInt8 = 1
    static let write: UInt8 = 2
}

private enum Force {
    static let count: UInt8 = 0
    static let info: UInt8 = 1
    static let current: UInt8 = 2
    static let write: UInt8 = 3
    static let panelButton: UInt8 = 0
}

/// Prints the haptic strength of every mouse; with `value`, writes it (confirmed by its echo) and reads it back.
func strength(_ value: UInt8?) async {
    var failures = 0
    for (channel, device) in await findTargets() {
        do {
            let config = Haptics.config(from: try await channel.call(Haptics.featureID, device: device,
                                                                     function: HapticConfig.read))
            print("device \(device): haptics \(config.enabled ? "on" : "off"), strength \(config.intensity)")
            guard let value else { continue }
            guard config.enabled else {
                print("  haptics are off: not written (the write would switch them on)")
                failures += 1
                continue
            }
            let params = Haptics.setConfigParams(strength: value)
            _ = try await channel.call(Haptics.featureID, device: device, function: HapticConfig.write,
                                       params: params, echo: params)
            let back = Haptics.config(from: try await channel.call(Haptics.featureID, device: device,
                                                                   function: HapticConfig.read))
            if back.intensity == value {
                print("  written: strength \(value) (confirmed, reads back)")
            } else {
                print("  written, but it reads back \(back.intensity)")
                failures += 1
            }
        } catch HIDPPError.featureMissing {
            print("device \(device): no haptics (0x19b0)")
        } catch {
            print("device \(device): \(error)")
            failures += 1
        }
    }
    if failures > 0 { fail("\(failures) device(s) not written as asked") }
}

/// Prints the haptic panel's force of every mouse; with `value`, writes it clamped to the mouse's range (confirmed by
/// its reply) and reads it back.
func force(_ value: UInt16?) async {
    var failures = 0
    for (channel, device) in await findTargets() {
        do {
            let count = try await channel.call(ForceSensing.featureID, device: device, function: Force.count)[0]
            guard count > 0 else {
                print("device \(device): no force-sensing button")
                continue
            }
            let button = [Force.panelButton]
            let infoReply = try await channel.call(ForceSensing.featureID, device: device, function: Force.info,
                                                   params: button)
            let currentReply = try await channel.call(ForceSensing.featureID, device: device, function: Force.current,
                                                      params: button)
            guard let info = ForceSensing.info(from: infoReply), let current = ForceSensing.current(from: currentReply)
            else {
                print("device \(device): unexpected force-sensing reply")
                failures += 1
                continue
            }
            print("device \(device): panel force \(current) (default \(info.defaultValue), range "
                  + "\(info.range.lowerBound)…\(info.range.upperBound)\(info.changeable ? "" : ", not changeable"))")
            guard let value else { continue }
            guard info.changeable else {
                print("  not changeable: nothing written")
                failures += 1
                continue
            }
            let target = min(max(value, info.range.lowerBound), info.range.upperBound)
            if target != value { print("  \(value) is outside the range: writing \(target)") }
            _ = try await channel.call(ForceSensing.featureID, device: device, function: Force.write,
                                       params: ForceSensing.setParams(button: Force.panelButton, value: target))
            let back = ForceSensing.current(from: try await channel.call(ForceSensing.featureID, device: device,
                                                                         function: Force.current, params: button))
            if back == target {
                print("  written: panel force \(target) (confirmed, reads back)")
            } else {
                print("  written, but it reads back \(back.map(String.init) ?? "nothing")")
                failures += 1
            }
        } catch HIDPPError.featureMissing {
            print("device \(device): no force-sensing button (0x19c0)")
        } catch {
            print("device \(device): \(error)")
            failures += 1
        }
    }
    if failures > 0 { fail("\(failures) device(s) not written as asked") }
}

/// Prints the hi-res wheel mode (`0x2121`) of every mouse; with `on`, writes the high-resolution bit set or clear
/// (keeping the other bits) and reads it back. Writes no marker: a wheel left on this way counts as the user's own.
func hires(_ on: Bool?) async {
    var failures = 0
    func describe(_ mode: UInt8) -> String {
        "mode 0x\(hex(mode, width: 2)): high resolution \(mode & 0x02 != 0 ? "on" : "off"), "
            + "divert \(mode & 0x01 != 0 ? "on" : "off"), invert \(mode & 0x04 != 0 ? "on" : "off")"
    }
    for (channel, device) in await findTargets() {
        do {
            let index = try await channel.featureIndex(HiResWheel.featureID, device: device)
            let mode = try await channel.call(HiResWheel.featureID, device: device, function: HiResMode.read)[0]
            print("device \(device): hi-res wheel (0x2121, index \(index)) \(describe(mode))")
            guard let on else { continue }
            let target = on ? mode | HiResWheel.highResolution : mode & ~HiResWheel.highResolution
            _ = try await channel.call(HiResWheel.featureID, device: device, function: HiResMode.write,
                                       params: [target])
            let back = try await channel.call(HiResWheel.featureID, device: device, function: HiResMode.read)[0]
            if back == target {
                print("  written: \(describe(back)) (confirmed, reads back)")
            } else {
                print("  written 0x\(hex(target, width: 2)), but it reads back \(describe(back))")
                failures += 1
            }
        } catch HIDPPError.featureMissing {
            print("device \(device): no hi-res wheel (0x2121)")
        } catch {
            print("device \(device): \(error)")
            failures += 1
        }
    }
    if failures > 0 { fail("\(failures) device(s) not written as asked") }
}

private enum HiResMode {
    static let read: UInt8 = 1
    static let write: UInt8 = 2
}

/// Prints the SmartShift state (`0x2111`) of every mouse: the wheel mode (free spin or ratchet), the auto-disengage
/// threshold and the torque; with a mode, writes it (`[mode, 0, 0]`: the threshold and torque stay) and reads it back.
/// Writes no marker: a mode left this way counts as the mouse's own.
func smartShift(_ mode: WheelMode?) async {
    var failures = 0
    func describe(_ reply: [UInt8]) -> String {
        let name = WheelMode(rawValue: reply[0]).map { $0 == .freeSpin ? "free spin" : "ratchet" }
            ?? "unknown mode 0x\(hex(reply[0], width: 2))"
        return "\(name), auto-disengage \(reply[1]), torque \(reply[2])"
    }
    for (channel, device) in await findTargets() {
        do {
            let index = try await channel.featureIndex(SmartShift.featureID, device: device)
            let reply = try await channel.call(SmartShift.featureID, device: device, function: SmartShiftFunction.read)
            guard reply.count >= 3 else {
                print("device \(device): SmartShift (0x2111, index \(index)): the mode reply is too short")
                failures += 1
                continue
            }
            print("device \(device): SmartShift (0x2111, index \(index)) \(describe(reply))")
            guard let mode else { continue }
            _ = try await channel.call(SmartShift.featureID, device: device, function: SmartShiftFunction.write,
                                       params: [mode.rawValue, 0, 0])
            let back = try await channel.call(SmartShift.featureID, device: device, function: SmartShiftFunction.read)
            if back.count >= 3, back[0] == mode.rawValue {
                print("  written: \(describe(back)) (confirmed, reads back)")
            } else {
                let shown = back.count >= 3 ? describe(back) : "a reply too short to read"
                print("  written mode \(mode.rawValue), but it reads back \(shown)")
                failures += 1
            }
        } catch HIDPPError.featureMissing {
            print("device \(device): no SmartShift (0x2111)")
        } catch {
            print("device \(device): \(error)")
            failures += 1
        }
    }
    if failures > 0 { fail("\(failures) device(s) not written as asked") }
}

private enum SmartShiftFunction {
    static let read: UInt8 = 1
    static let write: UInt8 = 2
}

// MARK: - release

private enum Reprog {
    static let count: UInt8 = 0
    static let controlInfo: UInt8 = 1
    static let setReporting: UInt8 = 3
}

private let wheelSetReporting: UInt8 = 2

/// Hands every divertable control and the thumb wheel of the mouse back, whoever diverted them: `LogiMouse.releaseAll`
/// only releases what its own object requested, so the probe does it directly on the channel (and confirms each reply).
func release() async {
    var failures = 0
    for target in await findTargets() { failures += await release(target.channel, device: target.device) }
    if failures > 0 { fail("\(failures) release request(s) failed") }
}

/// The mice on every receiver (devices with REPROG_CONTROLS_V4 and haptics or a thumb wheel), else the first device
/// with REPROG_CONTROLS_V4 alone, as `LogiMouse` picks them. Fails when there is none.
func findTargets() async -> [(channel: HIDPPChannel, device: UInt8)] {
    let receivers = await presentReceivers()
    guard !receivers.isEmpty else { fail("no Logitech receiver with a HID++ interface (page 0xFF00, usage 1)") }
    var mice: [(channel: HIDPPChannel, device: UInt8)] = []
    var fallbacks: [(channel: HIDPPChannel, device: UInt8)] = []
    for transport in receivers {
        let channel = HIDPPChannel(transport: transport)
        for device in await channel.discover() {
            guard (try? await channel.featureIndex(ReprogControls.featureID, device: device)) != nil else { continue }
            let hasHaptics = (try? await channel.featureIndex(Haptics.featureID, device: device)) != nil
            let hasWheel = (try? await channel.featureIndex(ThumbWheel.featureID, device: device)) != nil
            let isMouse = hasHaptics || hasWheel
            if isMouse { mice.append((channel, device)) } else { fallbacks.append((channel, device)) }
        }
    }
    // Like LogiMouse: a device with haptics or a thumb wheel is a mouse; else the first with 0x1B04.
    let targets = mice.isEmpty ? Array(fallbacks.prefix(1)) : mice
    guard !targets.isEmpty else { fail("no device with REPROG_CONTROLS_V4 (0x1b04) answered") }
    return targets
}

/// Returns the number of failed requests.
func release(_ channel: HIDPPChannel, device: UInt8) async -> Int {
    var failures = 0
    print("device \(device)")
    do {
        let count = try await channel.call(ReprogControls.featureID, device: device, function: Reprog.count)[0]
        var released = 0
        for index in 0..<count {
            do {
                let info = try await channel.call(ReprogControls.featureID, device: device,
                                                  function: Reprog.controlInfo, params: [index])
                let control = ReprogControls.control(fromInfo: info)
                guard control.divertable else { continue }
                let params = ReprogControls.divertParams(control.cid, divert: false)
                do {
                    _ = try await channel.call(ReprogControls.featureID, device: device, function: Reprog.setReporting,
                                               params: params, echo: Array(params.prefix(2)))
                    released += 1
                    print("  released \(cidText(control.cid))")
                } catch {
                    failures += 1
                    print("  \(cidText(control.cid)): \(error)")
                }
            } catch {
                failures += 1
                print("  control #\(index): \(error)")
            }
        }
        print("  \(released) of \(count) controls released (the rest are not divertable)")
    } catch {
        failures += 1
        print("  controls: \(error)")
    }
    do {
        _ = try await channel.call(ThumbWheel.featureID, device: device, function: wheelSetReporting,
                                   params: ThumbWheel.reportingParams(divert: false))
        print("  thumb wheel released")
    } catch HIDPPError.featureMissing {
        print("  no thumb wheel")
    } catch {
        failures += 1
        print("  thumb wheel: \(error)")
    }
    return failures
}

// MARK: - main

let arguments = Array(CommandLine.arguments.dropFirst())
switch arguments.first {
case "list" where arguments.count == 1:
    await list()
case "raw" where arguments.count == 2:
    guard let seconds = Double(arguments[1]), seconds > 0 else { fail("raw: seconds must be a positive number") }
    await raw(seconds: seconds)
case "listen":
    await listen(arguments.dropFirst().map(parseCID))
case "watch":
    await watch(arguments.dropFirst().map(parseCID))
case "thumbwheel" where arguments.count == 1:
    await thumbwheel()
case "haptic" where arguments.count == 2 || arguments.count == 3:
    guard let pattern = parsePattern(arguments[1]) else {
        fail("haptic: unknown pattern; use a number (0…14, 27 or 0x1b) or a name like whisper-collision")
    }
    var strength: UInt8?
    if arguments.count == 3 {
        guard let parsed = UInt8(arguments[2]), parsed <= 100 else { fail("haptic: the strength must be 0…100") }
        strength = parsed
    }
    await haptic([pattern], pause: .zero, strength: strength)
case "haptic-all" where arguments.count <= 2:
    var pause = 2.0
    if arguments.count == 2 {
        guard let seconds = Double(arguments[1]), seconds >= 0 else { fail("haptic-all: pause must be a number of seconds") }
        pause = seconds
    }
    await haptic(HapticPattern.all, pause: .seconds(pause))
case "force" where arguments.count <= 2:
    var value: UInt16?
    if arguments.count == 2 {
        guard let parsed = UInt16(arguments[1]) else { fail("force: the value must be a number (0…65535)") }
        value = parsed
    }
    await force(value)
case "strength" where arguments.count <= 2:
    var value: UInt8?
    if arguments.count == 2 {
        guard let parsed = UInt8(arguments[1]), parsed <= 100 else { fail("strength: the value must be 0…100") }
        value = parsed
    }
    await strength(value)
case "hires" where arguments.count <= 2:
    var on: Bool?
    if arguments.count == 2 {
        switch arguments[1] {
        case "on": on = true
        case "off": on = false
        default: fail("hires: use on or off")
        }
    }
    await hires(on)
case "smartshift" where arguments.count <= 2:
    var mode: WheelMode?
    if arguments.count == 2 {
        switch arguments[1] {
        case "free": mode = .freeSpin
        case "ratchet": mode = .ratchet
        default: fail("smartshift: use free or ratchet")
        }
    }
    await smartShift(mode)
case "release" where arguments.count == 1:
    await release()
case nil, "help", "-h", "--help":
    print(usage)
default:
    FileHandle.standardError.write(Data((usage + "\n").utf8))
    exit(64)
}
