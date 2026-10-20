import Foundation
import os
import Synchronization

private let log = Logger(subsystem: "LogiHIDPP", category: "LogiMouse")

/// A Logitech mouse on a Bolt / Unifying receiver, as an app sees it: its controls, diverted buttons and thumb wheel
/// as `events`, haptic patterns, and two settings of the mouse: haptic strength and panel force.
///
/// **Lifecycle.** `start()` opens every Logitech receiver (now and later) and pings the six slots of each. It takes the
/// first device with REPROG_CONTROLS_V4 (`0x1B04`) that also has haptics (`0x19B0`) or a thumb wheel (`0x2150`) — a
/// mouse, not a keyboard — or else the first with `0x1B04` alone, until a device that qualifies links. It reads the
/// device's controls, thumb-wheel info and haptic config; on the first binding after `start()` it releases every
/// control the app wants (left over if a previous run crashed); then it emits `.connected`.
/// When the mouse switches off or loses its link the receiver says so: held controls are released (`.released`
/// events), then `.disconnected`. When it links again the feature indices are looked up anew and the wanted state is
/// applied again (the mouse forgets diverts). A removed receiver works the same way; a re-plugged one is found anew.
/// No mouse at all: the package stays silent.
///
/// **Watching.** `watch(_:)` listens to controls without taking them: the mouse reports their presses over HID++
/// (analytics key events) and still sends the button to the OS, so an app that diverts nothing (or another app, such as
/// Mac Mouse Fix, that owns the button) keeps it. The presses come out as the same `.pressed` / `.released` events as
/// diverted ones; the OS also gets each of them, which `watching` tells the app to ignore.
///
/// **Foreground rule.** The wanted state (`divert(_:)`, `watch(_:)`, `divertThumbWheel(_:)`) is applied only while the
/// app is active (`setActive(_:)`, or `follow(app:)` for AppKit apps): on activation, and once more 300 ms later, so a
/// release sent late by the app that just lost the foreground cannot undo it (the same two steps follow every setup
/// while active). On deactivation everything is released, held controls get `.released` events, and button and wheel
/// reports are ignored while inactive (the receiver delivers them to every app listening, including the one that
/// diverted them). `play(haptic:)` does nothing while inactive.
///
/// **Exit.** Call `releaseAllSync()` from `applicationWillTerminate` (`follow(app:)` does it) so no control stays
/// diverted in the mouse. Call it too before dropping the object while the app goes on running: `deinit` releases
/// nothing, so the diverted controls (the thumb wheel, SmartShift) would stay dead in every app until the mouse sleeps.
///
/// **One instance per process.** Each process stamps its own HID++ software ID on its requests
/// (`HIDPPSoftwareID.process`), so it does not take another process's replies on the same receiver; two instances in
/// one process would share it.
///
/// **Mouse settings.** Two settings live in the mouse and survive its sleep: the haptic strength and the haptic
/// panel's force. Both are read at setup (`hapticStrength`, `panelForce`) and written only when the app asks
/// (`setHapticStrength(_:)`, `setPanelForce(_:)`, `play(haptic:strength:)`): at once if the mouse is set up, else at
/// setup, and again after every reconnect. They are not bound to the foreground rule (plays are). The haptic strength
/// is not written to a mouse whose haptics are off (the write would switch them on).
///
/// **Receiver notifications.** On every receiver attach (and in `systemDidWake()`) the receiver's wireless-notification
/// flag (register `0x00`, bit `0x000100`) is read and, only if it is clear, set, keeping every other flag: without it
/// the receiver does not report a mouse that links or loses its link. A failure is logged and ignored.
///
/// **Precision Scroll.** `wantHighResolutionWheel(_:)` is wanted state like `divert(_:)`: the vertical wheel's
/// high-resolution bit (`0x2121`) is set while the app is active and cleared on deactivation, by the same writer. Setup
/// reads the wheel mode; only the bit `0x02` is ever written, from the last mode read. A wheel already in high
/// resolution while `hiResMarker` is clear is the user's own setting and is never written; with the marker set it is a
/// leftover of this app (a crash) and is turned off unless wanted. The marker is set before an on-write and cleared only
/// by a confirmed off-write or a read showing the bit clear. An off-write refused by the mouse is retried every second
/// until it gets through or the mode is wanted again. After any `0x2121` request times out, the wheel rests for the
/// channel's late-reply window (no hi-res request at all), then its mode is read and acted on.
///
/// **SmartShift.** `wantWheelMode(_:)` is wanted state too: the vertical wheel's free spin or ratchet (`0x2111`) is
/// written while the app is active and the mouse's own mode given back on deactivation (nil wants none). Setup and
/// every activation read the mode first (a SmartShift press in another app is not heard); it is written only when
/// known and different from the target. Before the first write of the app's mode (or the first adopted press of the
/// SmartShift button, below), the mode known is saved in `wheelModeMarker`; with nothing wanted, a mouse whose mode
/// differs from the saved one gets it back (a leftover of a crash), and the marker is cleared by a confirmed write of
/// it, by a read showing it while nothing is wanted, or by `releaseAllSync()` once its give-back is sent. A give-back
/// the mouse refuses is retried every second while it is owed. After any `0x2111` request times out, the wheel mode
/// rests like the hi-res wheel (its own rest, as long), then is read and acted on. `wheelMode` and `.wheelMode` tell
/// the mode last read or written; the mouse sends no notification of its own when the mode changes. While a mode is
/// wanted, the writer also watches the SmartShift button (`CID.smartShift`, unless the app diverts it), as `watch(_:)`
/// would but without `watching` or `.pressed` / `.released` events: the mouse switches the mode itself on a press, so
/// from the press until its release (at most `smartShiftHoldLimit`) no mode is written, and the mode is read after
/// the release (a read while the button is down counts the same). While the app's mode is applied, a mode other than
/// the wanted one becomes the wanted one (the user's choice: nothing is written back, but the mouse's own mode is
/// saved as before a write, so deactivation gives it back), and every such read is reported as
/// `.wheelMode(_, byButton: true)`, even unchanged; read after deactivation or a give-back, it is only noted.
@MainActor
public final class LogiMouse {
    /// Whether a mouse is linked and set up (between `.connected` and `.disconnected`).
    public private(set) var isConnected = false
    /// The mouse's controls, as REPROG_CONTROLS_V4 lists them; empty until the first `.connected`.
    public private(set) var controls: [Control] = []
    /// The controls whose analytics reporting the mouse has confirmed switched on (the reply to the request arrived)
    /// and that are still wanted: empty while inactive, disconnected or set up anew. Their button events also reach
    /// the OS, so the app, which hears these presses from `events`, ignores the OS events of exactly these controls.
    public private(set) var watching: Set<CID> = []
    /// Thumb-wheel steps per revolution while it is diverted (`.thumbWheel` deltas count these); nil without a thumb
    /// wheel or when the mouse reports 0.
    public private(set) var stepsPerRevolution: Int?
    /// The mouse's haptic strength (0…100): read at setup, then the normal strength once a write of it is confirmed
    /// (never the strength of a strong play, nor one read while a strong play may have been under way). Nil without a
    /// mouse with haptics.
    public private(set) var hapticStrength: UInt8?
    /// The haptic panel's force (`0x19C0`, button 0): its current value and settings, read at setup and updated by
    /// `setPanelForce(_:)` once written. Nil without a mouse with a force-sensing button.
    public private(set) var panelForce: (current: UInt16, info: ForceSensing.Info)?
    /// Whether the connected mouse's vertical wheel is in high resolution now (`0x2121`), by this app or by the user's
    /// own setting; `.highResolutionWheel` reports each change. False without a mouse or without the feature.
    public private(set) var isHighResolution = false
    /// The connected mouse's wheel mode (SmartShift, `0x2111`), as last read or confirmed written; `.wheelMode` reports
    /// each change. Nil without a mouse, without the feature or while the mode is unknown (a failed read).
    public private(set) var wheelMode: WheelMode?

    /// Everything the mouse reports, delivered from the main actor. One stream for the object's lifetime: every read of
    /// the property returns the same stream, which supports a single consumer (a second `for await` would split the
    /// events between the two). Unbounded buffer: events wait until read.
    public let events: AsyncStream<MouseEvent>

    /// The delay of the second application of the wanted state after activation.
    static let reapplyDelay: Duration = .milliseconds(300)
    /// The wait before a failed setup is tried again. At least the channel's late-reply window (5 s): a retry sooner
    /// would have its reply swallowed by the failed request's tombstone.
    static let setupRetryDelay: Duration = .seconds(5)
    /// Setup attempts per connection (the first and two retries).
    static let setupAttempts = 3
    /// The wait before a hi-res off-write that the mouse refused (an error reply) is sent again.
    static let hiResRetryDelay: Duration = .seconds(1)
    /// After a `0x2121` request timed out, no hi-res request is sent for this long: at least the channel's late-reply
    /// window, as the timed-out request's tombstone would swallow the next reply on its key (setMode has no echo), that
    /// request would time out in turn, and so on, each stalling the writer. The rest ends with a read of the mode.
    /// The SmartShift mode rests as long after a timed-out `0x2111` request (its own rest).
    static let hiResRestDelay: Duration = setupRetryDelay
    /// The wait before a SmartShift give-back that the mouse refused (an error reply) is sent again.
    static let wheelModeRetryDelay: Duration = hiResRetryDelay
    /// How long the SmartShift button counts as down without its release (a lost release report); then it counts as
    /// released, and the mode is read as after a release.
    static let smartShiftHoldLimit: Duration = .seconds(1)

    private let makeTransports: () -> AsyncStream<any HIDPPTransport>
    private let clock: any Clock<Duration>
    private let requestTimeout: Duration
    /// The software ID of this object's channels (nil: the process's).
    private let softwareID: UInt8?
    private let continuation: AsyncStream<MouseEvent>.Continuation
    /// Tasks that live as long as the object: the transport loop and one notification listener per receiver.
    private let lifetime = TaskBag()

