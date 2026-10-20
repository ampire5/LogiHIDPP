# LogiHIDPP

A Swift package that talks Logitech's HID++ 2.0 protocol to a mouse on a Bolt (or Unifying) receiver, so macOS apps
get what the system hides — the MX Master 4's haptic thumb panel, gesture and SmartShift buttons, the high-resolution
thumb wheel, Precision Scroll on the main wheel, and haptic feedback — without Logi Options+. It reports raw facts
("button X pressed at T", "thumb wheel turned N steps") and plays haptic patterns on request; what they mean is up to
the app (Loupe, FrameScrub). macOS 15+, Swift 6, no dependencies, GPL-3.0. Hardware notes:
`docs/hardware-notes.md`.

```sh
swift build
swift test                          # no test touches a real device
LOGI_HARDWARE=1 swift test          # also the hardware test, with the mouse connected
swift run logi-probe                # the command-line probe
```

## API in ten lines

```swift
import LogiHIDPP

let mouse = LogiMouse()
mouse.divert([.hapticPanel, .gesture])        // before start(): the startup release covers them
mouse.divertThumbWheel(true)
mouse.watch([.back, .forward])                // hear these presses WITHOUT taking the buttons (see "Watching")
mouse.wantHighResolutionWheel(true)           // Precision Scroll while active (see "Precision Scroll")
mouse.start()                                  // after the window is shown
mouse.follow(app: NSApplication.shared)       // foreground rule; also releases on termination
Task { for await event in mouse.events { handle(event) } }   // .pressed / .thumbWheel / .highResolutionWheel …
mouse.play(haptic: .subtleCollision)           // does nothing in the background
mouse.play(haptic: .sharpCollision, strength: 80)   // stronger than normal for this one pattern
mouse.setPanelForce(3799)                      // a mouse setting: only when the app asks (see below)
```

Without `NSApplication` call `mouse.setActive(true)` yourself, `mouse.systemDidWake()` when the Mac wakes, and
`mouse.releaseAllSync()` before exit.

One `LogiMouse` per process. Call `releaseAllSync()` before dropping it while the app goes on running (`mouse = nil` to
turn the feature off): `deinit` releases nothing, and the thumb wheel and SmartShift button would stay dead in every app
until the mouse sleeps. `releaseAll()` (asynchronous) is for an active app or a manual cure only: called while inactive
it releases the controls this app wants, and so takes them from the app in the foreground if it diverted them too.

## Foreground rule

Only the app in the foreground owns the mouse's buttons and thumb wheel. When the app becomes active the package diverts
what the app wants, and diverts it again 300 ms later, so the "release" of the app that just left (Loupe to FrameScrub
and back), arriving in the mouse late, cannot leave a control undiverted. When the app resigns, everything is released,
held buttons get `.released`, button and wheel reports are ignored and `play(haptic:)` does nothing. At exit
`releaseAllSync()` (100 ms at most) hands every control back; `follow(app:)` calls it on termination.

The release of left-over diverts at startup (see "After a crash") ignores the rule: an app launched in the background
(`open -g`, a login item) while another app using the package is in front takes the wanted controls from it until that
app is activated again. A fallback binding (no mouse, only a keyboard with REPROG_CONTROLS_V4) is never diverted: its
keys would go dead in every app.

## Watching: hear a button without taking it

`divert` takes a control from the OS: its button stops working everywhere else, and an app that already owns it (Mac
Mouse Fix on back / forward) loses it. `watch(_ cids: Set<CID>)` is the other way: REPROG_CONTROLS_V4's *analytics key
events* make the mouse also report the control's presses over HID++ while it keeps sending the normal button to the OS.
The presses arrive as the same `.pressed(cid, at:)` / `.released(cid, at:)` events as diverted ones — and the OS gets the
same press too, so the app must ignore the OS event of a watched control or it handles each press twice.
`mouse.watching` is the set whose analytics the mouse has confirmed on right now: ignore the OS events of exactly those
controls (it is empty while the app is inactive, the mouse is off or the receiver is set up anew).