    private var started = false
    /// Set by `releaseAllSync`: nothing more is written to any mouse.
    private var terminated = false
    private var active = false
    private var wantedCIDs: Set<CID> = []
    private var wantedWatch: Set<CID> = []
    private var wantsThumbWheel = false
    private var wantsHiRes = false
    /// Set while this app's high resolution may be on in a mouse (persistent: it survives a crash).
    private let hiResMarker: any HiResMarker
    /// The writer's next pass reads the wheel mode first (`recheckHighResolutionWheel`, a wake, the end of a rest).
    private var hiResReadPending = false
    /// The retry of an off-write the mouse refused.
    private var hiResRetryTask: Task<Void, Never>?
    /// The rest after a timed-out `0x2121` request (`hiResRestDelay`): while it runs, no hi-res request is sent.
    private var hiResRestTask: Task<Void, Never>?
    /// Hi-res off-writes failed in a row (the first is logged, and the success after them).
    private var hiResFailures = 0
    /// The wheel mode the app wants (`wantWheelMode`); nil: the mouse's own.
    private var wantedWheelMode: WheelMode?
    /// The mouse's own wheel mode while this app's may be in it (persistent: it survives a crash).
    private let wheelModeMarker: any WheelModeMarker
    /// The writer's next pass reads the wheel mode first (`recheckWheelMode`, a wake, the end of a rest).
    private var wheelModeReadPending = false
    /// The writer's next pass reads the wheel mode first because the SmartShift button was released; one read serves
    /// this and `wheelModeReadPending` together, as a by-button read.
    private var wheelModeButtonReadPending = false
    /// The SmartShift button is down (its press heard by the internal watch, its release not yet): the mouse has
    /// already switched the mode, so no wheel-mode write is sent and every mode read counts as a by-button read.
    /// Ended by the release, deactivation, a disconnect or an unbinding, and `smartShiftHoldLimit` after the press.
    private var wheelModeButtonHeld = false
    /// The end of a hold whose release never came (`smartShiftHoldLimit`).
    private var wheelModeHoldTask: Task<Void, Never>?
    /// The rest after a timed-out `0x2111` request (`hiResRestDelay`): while it runs, no SmartShift request is sent.
    private var wheelModeRestTask: Task<Void, Never>?
    /// The retry of a give-back the mouse refused.
    private var wheelModeRetryTask: Task<Void, Never>?
    /// Give-backs refused in a row (the first is logged, and the success after them).
    private var wheelModeFailures = 0

    private var nextLinkID = 0
    private var links: [Int: Link] = [:]
    /// The mouse this object is bound to (found, possibly not yet set up or currently off).
    private var session: Session?
    /// Bumped whenever the connection state changes (setup started, link lost, receiver removed); an async step that
    /// finds it changed stops without touching state.
    private var epoch = 0
    private var setupTask: Task<Void, Never>?
    /// Whether the crash leftovers were released (once per `start()`, on the first binding to a qualifying device).
    private var leftoversReleased = false
    /// Work for the search: receivers to discover and slots to probe. Items join while it runs; nothing cancels it.
    private var searchQueue: [SearchItem] = []
    private var searchTask: Task<Void, Never>?

    private var tracker = PressTracker()
    /// The controls the last button notification listed as pressed (before filtering by the wanted set).
    private var lastPressed: [CID] = []
    /// Watched controls the app has seen pressed and not yet released, in press order.
    private var watchHeld: [CID] = []

    /// The task writing the wanted state to the mouse, one command at a time; `id` tells a stale task from the current.
    private var writer: (id: Int, task: Task<Void, Never>)?
    private var nextWriterID = 0
    /// The wanted state changed since the writer computed its commands: it starts over with the current state.
    private var syncPending = false
    private var reapplyTask: Task<Void, Never>?

    /// The haptic lane: plays and the setting writes, one command (or strong-play block) at a time, in order.
    private var hapticSlot = LatestOnly<HapticCommand>()
    private var laneBusy = false
    /// The strength the app set (`setHapticStrength`); nil: the mouse's own is the normal one.
    private var appStrength: UInt8?
    /// The lane writes the normal strength next (the app set one, a setup is done, or a block's restore is owed).
    private var strengthWritePending = false
    /// A strong play's strength was sent and the normal one has not been confirmed since.
    private var strengthMayBeOff = false
    /// A strong-play block is running (it ends with the normal strength itself).
    private var blockRunning = false
    /// Counts the strength writes sent: a confirmation counts only for the latest one.
    private var strengthSerial = 0
    /// The mouse may have had a strong strength since the running setup began: the strength it reads is not the
    /// normal one.
    private var strengthUnsureDuringSetup = false
    /// The panel force the app set (`setPanelForce`), before clamping.
    private var appPanelForce: UInt16?
    private var forceWritePending = false

    /// `follow(app:)`'s notification observers, with their centers. Not removed in `deinit` (it is nonisolated): they
    /// hold the object weakly, so after it goes they do nothing.
    var appObservers: [(center: NotificationCenter, observer: any NSObjectProtocol)] = []

    /// A mouse on the Logitech receivers of this Mac (opened by `start()`).
    /// - Parameters:
    ///   - softwareID: the HID++ software ID of its requests (1…15); nil, the default, uses this process's
    ///     (`HIDPPSoftwareID.process`, claimed so that no other process using the package has it).
    ///   - hiResMarker: where "this app turned the wheel to high resolution" is kept across launches (the app's
    ///     `UserDefaults` by default).
    ///   - wheelModeMarker: where the mouse's own wheel mode is kept across launches while this app's may be in the
    ///     mouse (the app's `UserDefaults` by default).
    public convenience init(softwareID: UInt8? = nil, hiResMarker: any HiResMarker = DefaultsHiResMarker(),
                            wheelModeMarker: any WheelModeMarker = DefaultsWheelModeMarker()) {
        self.init(makeTransports: {
            let receivers = IOKitTransport.receivers()
            return AsyncStream { continuation in
                let forward = Task {
                    for await receiver in receivers { continuation.yield(receiver) }
                    continuation.finish()
                }
                continuation.onTermination = { _ in forward.cancel() }
            }
        }, clock: ContinuousClock(), softwareID: softwareID, hiResMarker: hiResMarker, wheelModeMarker: wheelModeMarker)
    }

    /// For tests: receivers come from `transports`, delays run on `clock`, requests time out after `requestTimeout`
    /// and carry `softwareID` (`0x0A`, the ID of the recorded fixtures, by default).
    convenience init(transports: AsyncStream<any HIDPPTransport>, clock: any Clock<Duration>,
                     requestTimeout: Duration = .seconds(2), softwareID: UInt8 = 0x0A,
                     hiResMarker: any HiResMarker, wheelModeMarker: any WheelModeMarker) {
        self.init(makeTransports: { transports }, clock: clock, requestTimeout: requestTimeout, softwareID: softwareID,
                  hiResMarker: hiResMarker, wheelModeMarker: wheelModeMarker)
    }

    private init(makeTransports: @escaping () -> AsyncStream<any HIDPPTransport>, clock: any Clock<Duration>,
                 requestTimeout: Duration = .seconds(2), softwareID: UInt8?, hiResMarker: any HiResMarker,
                 wheelModeMarker: any WheelModeMarker) {
        self.makeTransports = makeTransports
        self.clock = clock
        self.requestTimeout = requestTimeout
        self.softwareID = softwareID
        self.hiResMarker = hiResMarker
        self.wheelModeMarker = wheelModeMarker
        (events, continuation) = AsyncStream.makeStream(of: MouseEvent.self)
    }

    deinit {
        lifetime.cancelAll()
        continuation.finish()
    }

    // MARK: - Public API

    /// Starts looking for the mouse; later calls do nothing. Call `divert(_:)` and `watch(_:)` before or right after
    /// it, so the startup release covers the controls the app wants.
    public func start() {
        guard !started else { return }
        started = true
        let transports = makeTransports()
        lifetime.add(Task { [weak self] in
            for await transport in transports {
                guard let self else { return }
                self.attach(transport)
            }
        })
    }

    /// The controls the app wants diverted to it (replacing the previous set). Applied while the app is active;
    /// controls the mouse does not list as divertable are ignored. A held control that leaves the set gets `.released`.
    public func divert(_ cids: Set<CID>) {
        let kept = wantedCIDs.intersection(cids)   // only releases: a newly wanted control is pressed by its next report
        wantedCIDs = cids
        emit(tracker.update(lastPressed.filter(kept.contains), at: Self.now))
        dropUnwantedWatched()   // a control that is diverted now is no longer watched
        requestSync()
    }

    /// The controls the app wants to hear without taking them (replacing the previous set): their presses arrive as
    /// `.pressed` / `.released` while the app is active, and the mouse keeps sending the buttons to the OS (Mac Mouse
    /// Fix and the like still get them), so the app should ignore the OS events of `watching` controls. Applied under
    /// the same foreground rule as `divert(_:)`, switched off on deactivation, re-applied after a reconnect. Controls
    /// the mouse does not list as `watchable` are ignored. A control in both the divert set and the watch set is
    /// diverted only: its watch is off while it is diverted. A held control that leaves the watch set (or becomes
    /// diverted) gets `.released`.
    ///
    /// Besides this set, `CID.smartShift` is watched internally while a wheel mode is wanted (`wantWheelMode(_:)`) and
    /// the app does not divert it, with the same bookkeeping (off on deactivation, on a give-back and at exit); that
    /// watch never enters `watching` and emits no `.pressed` / `.released`. If the app watches `CID.smartShift` too,
    /// its events come out as usual.
    public func watch(_ cids: Set<CID>) {
        wantedWatch = cids
        dropUnwantedWatched()
        requestSync()
    }

    /// Whether the app wants the thumb wheel (its steps arrive as `.thumbWheel` instead of horizontal scrolling).
    /// Applied while the app is active.
    public func divertThumbWheel(_ on: Bool) {
        wantsThumbWheel = on
        requestSync()
    }

    /// Whether the app wants the vertical wheel in high resolution (Precision Scroll, `0x2121`: about 6 scroll events
    /// per notch instead of 1). Applied while the app is active, like `divert(_:)`; on deactivation the wheel gets its
    /// low resolution back. A wheel already in high resolution by the user's own setting is never written.
    /// `isHighResolution` and `.highResolutionWheel` tell what the wheel is in.
    public func wantHighResolutionWheel(_ on: Bool) {
        wantsHiRes = on
        requestSync()
    }

    /// Reads the wheel mode again and fixes it if it drifted from the wanted state (the mouse slept, or another
    /// program such as BetterMouse rewrote it); also tells a user's own high resolution from a lost one again. Only
    /// while the app is active; does nothing otherwise, nor while the wheel rests after a timed-out request (the rest
    /// ends with a read anyway).
    public func recheckHighResolutionWheel() {
        guard active, !terminated, hiResRestTask == nil, session?.features?.hiRes != nil else { return }
        hiResReadPending = true
        requestSync()
    }

    /// The wheel mode the app wants (SmartShift, `0x2111`: free spin or ratchet); nil gives the mouse its own mode
    /// back. Applied while the app is active, like `divert(_:)`; on deactivation the mouse gets its own mode back (the
    /// one read before this app first wrote, kept in `wheelModeMarker`). `wheelMode` and `.wheelMode` tell the mode. A
    /// press of the SmartShift button while the mode is applied makes the mode it switched to the wanted one (see
    /// "SmartShift" above).
    public func wantWheelMode(_ mode: WheelMode?) {
        wantedWheelMode = mode
        requestSync()
    }

    /// Reads the wheel mode again and fixes it if it drifted from the wanted state (the mouse slept, or the user
    /// switched it). Only while the app is active; does nothing otherwise, nor while the wheel mode rests after a
    /// timed-out request (the rest ends with a read anyway).
    public func recheckWheelMode() {
        guard active, !terminated, wheelModeRestTask == nil, session?.features?.smartShift != nil else { return }
        wheelModeReadPending = true
        requestSync()
    }

    /// Hands every control and the thumb wheel back to the mouse and clears the wanted state (like `divert([])`,
    /// `watch([])`, `divertThumbWheel(false)`, `wantHighResolutionWheel(false)` and `wantWheelMode(nil)`), also
    /// releasing wanted controls this object has not diverted. Asynchronous; at exit use `releaseAllSync()`.
    ///
    /// Call it only while the app is active (or as a manual cure): while inactive it still releases the controls this
    /// app wanted, and so takes them away from the app in the foreground (e.g. FrameScrub) if it diverted them too.
    public func releaseAll() {
        if var session, let features = session.features {
            session.divertedInMouse.formUnion(wantedCIDs.intersection(features.divertable))
            session.watchedInMouse.formUnion(wantedWatch.intersection(features.watchable))
            if wantsThumbWheel && features.wheel != nil { session.wheelDivertedInMouse = true }
            self.session = session
        }
        wantedCIDs = []
        wantedWatch = []
        wantsThumbWheel = false
        wantsHiRes = false
        wantedWheelMode = nil
        watching = []
        releaseHeld()
        requestSync()
    }

    /// Releases, before returning, every control and the thumb wheel this object diverted and switches off every
    /// control it watched, then stops writing to the
    /// mouse for good: for `applicationWillTerminate`.
    ///
    /// If this app's high resolution may be on in the wheel (the marker is set), the mode without it is written too;
    /// the marker stays set (the write is not confirmed), so the next start reads the mode and turns off what is left.
    /// Likewise, the mouse's own wheel mode is written back while `wheelModeMarker` holds it; once that report is sent
    /// without a transport error the marker is cleared (its reply is not awaited), so the next launch does not give a
    /// stale mode back over one the user picks meanwhile with SmartShift in another app. Only a crash, a send error or
    /// the timeout before the report keeps the marker for the next launch. If a strong play (`play(haptic:strength:)`)
    /// may not have restored the normal strength yet, it is written too.
    ///
    /// It blocks the main thread for at most about `timeout` (plus one report write already under way). The releases
    /// go straight to the transport's synchronous `send`, not through the channel: awaiting the channel would need
    /// this method to suspend, and the app terminates as soon as `applicationWillTerminate` returns. Blocking on a
    /// semaphore instead would deadlock whenever the work it waits for needs the main actor. Each receiver's write gate
    /// is closed first, so a divert the channel is about to send can no longer overtake the release; a write already
    /// in progress finishes before the gate closes.
    public func releaseAllSync(timeout: Duration = .milliseconds(100)) {
        let deadline = ContinuousClock.now + timeout
        terminated = true
        wantedCIDs = []
        wantedWatch = []
        wantsThumbWheel = false
        wantsHiRes = false
        wantedWheelMode = nil
        watching = []
        reapplyTask?.cancel()
        reapplyTask = nil
        setupTask?.cancel()
        setupTask = nil
        cancelWriter()
        hiResRetryTask?.cancel()
        hiResRetryTask = nil
        hiResRestTask?.cancel()
        hiResRestTask = nil
        wheelModeRestTask?.cancel()
        wheelModeRestTask = nil
        wheelModeRetryTask?.cancel()
        wheelModeRetryTask = nil
        endWheelModeHold()
        hapticSlot = LatestOnly()
        for link in links.values { link.gate.close() }
        releaseHeld()

        guard var session, let features = session.features else { return }
        let softwareID = session.link.channel.softwareID
        var reports = session.divertedInMouse.sorted(by: Self.byRawValue).map { cid in
            HIDPPReport.short(device: session.device, feature: features.reprog, function: ReprogFunction.setReporting,
                              softwareID: softwareID, params: ReprogControls.divertParams(cid, divert: false))
        }
        if session.wheelDivertedInMouse, let wheel = features.wheel {
            reports.append(.short(device: session.device, feature: wheel.index, function: WheelFunction.setReporting,
                                  softwareID: softwareID, params: ThumbWheel.reportingParams(divert: false)))
        }
        reports += session.watchedInMouse.sorted(by: Self.byRawValue).map { cid in
            HIDPPReport.long(device: session.device, feature: features.reprog, function: ReprogFunction.setReporting,
                             softwareID: softwareID, params: ReprogControls.watchParams(cid, watch: false))
        }
        if hiResMarker.isSet, session.connected, let hiRes = features.hiRes, let mode = session.hiResMode {
            reports.append(.short(device: session.device, feature: hiRes.index, function: HiResWheel.setMode,
                                  softwareID: softwareID, params: [mode & ~HiResWheel.highResolution]))
        }
        var giveBack: HIDPPReport?
        if let saved = wheelModeMarker.saved, session.connected, let smartShift = features.smartShift {
            let report = HIDPPReport.short(device: session.device, feature: smartShift.index,
                                           function: SmartShift.writeMode, softwareID: softwareID,
                                           params: SmartShift.writeParams(saved))
            giveBack = report
            reports.append(report)
        }
        // A strong play whose normal strength may not have gone out: sent last, after the releases.
        if strengthMayBeOff, session.connected, let haptic = features.haptic, let normal = normalStrength {
            reports.append(.short(device: session.device, feature: haptic, function: HapticFunction.setConfig,
                                  softwareID: softwareID, params: Haptics.setConfigParams(strength: normal)))
            strengthMayBeOff = false
        }
        session.divertedInMouse = []
        session.watchedInMouse = []
        session.wheelDivertedInMouse = false
        self.session = session
        for report in reports {
            guard ContinuousClock.now < deadline else {
                log.error("releaseAllSync: timeout before \(report.description, privacy: .public)")
                break
            }
            do {
                try session.link.gate.base.send(report)
                if report == giveBack { wheelModeMarker.saved = nil }   // sent: the next launch gives nothing back
            } catch {
                log.error("releaseAllSync: \(String(describing: error), privacy: .public)")
            }
        }
    }

    /// Plays a haptic pattern, without waiting for the mouse. At most one command is in flight; while it is, newer
    /// patterns replace each other and the newest is sent next. Does nothing while inactive, without a connected mouse
    /// or with haptics switched off on the mouse.
    ///
    /// `strength` (0…100, clamped) other than the normal one (the app's `setHapticStrength`, else the mouse's) makes it
    /// a block of three commands: write `strength`, play, write the normal strength. A newer play replaces a block not
    /// yet started; a started block always ends with the normal strength, even if the app is deactivated meanwhile (the
    /// pattern is then skipped). The strength and the pattern are posted back to back; no play waits for a reply.
    /// While a setup runs (it reads the strength) a block waits. nil or the normal strength: a plain play.
    public func play(haptic pattern: HapticPattern, strength: UInt8? = nil) {
        guard hapticTarget != nil else { return }
        if let strength = strength.map({ min($0, 100) }), let normal = normalStrength, strength != normal {
            hapticSlot.put(.block(pattern, strength: strength))
        } else {
            hapticSlot.put(.play(pattern))
        }
        pumpLane()
    }

    /// Sets the mouse's normal haptic strength (0…100, clamped): written now if the mouse is set up, else at setup,
    /// and again after every reconnect; strong plays return to it. Not written while the mouse's haptics are off.
    public func setHapticStrength(_ strength: UInt8) {
        appStrength = min(strength, 100)
        guard !terminated else { return }
        strengthWritePending = true
        pumpLane()
    }

    /// Sets how hard the haptic panel must be pressed (Logitech's units; the MX Master 4 takes 3799…6316, default
    /// 4749), clamped to the mouse's range: written now if the mouse is set up, else at setup, and again after every
    /// reconnect. Does nothing (but log) when the mouse's panel force is not changeable.
    public func setPanelForce(_ value: UInt16) {
        appPanelForce = value
        guard !terminated else { return }
        forceWritePending = true
        pumpLane()
    }

    /// Whether the app is in the foreground (see the foreground rule above). `follow(app:)` calls it for AppKit apps;
    /// call it yourself without `NSApplication` (e.g. a command-line tool: `setActive(true)` once). Inactive at start.
    public func setActive(_ active: Bool) {
        guard active != self.active, !terminated else { return }
        self.active = active
        reapplyTask?.cancel()
        reapplyTask = nil
        if active {
            // While inactive nothing of the mouse is heard (a SmartShift press in another app changes its mode
            // unseen): the first pass reads both wheel modes before it writes (after a rest, if one runs).
            if session?.features?.hiRes != nil { hiResReadPending = true }
            if session?.features?.smartShift != nil { wheelModeReadPending = true }
            requestSync()
            scheduleReapply()
        } else {
            hapticSlot = LatestOnly()
            watching = []   // the writer switches the analytics off; nothing is heard from now on
            endWheelModeHold()
            releaseHeld()
            requestSync()
            // A strong play whose restore failed: write the normal strength (a running block writes it itself).
            if strengthMayBeOff && !blockRunning {
                strengthWritePending = true
                pumpLane()
            }
        }
    }

    /// Call when the Mac wakes from sleep (`follow(app:)` does it): makes sure every receiver reports links again
    /// (see "Receiver notifications" above), looks for the mouse if none is bound, and, while active, sends the wanted
    /// state again (now and 300 ms later; diverts are harmless to repeat), reading the hi-res and SmartShift wheel
    /// modes first.
    public func systemDidWake() {
        guard started, !terminated else { return }
        for link in links.values { enableReceiverNotifications(on: link) }
        if session?.preferred != true { search(links.keys.sorted().map { .discover(link: $0) }) }
        if active {
            if session?.features?.hiRes != nil { hiResReadPending = true }   // after a rest, if one runs
            if session?.features?.smartShift != nil { wheelModeReadPending = true }
            requestSync()
            scheduleReapply()
        }
    }

    // MARK: - Receivers

    private func attach(_ transport: any HIDPPTransport) {
        guard !terminated else { return }
        nextLinkID += 1
        let gate = TransportGate(transport)
        let channel = HIDPPChannel(transport: gate, timeout: requestTimeout, softwareID: softwareID)
        let link = Link(id: nextLinkID, gate: gate, channel: channel)
        links[link.id] = link
        let notifications = link.channel.notifications   // subscribed before the first request
        lifetime.add(Task { [weak self] in
            for await notification in notifications { self?.handle(notification, from: link) }
            self?.detach(link)
        })
        enableReceiverNotifications(on: link)
        if session?.preferred != true { search([.discover(link: link.id)]) }
    }