The rules are those of `divert`: applied while the app is active (now and 300 ms later), switched off on deactivation
(held watched controls get `.released`), applied again after a reconnect, switched off by `releaseAll()`,
`releaseAllSync()` and the startup release. Controls whose `Control.watchable` is false are ignored. A control in both
the divert set and the watch set is **diverted only**: divert wins, and its watch is off (and it is not in `watching`)
while it is diverted. Events arrive only while the app is active. A press event of a wanted control also confirms it
into `watching` (the mouse evidently has analytics on, e.g. after a lost reply or during a re-setup). An analytics
state left on by a crash should be harmless (the mouse only reports more); the next start switches it off first.
Caveat: another app using this package (FrameScrub, say) can switch a watch off: its deactivation-off arriving after our
300 ms re-apply, or its startup release of leftovers. The button then goes dead in this app (the OS events are ignored
because the control is in `watching`, and no HID++ events come) until the app is activated again. Hardware facts:
`docs/hardware-notes.md`.

## Precision Scroll

`wantHighResolutionWheel(_:)` puts the main (vertical) wheel into high resolution (HID++ `0x2121` Hi-Res Wheel,
Logitech's "Precision Scroll": on the MX Master 4 about 6 macOS scroll events per notch instead of 1, and a touch short
of a notch gives one). The wheel still goes through macOS; nothing is diverted, so a crash leaves it working, only more
sensitive. It is wanted state under the foreground rule, like `divert`: set while the app is active (now and 300 ms
later), cleared on deactivation, by `releaseAll()` and within `releaseAllSync()`'s 100 ms, read and applied again after
a reconnect. The app decides when to want it (FrameScrub: the pointer is over the video).

- Only the high-resolution bit (`0x02`) of the wheel mode is written, from the mode last read (setup, recheck); the
  divert and invert bits stay as they are. The mode is written only when it differs from the wanted state.
- A wheel found in high resolution that this app did not turn on is **the user's own** setting (LinearMouse, Logi
  Options+, for the whole system): it is never written, wanted or not.
- A **marker** (`HiResMarker`; by default the app's `UserDefaults`, key `LogiHIDPP.hiResTurnedOn`) is set before the
  package turns the bit on and cleared only once an off-write is confirmed (or a read shows the bit clear). A wheel
  found in high resolution with the marker set is a leftover of a crash: it is turned off at the next setup unless
  wanted. The marker is one per app (not per mouse) and not shared between apps.
- An off-write the mouse refuses (an error reply) is retried every second until it gets through or the mode is wanted
  again. The first failure and the success after it are logged.
- After any `0x2121` request **times out**, the wheel rests for 5 s (the channel's late-reply window: setMode has no
  echo, so the timed-out request's tombstone would swallow the next reply, that request would time out in turn, and so
  on, each stalling the writer for the request timeout). During the rest no hi-res request is sent in either direction,
  however often the wish changes. The rest ends with a read of the mode, and the writer then does what the real mode
  needs (a write that got through after all is not repeated). Until that read, `isHighResolution` shows the last known
  mode.
- `recheckHighResolutionWheel()` reads the mode again while active and fixes a drift (the mouse slept, or BetterMouse
  rewrote the feature after a reconnect); `systemDidWake()` does the same. While inactive, or while the wheel rests,
  it does nothing.
- `isHighResolution` says whether the wheel is in high resolution now (this app's or the user's own); every change
  arrives as `.highResolutionWheel(Bool)`, e.g. to count scroll events per notch.

`logi-probe hires` shows the mode; `hires on` / `hires off` write the bit directly (no marker) and read it back.

## SmartShift

`wantWheelMode(_:)` sets the main wheel's mode (HID++ `0x2111` SmartShift: `.freeSpin`, the wheel spins freely, or
`.ratchet`, it clicks from notch to notch). It is wanted state under the foreground rule, like `divert`: written while
the app is active (now and 300 ms later), read and applied again after a reconnect. `wantWheelMode(nil)` wants none.
The app decides when to want a mode.