    /// Sets the receiver's wireless-notification flag if it is clear (beside the search, which does not wait for it).
    private func enableReceiverNotifications(on link: Link) {
        lifetime.add(Task { await ReceiverNotifications.enable(on: link.channel) })
    }

    /// The receiver went away; its channel has ended.
    private func detach(_ link: Link) {
        links[link.id] = nil
        guard session?.link.id == link.id else { return }
        unbind()
        search(links.keys.sorted().map { .discover(link: $0) })
    }

    private func handle(_ notification: HIDPPNotification, from link: Link) {
        switch notification {
        case .connection(let device, let linked):
            guard !terminated else { return }
            if let session, session.link.id == link.id, session.device == device {
                if linked {
                    startConfigure(forget: true)
                } else {
                    markDisconnected()
                }
            } else if linked, session?.preferred != true {
                search([.probe(link: link.id, slot: device)])
            }
        case .feature(let device, let featureIndex, let function, let params, let time):
            guard active, let session, session.connected, session.link.id == link.id,
                  session.device == device, let features = session.features else { return }
            if featureIndex == features.reprog {
                if function == 0 {
                    lastPressed = ReprogControls.pressed(from: params)
                    emit(tracker.update(lastPressed.filter(wantedCIDs.contains), at: time))
                } else if function == 2 {
                    let keyEvents = ReprogControls.keyEvents(from: params)
                    handleKeyEvents(keyEvents, watchable: features.watchable, at: time)
                    // The mouse switches its wheel mode on the press: nothing is written while the button is down,
                    // and the mode is read once it is up.
                    if !smartShiftWatch(features).isEmpty {
                        for event in keyEvents where event.cid == .smartShift {
                            if event.pressed { smartShiftPressed() } else { smartShiftReleased() }
                        }
                    }
                }
            } else if function == 0, featureIndex == features.wheel?.index, wantsThumbWheel,
                      let info = features.wheel?.info,
                      let event = ThumbWheel.event(from: params, info: info, at: time) {
                continuation.yield(event)
            }
        }
    }

    /// Turns analytics key events into `.pressed` / `.released` of the watched controls: those the app wants (and the
    /// mouse lists as watchable), nothing else. An event of such a control proves that the mouse has its analytics on,
    /// so it confirms the control into `watching` even if the reply to our request was lost or a re-setup cleared the
    /// set: the app ignores the OS events of `watching` controls, and exactly these controls report here. A press of a
    /// control already held and a release of one not held (its press came before the watch or while inactive) are
    /// dropped.
    private func handleKeyEvents(_ keyEvents: [(cid: CID, pressed: Bool)], watchable: Set<CID>, at time: TimeInterval) {
        let watched = effectiveWatch.intersection(watchable)
        for (cid, pressed) in keyEvents where watched.contains(cid) {
            watching.insert(cid)
            if pressed, !watchHeld.contains(cid) {
                watchHeld.append(cid)
                continuation.yield(.pressed(cid, at: time))
            } else if !pressed, let index = watchHeld.firstIndex(of: cid) {
                watchHeld.remove(at: index)
                continuation.yield(.released(cid, at: time))
            }
        }
    }

    /// The watched controls the app wants: divert wins, so a diverted control is left out.
    private var effectiveWatch: Set<CID> { wantedWatch.subtracting(wantedCIDs) }

    /// The internal watch of the SmartShift button: while a wheel mode is wanted and the mouse has `0x2111`, unless the
    /// app diverts the button.
    private func smartShiftWatch(_ features: Features) -> Set<CID> {
        wantedWheelMode != nil && features.smartShift != nil && !wantedCIDs.contains(.smartShift) ? [.smartShift] : []
    }

    /// After a change of the divert or watch set: held watched controls that are no longer watched get `.released`, and
    /// are no longer `watching` (the app hears them from the OS again or not at all).
    private func dropUnwantedWatched() {
        let watched = effectiveWatch
        emit(watchHeld.filter { !watched.contains($0) }.map { .released($0, at: Self.now) })
        watchHeld.removeAll { !watched.contains($0) }
        watching.formIntersection(watched)
    }

    // MARK: - Setup

    /// Adds work to the search and starts it if it is not running. A running search is never cancelled: a connection
    /// notice that arrives meanwhile becomes one more item.
    private func search(_ items: [SearchItem]) {
        guard !terminated, !items.isEmpty else { return }
        for item in items where !searchQueue.contains(item) { searchQueue.append(item) }
        if searchTask == nil { searchTask = Task { await self.runSearch() } }
    }

    /// Works through the queue until a qualifying device is bound. A probed slot without one makes its receiver
    /// discovered in full (once per run). When the queue runs dry with nothing bound, the first device seen with
    /// REPROG_CONTROLS_V4 alone is bound as a fallback.
    private func runSearch() async {
        var fallback: (link: Link, device: UInt8)?
        var discovered: Set<Int> = []
        while !searchQueue.isEmpty {
            let item = searchQueue.removeFirst()
            guard !terminated, session?.preferred != true else { break }
            let link: Link
            let devices: [UInt8]
            var probing = false
            switch item {
            case .discover(let id):
                guard let found = links[id] else { continue }
                link = found
                discovered.insert(id)
                devices = await link.channel.discover()
            case .probe(let id, let slot):
                guard let found = links[id] else { continue }
                link = found
                devices = [slot]
                probing = true
            }
            for device in devices {
                // A probed slot may hold another device than before: its cached indices are dropped first.
                let kind = await Self.kind(of: device, on: link.channel, forget: probing)
                guard !terminated, session?.preferred != true, links[link.id] != nil else { break }
                if kind == .qualifying {
                    bind(link, device, qualifying: true)
                    break
                }
                if kind == .fallback, fallback == nil { fallback = (link, device) }
            }
            if probing, session?.preferred != true, !discovered.contains(link.id),
               !searchQueue.contains(.discover(link: link.id)) {
                searchQueue.append(.discover(link: link.id))
            }
        }
        searchQueue = []
        searchTask = nil
        if !terminated, session == nil, let fallback, links[fallback.link.id] != nil {
            bind(fallback.link, fallback.device, qualifying: false)
        }
    }

    private nonisolated static func kind(of device: UInt8, on channel: HIDPPChannel, forget: Bool) async -> DeviceKind {
        if forget { await channel.forget(device: device) }
        guard (try? await channel.featureIndex(ReprogControls.featureID, device: device)) != nil else { return .none }
        if (try? await channel.featureIndex(Haptics.featureID, device: device)) != nil { return .qualifying }
        if (try? await channel.featureIndex(ThumbWheel.featureID, device: device)) != nil { return .qualifying }
        return .fallback
    }

    /// Binds to `device` (dropping a fallback binding first) and sets it up.
    private func bind(_ link: Link, _ device: UInt8, qualifying: Bool) {
        if session != nil { unbind() }
        session = Session(link: link, device: device, preferred: qualifying)
        startConfigure(forget: false)
    }

    /// Cancels the setup and writes under way and sets the bound mouse up anew. Until it is done the writer stays idle
    /// (`settingUp`): the features it would use may be stale.
    private func startConfigure(forget: Bool) {
        guard session != nil else { return }
        setupTask?.cancel()
        cancelWriter()
        hiResRetryTask?.cancel()   // setup reads the mode again
        hiResRetryTask = nil
        wheelModeRetryTask?.cancel()
        wheelModeRetryTask = nil
        epoch += 1
        let epoch = epoch
        session?.settingUp = true
        watching = []   // a mouse that relinked has forgotten it; the writer confirms it anew after setup
        strengthUnsureDuringSetup = strengthMayBeOff
        setupTask = Task { await self.configure(forget: forget, epoch: epoch) }
    }

    /// Reads the bound mouse's features, releases leftovers (once per `start()`) and marks it connected. A failure is
    /// retried after `setupRetryDelay`, at most `setupAttempts` times in all.
    private func configure(forget: Bool, epoch: Int) async {
        guard let bound = session else { return }
        var forget = forget
        for attempt in 1...Self.setupAttempts {
            do {
                let features = try await Self.readFeatures(bound.link.channel, device: bound.device, forget: forget)
                guard self.epoch == epoch else { return }
                if !leftoversReleased {
                    await releaseLeftovers(features, on: bound)
                    guard self.epoch == epoch else { return }
                    // A fallback device (a keyboard) does not use up the release: the mouse may still be found.
                    if bound.preferred { leftoversReleased = true }
                }
                finishSetup(features)
                return
            } catch HIDPPError.featureMissing(ReprogControls.featureID) {
                guard self.epoch == epoch else { return }
                log.info("device \(bound.device) has no REPROG_CONTROLS_V4 any more: unbinding")
                unbind()
                return
            } catch {
                guard self.epoch == epoch else { return }
                log.error("setup of device \(bound.device) failed (attempt \(attempt)): \(String(describing: error), privacy: .public)")
                guard attempt < Self.setupAttempts else {
                    // Writes resume with what was read before (if anything). State changes made during the attempts
                    // were not written (`requestSync` waits while `settingUp`): write them now.
                    session?.settingUp = false
                    requestSync()
                    if active { scheduleReapply() }
                    pumpLane()
                    return
                }
                do { try await clock.sleeper(for: Self.setupRetryDelay)() } catch { return }
                guard self.epoch == epoch else { return }
                forget = true
            }
        }
    }

    /// Releases the wanted controls and the wheel (if wanted) before anything is diverted, and switches off the
    /// analytics of the watched ones: a crashed previous run may have left them on. Failures are logged and ignored.
    private func releaseLeftovers(_ features: Features, on bound: Session) async {
        for cid in wantedCIDs.intersection(features.divertable).sorted(by: Self.byRawValue) {
            await Self.setReporting(cid, divert: false, on: bound)
        }
        if wantsThumbWheel, features.wheel != nil {
            await Self.write(bound.link.channel, ThumbWheel.featureID, device: bound.device,
                             function: WheelFunction.setReporting, params: ThumbWheel.reportingParams(divert: false))
        }
        for cid in wantedWatch.intersection(features.watchable).sorted(by: Self.byRawValue) {
            await Self.setWatching(cid, watch: false, on: bound)
        }
    }

    private func finishSetup(_ features: Features) {
        guard var session else { return }
        let wasConnected = session.connected
        session.features = features
        session.connected = true
        session.settingUp = false
        if !wasConnected {
            session.divertedInMouse = []   // a mouse that (re)linked has forgotten every divert
            session.watchedInMouse = []
            session.wheelDivertedInMouse = false
        }
        // A re-setup of a connected mouse (a second "linked" notice) keeps what may be diverted: the mouse may not have
        // reset, and a release of a control that is not diverted is harmless.
        self.session = session
        isConnected = true
        controls = features.controls
        if let info = features.wheel?.info, info.divertedResolution > 0 {
            stepsPerRevolution = info.divertedResolution
        } else {
            stepsPerRevolution = nil
        }
        // A strength read while the mouse may have had a strong one (a restore owed when setup began, or a block
        // since) may be the strong one: the known normal one stays.
        let strengthUnsure = strengthUnsureDuringSetup || strengthMayBeOff
        if !(strengthUnsure && hapticStrength != nil) { hapticStrength = features.hapticStrength }
        panelForce = features.force.map { ($0.current, $0.info) }
        strengthWritePending = appStrength != nil || strengthMayBeOff
        forceWritePending = appPanelForce != nil
        if !wasConnected { continuation.yield(.connected) }
        hiResReadPending = false   // just read (a running rest still ends with a read)
        noteHiResMode(features.hiRes?.mode)
        if let hiRes = features.hiRes, hiRes.mode == nil {
            // The setup's read failed: read again before anything is written (the off-write of a leftover needs the
            // mode too). A timed-out read rests first, as its tombstone would swallow the next reply.
            if hiRes.readTimedOut { startHiResRest() } else { hiResReadPending = true }
        }
        wheelModeReadPending = false   // the same for the SmartShift mode
        noteWheelMode(features.smartShift?.mode)
        if let smartShift = features.smartShift, smartShift.mode == nil {
            if smartShift.readTimedOut { startWheelModeRest() } else { wheelModeReadPending = true }
        }
        requestSync()
        if active { scheduleReapply() }
        pumpLane()
    }

    /// The mouse lost its link or its receiver: stop setup and writes, release held controls, then `.disconnected`.
    private func markDisconnected() {
        setupTask?.cancel()
        setupTask = nil
        cancelWriter()
        hiResRetryTask?.cancel()   // the next setup reads the mode again
        hiResRetryTask = nil
        wheelModeRetryTask?.cancel()
        wheelModeRetryTask = nil
        endWheelModeHold()
        epoch += 1
        hapticSlot = LatestOnly()
        guard var session else { return }
        let wasConnected = session.connected
        session.connected = false
        session.settingUp = false
        session.divertedInMouse = []
        session.watchedInMouse = []
        session.wheelDivertedInMouse = false
        self.session = session
        watching = []
        guard wasConnected else { return }
        isConnected = false
        releaseHeld()
        updateHighResolution()
        updateWheelMode()
        continuation.yield(.disconnected)
    }

    /// Forgets the bound mouse (its receiver went away, or another device took its slot).
    private func unbind() {
        markDisconnected()
        hiResRestTask?.cancel()   // the channel and its tombstones go with the binding (or the next is another mouse)
        hiResRestTask = nil
        wheelModeRestTask?.cancel()
        wheelModeRestTask = nil
        wheelModeButtonReadPending = false   // a press of this mouse: the next binding may be another
        session = nil
        controls = []
        stepsPerRevolution = nil
        panelForce = nil
        // An owed restore belongs to this binding: the next one may be another mouse, which is never written unasked.
        hapticStrength = nil
        strengthMayBeOff = false
        strengthSerial += 1   // a late confirmation of a write to this mouse counts for nothing
    }

    private nonisolated static func readFeatures(_ channel: HIDPPChannel, device: UInt8,
                                                 forget: Bool) async throws -> Features {
        if forget { await channel.forget(device: device) }
        let reprog = try await channel.featureIndex(ReprogControls.featureID, device: device)
        let count = try await channel.call(ReprogControls.featureID, device: device, function: ReprogFunction.count)[0]
        var controls: [Control] = []
        for index in 0..<count {
            let info = try await channel.call(ReprogControls.featureID, device: device,
                                              function: ReprogFunction.controlInfo, params: [index])
            controls.append(ReprogControls.control(fromInfo: info))
        }
        var wheel: (index: UInt8, info: ThumbWheel.Info)?
        do {
            let index = try await channel.featureIndex(ThumbWheel.featureID, device: device)
            let info = try await channel.call(ThumbWheel.featureID, device: device, function: WheelFunction.info)
            wheel = (index, ThumbWheel.info(from: info))
        } catch {
            // Missing or unreadable: no thumb wheel this time (the controls are what setup needs).
            if error as? HIDPPError != .featureMissing(ThumbWheel.featureID) {
                log.error("thumb wheel unreadable: \(String(describing: error), privacy: .public)")
            }
        }
        var haptic: UInt8?
        var hapticsEnabled = false
        var hapticStrength: UInt8?
        do {
            haptic = try await channel.featureIndex(Haptics.featureID, device: device)
            let config = Haptics.config(from: try await channel.call(Haptics.featureID, device: device,
                                                                     function: HapticFunction.config))
            hapticsEnabled = config.enabled
            hapticStrength = config.intensity
        } catch {
            haptic = nil   // missing or unreadable: no haptics this time
            if error as? HIDPPError != .featureMissing(Haptics.featureID) {
                log.error("haptic config unreadable: \(String(describing: error), privacy: .public)")
            }
        }
        var force: ForceFeature?
        do {
            let index = try await channel.featureIndex(ForceSensing.featureID, device: device)
            let count = try await channel.call(ForceSensing.featureID, device: device, function: ForceFunction.count)[0]
            if count > 0 {
                let info = try await channel.call(ForceSensing.featureID, device: device, function: ForceFunction.info,
                                                  params: [ForceFunction.panelButton])
                let current = try await channel.call(ForceSensing.featureID, device: device,
                                                     function: ForceFunction.current,
                                                     params: [ForceFunction.panelButton])
                if let info = ForceSensing.info(from: info), let current = ForceSensing.current(from: current) {
                    force = ForceFeature(index: index, info: info, current: current)
                } else {
                    log.error("panel force: unexpected reply \(info, privacy: .public) \(current, privacy: .public)")
                }
            }
        } catch {
            // Missing or unreadable: no panel force this time.
            if error as? HIDPPError != .featureMissing(ForceSensing.featureID) {
                log.error("panel force unreadable: \(String(describing: error), privacy: .public)")
            }
        }
        var hiRes: HiResFeature?
        do {
            let index = try await channel.featureIndex(HiResWheel.featureID, device: device)
            do {
                hiRes = HiResFeature(index: index, mode: try await readHiResMode(channel, device: device),
                                     readTimedOut: false)
            } catch {
                // Unreadable this time: the wheel is kept with an unknown mode (nothing is written until a read
                // succeeds); `finishSetup` has it read again, after the rest if the read timed out.
                log.error("hi-res wheel mode unreadable: \(String(describing: error), privacy: .public)")
                hiRes = HiResFeature(index: index, mode: nil, readTimedOut: error as? HIDPPError == .timeout)
            }
        } catch {
            // Missing, or its index unreadable: no hi-res wheel this time (the next setup looks again).
            if error as? HIDPPError != .featureMissing(HiResWheel.featureID) {
                log.error("hi-res wheel unreadable: \(String(describing: error), privacy: .public)")
            }
        }
        var smartShift: SmartShiftFeature?
        do {
            let index = try await channel.featureIndex(SmartShift.featureID, device: device)
            do {
                smartShift = SmartShiftFeature(index: index, mode: try await readWheelMode(channel, device: device),
                                               readTimedOut: false)
            } catch {
                // Unreadable this time: kept with an unknown mode, read again, as for the hi-res wheel.
                log.error("SmartShift mode unreadable: \(String(describing: error), privacy: .public)")
                smartShift = SmartShiftFeature(index: index, mode: nil, readTimedOut: error as? HIDPPError == .timeout)
            }
        } catch {
            // Missing, or its index unreadable: no SmartShift this time (the next setup looks again).
            if error as? HIDPPError != .featureMissing(SmartShift.featureID) {
                log.error("SmartShift unreadable: \(String(describing: error), privacy: .public)")
            }
        }
        return Features(reprog: reprog, controls: controls, wheel: wheel.map { WheelFeature(index: $0.index, info: $0.info) },
                        haptic: haptic, hapticsEnabled: hapticsEnabled, hapticStrength: hapticStrength, force: force,
                        hiRes: hiRes, smartShift: smartShift)
    }

    /// getWheelMode of `0x2121`: the mode byte.
    private nonisolated static func readHiResMode(_ channel: HIDPPChannel, device: UInt8) async throws -> UInt8 {
        let reply = try await channel.call(HiResWheel.featureID, device: device, function: HiResWheel.getMode)
        return reply[0]
    }

    /// The SmartShift mode (`0x2111` function 1, the reply's first byte); a mode other than free spin or ratchet is
    /// unreadable.
    private nonisolated static func readWheelMode(_ channel: HIDPPChannel, device: UInt8) async throws -> WheelMode {
        let reply = try await channel.call(SmartShift.featureID, device: device, function: SmartShift.readMode)
        guard let mode = WheelMode(rawValue: reply[0]) else { throw UnknownWheelMode(byte: reply[0]) }
        return mode
    }

    // MARK: - Writing the wanted state

    /// Makes the writer bring the mouse to the current wanted state (diverts are always sent again: another app may
    /// have released them). Does nothing without a connected mouse; setup calls it when done.
    private func requestSync() {
        guard !terminated, session?.connected == true, session?.settingUp == false else { return }
        syncPending = true
        guard writer == nil else { return }
        nextWriterID += 1
        let id = nextWriterID
        writer = (id, Task { await self.runWriter(id: id) })
    }

    private func cancelWriter() {
        writer?.task.cancel()
        writer = nil
        syncPending = false
    }

    private func runWriter(id: Int) async {
        defer { if writer?.id == id { writer = nil } }
        while syncPending, !Task.isCancelled {
            syncPending = false
            await writeWantedState()
        }
    }