- **The mouse's own mode is given back.** Before the first write of the app's mode the mode read from the mouse is saved
  in a **marker** (`WheelModeMarker`; by default the app's `UserDefaults`, key `LogiHIDPP.wheelModeSaved`), and on
  deactivation, `releaseAll()` (which also drops the wish) and within `releaseAllSync()`'s 100 ms the mouse gets that
  mode back; the marker is cleared once a write of it is confirmed (or a read shows it while the app wants none). At
  exit the write's reply is not awaited: the marker is cleared as soon as the report is sent without a transport error,
  so a mode the user picks later with SmartShift in another app is not overwritten at the next launch. A give-back the
  mouse refuses (an error reply) is sent again every second while it is owed. Every activation reads the mode before
  writing (a press of the button in another app is not heard), so a mouse already in the wanted mode is not written to.
  Only the mode is written (`[mode, 0, 0]`); the auto-disengage threshold and the torque stay.
- **After a crash** (or a give-back at exit that could not be sent) the mouse is left in the app's mode and the marker
  stays set. The next launch of the same app (the marker is in that app's `UserDefaults`, one per app, not shared
  between apps) reads the mode at setup and, if the app wants none, gives the saved one back. Relaunching is the cure;
  `logi-probe release` does not know the wheel mode (`logi-probe smartshift free|ratchet` or a press of the button
  switches it by hand).
- **The SmartShift button adopts the user's choice.** The mouse switches the mode itself when the button is pressed, and
  sends no notification of it. While a mode is wanted, the package watches the button (`CID.smartShift`, as `watch(_:)`
  would, but without `watching` or `.pressed` / `.released` events) and reads the mode after each release. From the
  press until its release (at most 1 s, in case the release is lost) no mode is written, so a `recheckWheelMode()`
  landing in between cannot undo the press; its read counts as a read after the press. While the app's mode is applied,
  a mode other than the wanted one becomes the wanted one: nothing is written back, the mouse's own mode is saved in the
  marker if no write has saved it yet (so deactivation gives it back), and the read arrives as
  `.wheelMode(_, byButton: true)`; an unchanged read after a press arrives the same way (two presses may have come back
  to the mode, or a read while the button was down adopted it already). Read while the app is inactive or after the
  give-back, a changed mode is only noted. An app that **diverts** the button itself (`divert([.smartShift])`) gets no
  automatic switching: the button is its own then, and the mode is only what it wrote.
- After any `0x2111` request **times out**, the wheel mode rests for 5 s like the hi-res wheel (its own rest: no
  SmartShift request in either direction), then the mode is read and acted on.
- `recheckWheelMode()` reads the mode again while active and fixes a drift (the mouse slept, or the user switched it);
  `systemDidWake()` does the same. While inactive, or while the mode rests, it does nothing.
- `wheelMode` is the mode last read or written (nil without a mouse or the feature, or while the mode is unreadable);
  every change to a known mode arrives as `.wheelMode(WheelMode, byButton: Bool)`, and so does every read after a press
  of the SmartShift button while the app's mode is applied, changed or not, with `byButton: true`.

`logi-probe smartshift` shows the mode, the threshold and the torque; `smartshift free` / `smartshift ratchet` write the
mode directly (no marker, so a mode left this way counts as the mouse's own) and read it back. Hardware facts:
`docs/hardware-notes.md`.

## Software ID per process

Every HID++ request carries a 4-bit software ID that its reply repeats, and macOS delivers every report of the
receiver to every process that has it open. Two processes with the same ID would take each other's replies, and a
wrong reply can send a write to the wrong feature (e.g. the haptic-strength setting). So each process claims its own ID
on first use: the lowest free one of `0xA…0xF`, then `1…7`, `9` (never 0, the notification ID, and never 8, which
BetterMouse uses), by a non-blocking `flock` on `$TMPDIR/LogiHIDPP-swid-<n>.lock` held for the life of the process (the
kernel releases it on a crash). `HIDPPSoftwareID.process` is the claimed ID; `LogiMouse(softwareID:)` and
`HIDPPChannel(transport:softwareID:)` override it. A sandboxed app has its own `$TMPDIR`, so the lock files do not see
other apps: pass an explicit ID there.

## Receiver notifications

The receiver tells the package that the mouse linked or lost its link (switched on or off, woke from deep sleep) only
when its wireless-notification flag is set (register `0x00`, flag `0x000100`). Without it a mouse that is off when the
app starts is never found, and a mouse that slept or was switched off and on (and so forgot its diverts) is never
diverted again until the app is re-activated. Another client (BetterMouse, Logi Options+) usually sets the flag, but the
register is volatile: a receiver re-plug or reset clears it.

So on every receiver attach, and in `systemDidWake()` (`follow(app:)` calls it on `NSWorkspace.didWakeNotification`),
the package reads the register and, **only if the wireless flag is clear**, writes it back with that one flag set; every
other flag stays as it was. A failure is logged and ignored. Risk: this is a write to the receiver (not to the mouse,
whose settings the package writes only when the app asks, see "Haptic strength and panel force"), it lasts until the
receiver is re-plugged or reset, and it makes the receiver send connection notices to every client — harmless for the
clients known so far, which expect them. The package does not set the `software present` flag (`0x000800`), which
changes host-mode behaviour on some devices.

## After a crash

A crash leaves the controls diverted in the mouse until it sleeps or is switched off. The haptic panel does not mind,
but the SmartShift button stops toggling the wheel mode, and the thumb wheel stays out of the system. Cure: run
`swift run logi-probe release` (hands back every divertable control and the thumb wheel, whoever diverted them), or let
the mouse sleep. The next start of an app using the package also releases what it wants first thing, and turns off a
Precision Scroll it left on (by its marker) and gives back the wheel mode it changed (by its marker, see "SmartShift";
a clean quit has given it back already and cleared the marker, so only a crash leaves this to the next launch); by
hand, `swift run logi-probe hires off` and `swift run logi-probe smartshift ratchet` (or `free`, whichever the mouse
had; a press of the SmartShift button switches it too).

## logi-probe

```
swift run logi-probe <command>

list                  receivers, devices, HID++ version, features, buttons and what is diverted (read-only)
raw <seconds>         print every incoming HID++ report with a timestamp
listen [cid…]         divert buttons (hex CIDs; none = every divertable one except left/right) and print presses
watch [cid…]          listen to buttons without taking them (hex CIDs; none = 53 56) and print presses
thumbwheel            divert the thumb wheel and print its steps
haptic <N|name> [s]   play a haptic pattern by number (0…14, 0x1b) or name (whisper-collision), at strength s if given
haptic-all [pause]    play every pattern in turn, announcing each (pause in seconds, default 2)
force [value]         show the haptic panel's force (current, default, range); with a value, write it (clamped),
                      confirmed and read back
strength [0-100]      show the haptic strength; with a value, write it, confirmed and read back
hires [on|off]        show the main wheel's mode (0x2121, Precision Scroll); with on / off, write the high-resolution
                      bit (the others stay), confirmed and read back
smartshift [free|ratchet]
                      show the wheel mode (0x2111: free spin or ratchet, the auto-disengage threshold, the torque); with
                      free / ratchet, write the mode and read it back
release               hand every divertable control and the thumb wheel back to the mouse
```

`listen`, `watch` and `thumbwheel` print one line per event with the time in seconds since the start and release what
they diverted (switch off what they watched) on Ctrl-C. While `listen` runs, the buttons it diverts do nothing in
macOS. Without arguments it never diverts the left and right buttons (0x50, 0x51), even if the mouse reports them
divertable; name them explicitly to divert them.

## Haptic patterns

Sixteen waveforms; numbers and names are Logitech's (as Solaar lists them in `HapticWaveForms`; the mouse reports which
it has in a capability mask, bit N = pattern N — the MX Master 4 has bits 0–14 and 27). All checked by hand on the MX
Master 4 on 2026-10-16. The "use" column is what the name suggests and how the user read them.

| N | `HapticPattern` | Feel / use |
|---|---|---|
| 0x00 | `.sharpStateChange` | crisp switch — a toggle turned on/off |
| 0x01 | `.dampStateChange` | soft switch |
| 0x02 | `.sharpCollision` | hard bump — hitting a limit |
| 0x03 | `.dampCollision` | soft bump |
| 0x04 | `.subtleCollision` | light bump — a zoom stop |
| 0x1B | `.whisperCollision` | barely-there bump — fine steps of an adjustment |
| 0x05 | `.happyAlert` | "good" notification |
| 0x06 | `.angryAlert` | "bad" notification, an error |
| 0x07 | `.completed` | done |
| 0x08 | `.square` | square wave |
| 0x09 | `.wave` | smooth wave |
| 0x0A | `.firework` | firework |
| 0x0B | `.mad` | mad |
| 0x0C | `.knock` | knock |
| 0x0D | `.jingle` | little tune |
| 0x0E | `.ringing` | ringing |

**Strength** is one setting of the mouse, 0–100 (`0x19B0` function 1 reads `enabled strength`, function 2 writes it;
Logi Options+ offers Low 25 / Medium 50 / High 75 / Maximum 100; a mouse whose function-1 byte 2 bit 0 is set knows only
those four). The user's mouse is set to 35. See below for how the package writes it.

## Haptic strength and panel force

Two settings live in the mouse and survive its sleep. The package reads both at setup and writes them **only when the
app asks**; neither is bound to the foreground rule.

- **Haptic strength** (`0x19B0`): `hapticStrength` is the strength read at setup (then the one the app wrote).
  `setHapticStrength(_:)` (0–100) makes it the normal strength: written now, or at setup if no mouse is set up yet, and
  again after every reconnect. The write is `01 NN` and so also switches haptics on: it is skipped (and logged) while
  the mouse's haptics are off.
- **Strong plays**: `play(haptic:strength:)` with a strength other than the normal one sends a block of three commands
  in order — write the strength, play, write the normal strength (the app's, else the one read at setup). The first two
  are posted back to back without waiting for a reply; the restore's reply is awaited beside the queue, so no play ever
  waits for a write (nor for a lost reply). A newer play replaces a block that has not started; a started block always
  ends with the normal strength, also when the app goes to the background meanwhile (the pattern is then skipped).
  Until the restore is confirmed it is owed: deactivation writes the normal strength again, `releaseAllSync()` sends it
  at exit (after the releases, within the same 100 ms), and a mouse that lost its link gets it at the next setup (an
  owed restore is dropped when the binding ends — receiver removed, another device bound — as the next device may be
  another mouse). While a setup runs (it reads the strength) a strong play waits in the queue.
- Apps that use strong plays should also call `setHapticStrength(_:)` with their normal strength: otherwise the normal
  one is whatever the mouse reports at setup, which is the strong one if another app's strong play was under way.
- **Panel force** (`0x19C0` Force Sensing Button, button 0): how hard the haptic panel must be pressed, in Logitech's
  undocumented units; the MX Master 4 takes 3799…6316, default 4749. `panelForce` is `(current, info)` read at setup;
  `setPanelForce(_:)` clamps to `info.range` and writes now, or at setup, and again after every reconnect. A mouse
  whose button is not changeable is left alone (logged).

Try them with `logi-probe force [value]` and `logi-probe strength [0-100]` (direct writes, confirmed and read back)
and `logi-probe haptic <N> <strength>` (a strong play through `LogiMouse`); `force 4749` and `strength 35` put the
user's mouse back as it was.