    /// One pass: releases what should no longer be diverted or watched, then diverts and watches what should be.
    /// Stops early when the state changes meanwhile (the writer then starts a new pass) or the connection changes.
    ///
    /// The hi-res wheel is written only when its mode differs from the target: on (the bit `0x02` added to the last
    /// mode read) while active, wanted and not the user's own; off (the bit removed) while this app's marker is set.
    /// A pending read (recheck, wake, the end of a rest) comes first. While the wheel rests nothing of it is sent.
    ///
    /// The SmartShift mode works the same way: the wanted mode is written (after the diverts) while active, when the
    /// known mode differs; with none wanted, the mode saved in the marker is given back (before the diverts) when the
    /// known mode differs, and the marker is cleared at once when it does not. The SmartShift button is watched beside
    /// the app's controls while a mode is wanted (`smartShiftWatch`); while it is down no SmartShift write is sent, and
    /// a read then or after its release is a by-button read.
    private func writeWantedState() async {
        let epoch = epoch
        if hiResReadPending, hiResRestTask == nil, let bound = session, bound.connected, bound.features?.hiRes != nil {
            hiResReadPending = false
            do {
                let mode = try await Self.readHiResMode(bound.link.channel, device: bound.device)
                guard self.epoch == epoch, !Task.isCancelled else { return }
                noteHiResMode(mode)
            } catch {
                log.error("hi-res wheel mode unreadable: \(String(describing: error), privacy: .public)")
                guard self.epoch == epoch, !Task.isCancelled else { return }
                if error as? HIDPPError == .timeout { startHiResRest() }
            }
        }
        if wheelModeReadPending || wheelModeButtonReadPending, wheelModeRestTask == nil, let bound = session,
           bound.connected, bound.features?.smartShift != nil {
            let byButton = wheelModeButtonReadPending
            wheelModeReadPending = false
            wheelModeButtonReadPending = false
            do {
                let mode = try await Self.readWheelMode(bound.link.channel, device: bound.device)
                guard self.epoch == epoch, !Task.isCancelled else { return }
                // A read while the button is down (a recheck) sees the mode the press switched to: a press read too.
                if byButton || wheelModeButtonHeld { wheelModeReadAfterPress(mode) } else { noteWheelMode(mode) }
            } catch {
                log.error("SmartShift mode unreadable: \(String(describing: error), privacy: .public)")
                guard self.epoch == epoch, !Task.isCancelled else { return }
                if error as? HIDPPError == .timeout { startWheelModeRest() }
            }
        }
        guard let session, session.connected, let features = session.features else { return }
        // A fallback binding (a keyboard) is never diverted: its keys would go dead in every app while this one is active.
        // It is not watched either (the same rule, though a watch would be harmless).
        let diverting = active && session.preferred
        let target = diverting ? wantedCIDs.intersection(features.divertable) : []
        let watched = effectiveWatch.union(smartShiftWatch(features))
        let watchTarget = diverting ? watched.intersection(features.watchable) : []
        let wheelTarget = diverting && wantsThumbWheel && features.wheel != nil
        let hiResFree = features.hiRes != nil && hiResRestTask == nil   // resting: no hi-res request in either direction
        let hiResTarget = diverting && wantsHiRes && features.hiRes != nil && !session.hiResUsersOwn
        let hiResOn = (session.hiResMode ?? 0) & HiResWheel.highResolution != 0
        // Resting: no SmartShift request; the button down: no SmartShift write (it would undo the press).
        let wheelModeFree = features.smartShift != nil && wheelModeRestTask == nil && !wheelModeButtonHeld
        let wheelModeTarget = diverting && features.smartShift != nil ? wantedWheelMode : nil
        var steps: [WriteStep] = []
        steps += session.divertedInMouse.subtracting(target).sorted(by: Self.byRawValue).map { .divert($0, on: false) }
        if session.wheelDivertedInMouse && !wheelTarget { steps.append(.wheel(on: false)) }
        if hiResFree && hiResMarker.isSet && !hiResTarget { steps.append(.hiRes(on: false)) }
        if wheelModeFree, wheelModeTarget == nil, let saved = wheelModeMarker.saved {
            if session.wheelMode == saved {
                wheelModeMarker.saved = nil   // the mouse has its own mode already
            } else {
                steps.append(.wheelMode(saved, givingBack: true))
            }
        }
        steps += session.watchedInMouse.subtracting(watchTarget).sorted(by: Self.byRawValue)
            .map { .watch($0, on: false) }
        steps += target.sorted(by: Self.byRawValue).map { .divert($0, on: true) }
        if wheelTarget { steps.append(.wheel(on: true)) }
        if hiResFree && hiResTarget && !hiResOn { steps.append(.hiRes(on: true)) }
        if wheelModeFree, let wheelModeTarget, let known = session.wheelMode, known != wheelModeTarget {
            steps.append(.wheelMode(wheelModeTarget, givingBack: false))
        }
        steps += watchTarget.sorted(by: Self.byRawValue).map { .watch($0, on: true) }

        for step in steps {
            guard self.epoch == epoch, !syncPending, !Task.isCancelled, self.session != nil else { return }
            // Counted as diverted before the divert is sent, and no longer once its release has returned: a
            // `releaseAllSync` in between sends the release again (harmless) instead of leaving the control diverted.
            // Watching works the same way, and a watch counts as `watching` only once the mouse has answered.
            switch step {
            case .divert(let cid, let on):
                if on { self.session?.divertedInMouse.insert(cid) }
                await Self.setReporting(cid, divert: on, on: session)
                if !on, !Task.isCancelled { self.session?.divertedInMouse.remove(cid) }
            case .wheel(let on):
                if on { self.session?.wheelDivertedInMouse = true }
                await Self.write(session.link.channel, ThumbWheel.featureID, device: session.device,
                                 function: WheelFunction.setReporting, params: ThumbWheel.reportingParams(divert: on))
                if !on, !Task.isCancelled { self.session?.wheelDivertedInMouse = false }
            case .hiRes(let on):
                // From the mode as it is now (a recheck may have read it since the pass began). The marker is set
                // before the on-write and cleared only once an off-write is confirmed.
                guard let mode = self.session?.hiResMode else { continue }
                let value = on ? mode | HiResWheel.highResolution : mode & ~HiResWheel.highResolution
                if on { hiResMarker.isSet = true }
                let error = await Self.setHiResMode(value, on: session)
                if self.epoch == epoch, !Task.isCancelled { hiResWritten(value, on: on, error: error) }
            case .wheelMode(let mode, let givingBack):
                // The mouse's own mode is saved before the first write of the app's (from the mode as it is now);
                // the marker is cleared only once a write of the saved mode is confirmed. A press since the pass
                // began skips the write.
                if wheelModeButtonHeld { continue }
                if !givingBack, wheelModeMarker.saved == nil {
                    guard let known = self.session?.wheelMode else { continue }
                    wheelModeMarker.saved = known
                }
                let error = await Self.setWheelMode(mode, on: session)
                if self.epoch == epoch, !Task.isCancelled {
                    wheelModeWritten(mode, givingBack: givingBack, error: error)
                }
            case .watch(let cid, let on):
                if on {
                    self.session?.watchedInMouse.insert(cid)
                } else {
                    self.watching.remove(cid)
                }
                let answered = await Self.setWatching(cid, watch: on, on: session)
                if on {
                    // The app may have been deactivated or changed the set while the request was out.
                    if answered, self.epoch == epoch, active, effectiveWatch.contains(cid) { self.watching.insert(cid) }
                } else if !Task.isCancelled {
                    self.session?.watchedInMouse.remove(cid)
                }
            }
        }
    }

    /// setControlReporting for `cid`. The reply repeats the CID, which is passed as the echo: every divert and release
    /// shares one channel key, and a lost reply's tombstone must not swallow another CID's reply (and so on, each call
    /// timing out in turn).
    private nonisolated static func setReporting(_ cid: CID, divert: Bool, on session: Session) async {
        let params = ReprogControls.divertParams(cid, divert: divert)
        await write(session.link.channel, ReprogControls.featureID, device: session.device,
                    function: ReprogFunction.setReporting, params: params, echo: Array(params.prefix(2)))
    }

    /// setControlReporting for `cid`'s analytics key events (a long report). Like a divert, its reply repeats the CID,
    /// which is passed as the echo. True when it was answered.
    @discardableResult
    private nonisolated static func setWatching(_ cid: CID, watch: Bool, on session: Session) async -> Bool {
        let params = ReprogControls.watchParams(cid, watch: watch)
        return await write(session.link.channel, ReprogControls.featureID, device: session.device,
                           function: ReprogFunction.setReporting, params: params, echo: Array(params.prefix(2)))
    }

    /// One request; a failure is logged (the next activation or link sends the state again). True when it was
    /// answered.
    @discardableResult
    private nonisolated static func write(_ channel: HIDPPChannel, _ feature: UInt16, device: UInt8, function: UInt8,
                                          params: [UInt8], echo: [UInt8]? = nil) async -> Bool {
        do {
            _ = try await channel.call(feature, device: device, function: function, params: params, echo: echo)
            return true
        } catch {
            log.error("feature \(feature, format: .hex) function \(function): \(String(describing: error), privacy: .public)")
            return false
        }
    }

    // MARK: - Hi-res wheel

    /// setWheelMode of `0x2121` with the whole mode byte. Nil when the mouse confirmed it, else the error.
    private nonisolated static func setHiResMode(_ mode: UInt8, on session: Session) async -> (any Error)? {
        do {
            _ = try await session.link.channel.call(HiResWheel.featureID, device: session.device,
                                                    function: HiResWheel.setMode, params: [mode])
            return nil
        } catch {
            return error
        }
    }

    /// A mode read from the mouse (nil: no hi-res wheel, or unreadable). The bit set without the marker is the user's
    /// own setting; the bit clear means nothing of ours is on, so the marker is cleared.
    private func noteHiResMode(_ mode: UInt8?) {
        guard session != nil else { return }
        session?.hiResMode = mode
        session?.hiResUsersOwn = false
        if let mode {
            if mode & HiResWheel.highResolution != 0 {
                session?.hiResUsersOwn = !hiResMarker.isSet
            } else if hiResMarker.isSet {
                givenBack()
            }
        }
        updateHighResolution()
    }

    /// Nothing of this app's high resolution is on any more (a confirmed off-write, or a read without the bit).
    private func givenBack() {
        hiResMarker.isSet = false
        if hiResFailures > 0 {
            log.info("hi-res wheel given back its low resolution after \(self.hiResFailures) failed tries")
        }
        hiResFailures = 0
        hiResRetryTask?.cancel()
        hiResRetryTask = nil
    }

    /// The outcome of a hi-res write on the current connection. A failed on-write leaves the marker set (it may have
    /// got through). A timed-out write, in either direction, starts the rest, which ends with a read of the real mode;
    /// an on-write refused by the mouse is tried again by the next pass, a refused off-write by its own retry.
    private func hiResWritten(_ mode: UInt8, on: Bool, error: (any Error)?) {
        if let error {
            let reason = String(describing: error)
            if on {
                log.error("hi-res wheel not turned on: \(reason, privacy: .public)")
            } else {
                hiResFailures += 1
                if hiResFailures == 1 {
                    log.error("hi-res wheel not given back its low resolution (\(reason, privacy: .public)); retrying")
                }
            }
            if error as? HIDPPError == .timeout {
                startHiResRest()
            } else if !on {
                scheduleHiResRetry()
            }
            return
        }
        session?.hiResMode = mode
        if on {
            hiResFailures = 0   // nothing is owed any more
            hiResRetryTask?.cancel()
            hiResRetryTask = nil
        } else {
            givenBack()
        }
        updateHighResolution()
    }

    /// Starts the rest after a timed-out `0x2121` request: no hi-res request until `hiResRestDelay` from now, then a
    /// writer pass that reads the mode first and writes what the real mode needs.
    private func startHiResRest() {
        hiResRetryTask?.cancel()
        hiResRetryTask = nil
        hiResRestTask?.cancel()
        let sleep = clock.sleeper(for: Self.hiResRestDelay)
        hiResRestTask = Task { [weak self] in
            do { try await sleep() } catch { return }
            guard let self, !Task.isCancelled else { return }
            self.hiResRestTask = nil
            self.hiResReadPending = true
            self.requestSync()
        }
    }

    /// Another writer pass after `hiResRetryDelay` (replacing a pending retry): it sends the off-write again while it is
    /// owed.
    private func scheduleHiResRetry() {
        hiResRetryTask?.cancel()
        let sleep = clock.sleeper(for: Self.hiResRetryDelay)
        hiResRetryTask = Task { [weak self] in
            do { try await sleep() } catch { return }
            guard let self, !Task.isCancelled else { return }
            self.hiResRetryTask = nil
            self.requestSync()
        }
    }

    /// Sets `isHighResolution` from the connected mouse's mode and reports a change.
    private func updateHighResolution() {
        let on = session.map {
            $0.connected && $0.features?.hiRes != nil && ($0.hiResMode ?? 0) & HiResWheel.highResolution != 0
        } ?? false
        guard on != isHighResolution else { return }
        isHighResolution = on
        continuation.yield(.highResolutionWheel(on))
    }

    // MARK: - SmartShift

    /// Function 2 of `0x2111` with `mode` (threshold and torque kept). The reply repeats the mode, which is passed as
    /// the echo, as for a divert: a lost reply's tombstone cannot swallow the reply to a write of the other mode. Nil
    /// when the mouse confirmed it, else the error.
    private nonisolated static func setWheelMode(_ mode: WheelMode, on session: Session) async -> (any Error)? {
        do {
            _ = try await session.link.channel.call(SmartShift.featureID, device: session.device,
                                                    function: SmartShift.writeMode,
                                                    params: SmartShift.writeParams(mode), echo: [mode.rawValue])
            return nil
        } catch {
            return error
        }
    }

    /// A mode read from the mouse or confirmed written (nil: no SmartShift, or unreadable).
    private func noteWheelMode(_ mode: WheelMode?, byButton: Bool = false) {
        guard session != nil else { return }
        session?.wheelMode = mode
        updateWheelMode(byButton: byButton)
    }

    /// The mode read after a press of the SmartShift button (after its release, or while it is down). While the app's
    /// mode is applied (active, a mode wanted), a mode other than the wanted one is the user's choice: it becomes the
    /// wanted mode, so nothing is written back, and the read is reported `byButton` (even unchanged: two presses may
    /// have come back to it, or a read while the button was down adopted it already). With the marker clear (no write
    /// of the app's mode yet), the mode the mouse had before the press is its own: it is saved first, so deactivation
    /// gives it back — the known mode, or, when a read since the press already noted the new one, the other mode (the
    /// wanted one: a press toggles). Otherwise (the app was deactivated or gave the mode back meanwhile) the mode is
    /// only noted.
    private func wheelModeReadAfterPress(_ mode: WheelMode) {
        guard let session, active, session.preferred, let wanted = wantedWheelMode else {
            noteWheelMode(mode)
            return
        }
        if mode != wanted {
            if wheelModeMarker.saved == nil {
                if let known = session.wheelMode, known != mode {
                    wheelModeMarker.saved = known
                } else {
                    wheelModeMarker.saved = wanted
                }
            }
            wantedWheelMode = mode
        }
        noteWheelMode(mode, byButton: true)
    }

    /// The internal watch heard the SmartShift button go down: the hold starts (no SmartShift write until it ends),
    /// and ends by itself `smartShiftHoldLimit` from now as if released.
    private func smartShiftPressed() {
        wheelModeButtonHeld = true
        wheelModeHoldTask?.cancel()
        let sleep = clock.sleeper(for: Self.smartShiftHoldLimit)
        wheelModeHoldTask = Task { [weak self] in
            do { try await sleep() } catch { return }
            guard let self, !Task.isCancelled else { return }
            self.wheelModeHoldTask = nil
            self.smartShiftReleased()
        }
    }

    /// The SmartShift button is up (or its release never came): the hold ends and the mode is read, as a by-button
    /// read.
    private func smartShiftReleased() {
        endWheelModeHold()
        wheelModeButtonReadPending = true
        requestSync()
    }

    /// Ends a hold of the SmartShift button without a read (deactivation, a disconnect, exit).
    private func endWheelModeHold() {
        wheelModeButtonHeld = false
        wheelModeHoldTask?.cancel()
        wheelModeHoldTask = nil
    }

    /// The outcome of a SmartShift write on the current connection. A failed write changes nothing known (the marker
    /// stays: a write of the app's mode may have got through); a timed-out one starts the rest, which ends with a read
    /// of the real mode; a refused write of the app's mode is tried again by the next pass, a refused give-back by its
    /// own retry (`wheelModeRetryDelay`), while it is owed. A confirmed give-back clears the marker.
    private func wheelModeWritten(_ mode: WheelMode, givingBack: Bool, error: (any Error)?) {
        if let error {
            let reason = String(describing: error)
            if givingBack {
                wheelModeFailures += 1
                if wheelModeFailures == 1 {
                    log.error("SmartShift mode \(mode.rawValue) not given back (\(reason, privacy: .public)); retrying")
                }
            } else {
                log.error("SmartShift mode \(mode.rawValue) not written: \(reason, privacy: .public)")
            }
            if error as? HIDPPError == .timeout {
                startWheelModeRest()
            } else if givingBack {
                scheduleWheelModeRetry()
            }
            return
        }
        if givingBack, wheelModeFailures > 0 {
            log.info("SmartShift mode \(mode.rawValue) given back after \(self.wheelModeFailures) failed tries")
        }
        wheelModeFailures = 0
        wheelModeRetryTask?.cancel()   // nothing is owed any more (or the app's mode is in)
        wheelModeRetryTask = nil
        if givingBack, wheelModeMarker.saved == mode { wheelModeMarker.saved = nil }
        noteWheelMode(mode)
    }

    /// Another writer pass after `wheelModeRetryDelay` (replacing a pending retry): it sends the give-back again while
    /// it is owed.
    private func scheduleWheelModeRetry() {
        wheelModeRetryTask?.cancel()
        let sleep = clock.sleeper(for: Self.wheelModeRetryDelay)
        wheelModeRetryTask = Task { [weak self] in
            do { try await sleep() } catch { return }
            guard let self, !Task.isCancelled else { return }
            self.wheelModeRetryTask = nil
            self.requestSync()
        }
    }

    /// Starts the rest after a timed-out `0x2111` request: no SmartShift request until `hiResRestDelay` from now, then
    /// a writer pass that reads the mode first and writes what the real mode needs.
    private func startWheelModeRest() {
        wheelModeRetryTask?.cancel()
        wheelModeRetryTask = nil
        wheelModeRestTask?.cancel()
        let sleep = clock.sleeper(for: Self.hiResRestDelay)
        wheelModeRestTask = Task { [weak self] in
            do { try await sleep() } catch { return }
            guard let self, !Task.isCancelled else { return }
            self.wheelModeRestTask = nil
            self.wheelModeReadPending = true
            self.requestSync()
        }
    }

    /// Sets `wheelMode` from the connected mouse's mode and reports a change to a known mode (a change to nil — a
    /// disconnect, an unbinding, a failed read — has no event); `byButton` reports the mode even unchanged.
    private func updateWheelMode(byButton: Bool = false) {
        let mode = session.flatMap { $0.connected && $0.features?.smartShift != nil ? $0.wheelMode : nil }
        guard mode != wheelMode || byButton else { return }
        wheelMode = mode
        if let mode { continuation.yield(.wheelMode(mode, byButton: byButton)) }
    }

    // MARK: - Haptics

    private var hapticTarget: (channel: HIDPPChannel, device: UInt8, index: UInt8)? {
        guard active, !terminated, let session, session.connected, let features = session.features,
              features.hapticsEnabled, let index = features.haptic else { return nil }
        return (session.link.channel, session.device, index)
    }

    /// The strength a strong play returns to: the app's, else the mouse's.
    private var normalStrength: UInt8? { appStrength ?? hapticStrength }

    /// Starts the lane's next command if it is idle: a pending strength write first, then a panel-force write (both
    /// wait while a setup runs), then the waiting play or strong-play block (only while active, see `hapticTarget`; a
    /// block also waits while a setup runs, in the slot, where a newer play can still replace it).
    ///
    /// No command waits for a reply: the lane moves on as soon as a command is sent (a write's reply is awaited
    /// beside it), so a lost reply never delays a play.
    private func pumpLane() {
        guard !laneBusy else { return }
        guard !terminated, let session, session.connected, let features = session.features else {
            hapticSlot = LatestOnly()
            return
        }
        let channel = session.link.channel, device = session.device, epoch = epoch
        if strengthWritePending, !session.settingUp {
            strengthWritePending = false
            if let index = features.haptic, features.hapticsEnabled, let value = normalStrength {
                runLane { await self.sendNormalStrength(value, on: channel, device: device, index: index) }
                return
            }
            if features.haptic != nil, appStrength != nil {
                log.info("haptics are off in the mouse: the haptic strength is not written")
            }
        }
        if forceWritePending, !session.settingUp {
            forceWritePending = false
            if let wanted = appPanelForce, let force = features.force {
                if force.info.changeable {
                    let value = min(max(wanted, force.info.range.lowerBound), force.info.range.upperBound)
                    runLane {
                        await self.sendPanelForce(value, force: force, on: channel, device: device, epoch: epoch)
                    }
                    return
                }
                log.info("the panel force of this mouse is not changeable: not written")
            } else if appPanelForce != nil {
                log.info("this mouse has no force-sensing button: the panel force is not written")
            }
        }
        guard let target = hapticTarget else {
            hapticSlot = LatestOnly()
            return
        }
        guard let command = hapticSlot.take() else { return }
        switch command {
        case .play(let pattern):
            runLane { await Self.post(pattern, on: target.channel, device: target.device, index: target.index) }
        case .block where session.settingUp:
            // Setup reads the strength: a strong one written now could be taken for the normal one.
            hapticSlot.put(command)
        case .block(let pattern, let strength):
            runLane {
                await self.playBlock(pattern, strength: strength, on: target.channel, device: target.device,
                                     index: target.index)
            }
        }
    }

    /// Runs one lane command; when it returns, the next.
    private func runLane(_ work: @escaping @MainActor () async -> Void) {
        laneBusy = true
        Task {
            await work()
            self.laneBusy = false
            self.pumpLane()
        }
    }

    private nonisolated static func post(_ pattern: HapticPattern, on channel: HIDPPChannel, device: UInt8,
                                         index: UInt8) async {
        await post(.short(device: device, feature: index, function: HapticFunction.play,
                          params: Haptics.playParams(pattern)), on: channel)
    }

    private nonisolated static func post(_ report: HIDPPReport, on channel: HIDPPChannel) async {
        do {
            try await channel.post(report)
        } catch {
            log.error("\(report.description, privacy: .public): \(String(describing: error), privacy: .public)")
        }
    }

    /// A strong play: the strength and the pattern are posted back to back (one link keeps them in order, and the
    /// mouse applies the strength first), then the normal strength is sent, its reply awaited beside the lane. Once
    /// started the block always sends the normal strength (the pattern is skipped if the app was deactivated
    /// meanwhile); until that write is confirmed a restore is owed (`strengthMayBeOff`), which deactivation,
    /// `releaseAllSync` and the next setup settle.
    private func playBlock(_ pattern: HapticPattern, strength: UInt8, on channel: HIDPPChannel, device: UInt8,
                           index: UInt8) async {
        guard !terminated else { return }
        strengthMayBeOff = true
        strengthUnsureDuringSetup = true
        strengthSerial += 1
        blockRunning = true
        defer { blockRunning = false }
        await Self.post(.short(device: device, feature: index, function: HapticFunction.setConfig,
                               params: Haptics.setConfigParams(strength: strength)), on: channel)
        if active, !terminated { await Self.post(pattern, on: channel, device: device, index: index) }
        guard !terminated, let normal = normalStrength else { return }
        await sendNormalStrength(normal, on: channel, device: device, index: index)
    }

    /// Sends the normal strength and returns; its reply is awaited beside the lane. Once confirmed, and if no other
    /// strength was sent since, it is the mouse's `hapticStrength` and no restore is owed.
    private func sendNormalStrength(_ value: UInt8, on channel: HIDPPChannel, device: UInt8, index: UInt8) async {
        strengthSerial += 1
        let serial = strengthSerial
        let params = Haptics.setConfigParams(strength: value)
        let reply = await channel.sendRequest(.short(device: device, feature: index, function: HapticFunction.setConfig,
                                                     params: params), echo: params)
        Task {
            do {
                _ = try await reply.value
            } catch {
                log.error("haptic strength \(value): \(String(describing: error), privacy: .public)")
                return
            }
            guard serial == self.strengthSerial, !self.terminated else { return }
            self.hapticStrength = value
            if value == self.normalStrength { self.strengthMayBeOff = false }   // else another one is written next
        }
    }

    /// Sends the panel force and returns; once confirmed (on the same connection) it is `panelForce.current`.
    private func sendPanelForce(_ value: UInt16, force: ForceFeature, on channel: HIDPPChannel, device: UInt8,
                                epoch: Int) async {
        let reply = await channel.sendRequest(.short(device: device, feature: force.index, function: ForceFunction.set,
                                                     params: ForceSensing.setParams(button: ForceFunction.panelButton,
                                                                                    value: value)))
        Task {
            do {
                _ = try await reply.value
            } catch {
                log.error("panel force \(value): \(String(describing: error), privacy: .public)")
                return
            }
            guard self.epoch == epoch else { return }
            self.panelForce = (value, force.info)
        }
    }

    // MARK: - Helpers

    /// The second application of the wanted state, `reapplyDelay` from now (replacing a pending one).
    private func scheduleReapply() {
        reapplyTask?.cancel()
        let sleep = clock.sleeper(for: Self.reapplyDelay)
        reapplyTask = Task { [weak self] in
            do { try await sleep() } catch { return }
            guard let self, !Task.isCancelled, self.active else { return }
            self.reapplyTask = nil
            self.requestSync()
        }
    }

    private func emit(_ events: [MouseEvent]) {
        for event in events { continuation.yield(event) }
    }

    private func releaseHeld() {
        emit(tracker.releaseAll(at: Self.now))
        lastPressed = []
        emit(watchHeld.map { .released($0, at: Self.now) })
        watchHeld = []
    }

    /// The time of synthesised events: the clock of the reports' timestamps.
    private static var now: TimeInterval { IOKitTransport.currentTime }

    private static func byRawValue(_ a: CID, _ b: CID) -> Bool { a.rawValue < b.rawValue }

}

// MARK: - Supporting types

extension Clock where Duration == Swift.Duration {
    /// A sleep until `delay` after now — now being the moment of this call, not of the first await.
    fileprivate func sleeper(for delay: Duration) -> @Sendable () async throws -> Void {
        let deadline = now.advanced(by: delay)
        return { try await self.sleep(until: deadline, tolerance: nil) }
    }
}

private enum ReprogFunction {
    static let count: UInt8 = 0
    static let controlInfo: UInt8 = 1
    static let setReporting: UInt8 = 3
}

/// One request of a writer pass: a divert or release of a control, of the thumb wheel, analytics on / off, the
/// hi-res wheel's high-resolution bit on / off, or a SmartShift wheel mode (the wanted one, or the mouse's own given
/// back).
private enum WriteStep {
    case divert(CID, on: Bool)
    case wheel(on: Bool)
    case hiRes(on: Bool)
    case wheelMode(WheelMode, givingBack: Bool)
    case watch(CID, on: Bool)
}

private enum WheelFunction {
    static let info: UInt8 = 0
    static let setReporting: UInt8 = 2
}

private enum HapticFunction {
    static let config: UInt8 = 1
    static let setConfig: UInt8 = 2
    static let play: UInt8 = 4
}

private enum ForceFunction {
    static let count: UInt8 = 0
    static let info: UInt8 = 1
    static let current: UInt8 = 2
    static let set: UInt8 = 3
    /// The haptic panel: the MX Master 4's only force-sensing button.
    static let panelButton: UInt8 = 0
}

/// What the haptic lane plays next: a pattern, or a strong-play block (strength, pattern, normal strength).
private enum HapticCommand: Sendable {
    case play(HapticPattern)
    case block(HapticPattern, strength: UInt8)
}

/// One receiver: its transport behind a write gate, and the channel on it.
private struct Link: Sendable {
    let id: Int
    let gate: TransportGate
    let channel: HIDPPChannel
}

private struct WheelFeature: Sendable {
    let index: UInt8
    let info: ThumbWheel.Info
}

private struct HiResFeature: Sendable {
    let index: UInt8
    /// The wheel mode read at setup; nil when that read failed.
    let mode: UInt8?
    /// The setup's read of the mode timed out (and so is followed by the rest).
    let readTimedOut: Bool
}

private struct SmartShiftFeature: Sendable {
    let index: UInt8
    /// The wheel mode read at setup; nil when that read failed.
    let mode: WheelMode?
    /// The setup's read of the mode timed out (and so is followed by the rest).
    let readTimedOut: Bool
}

/// A SmartShift read whose mode byte is neither free spin nor ratchet.
private struct UnknownWheelMode: Error {
    let byte: UInt8
}

private struct ForceFeature: Sendable {
    let index: UInt8
    let info: ForceSensing.Info
    let current: UInt16
}

/// What setup read from the mouse.
private struct Features: Sendable {
    let reprog: UInt8
    let controls: [Control]
    let wheel: WheelFeature?
    let haptic: UInt8?
    let hapticsEnabled: Bool
    let hapticStrength: UInt8?
    let force: ForceFeature?
    let hiRes: HiResFeature?
    let smartShift: SmartShiftFeature?

    var divertable: Set<CID> { Set(controls.lazy.filter(\.divertable).map(\.cid)) }
    var watchable: Set<CID> { Set(controls.lazy.filter(\.watchable).map(\.cid)) }
}

private enum SearchItem: Equatable {
    case discover(link: Int)
    case probe(link: Int, slot: UInt8)
}

/// What the search makes of a device: a mouse (REPROG_CONTROLS_V4 plus haptics or a thumb wheel), a fallback
/// (REPROG_CONTROLS_V4 alone, e.g. a keyboard), or neither.
private enum DeviceKind {
    case none, fallback, qualifying
}

/// The mouse a `LogiMouse` is bound to.
private struct Session {
    let link: Link
    let device: UInt8
    /// Whether it qualified as a mouse; a fallback binding gives way to a qualifying device that links later.
    let preferred: Bool
    var connected = false
    /// Setup is reading features: the writer stays idle.
    var settingUp = false
    var features: Features?
    /// Controls that may be diverted by us in the mouse: added before a divert is sent, removed once a release is.
    var divertedInMouse: Set<CID> = []
    /// Controls whose analytics may be on in the mouse: the same bookkeeping as `divertedInMouse`.
    var watchedInMouse: Set<CID> = []
    var wheelDivertedInMouse = false
    /// The hi-res wheel mode as last read or confirmed written; nil without the feature.
    var hiResMode: UInt8?
    /// The mode had the high-resolution bit when read while this app's marker was clear: the user's own setting,
    /// never written.
    var hiResUsersOwn = false
    /// The SmartShift wheel mode as last read or confirmed written; nil without the feature or while unknown.
    var wheelMode: WheelMode?

    init(link: Link, device: UInt8, preferred: Bool) {
        self.link = link
        self.device = device
        self.preferred = preferred
    }
}

/// A transport whose writes can be shut off for good. `close` waits for a write in progress, so after it returns no
/// write through the gate can reach the device; `base` stays usable for the final releases.
final class TransportGate: HIDPPTransport {
    let base: any HIDPPTransport
    private let open = Mutex(true)

    init(_ base: any HIDPPTransport) {
        self.base = base
    }

    var events: AsyncStream<TransportEvent> { base.events }

    func send(_ report: HIDPPReport) throws {
        try open.withLock { open in
            guard open else { throw HIDPPError.disconnected }
            try base.send(report)
        }
    }

    func close() {
        open.withLock { $0 = false }
    }
}

/// Tasks cancelled together when their owner goes away.
final class TaskBag: Sendable {
    private let tasks = Mutex<[Task<Void, Never>]>([])

    func add(_ task: Task<Void, Never>) {
        tasks.withLock { $0.append(task) }
    }

    func cancelAll() {
        for task in tasks.withLock({ $0 }) { task.cancel() }
    }
}
