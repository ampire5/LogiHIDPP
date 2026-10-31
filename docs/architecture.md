# LogiHIDPP architecture

Current map; update when device ownership, request matching or diversion/release behavior changes. Package.swift
specifies macOS 15+, Swift tools 6.0 and Swift 6 language mode. This is the low-level hardware library, not the
applications' window/input dispatcher.

## Components and flow

| Layer | Owns | Source |
|---|---|---|
| Transport | HID report I/O and asynchronous report delivery | `Sources/LogiHIDPP/HIDPPTransport.swift`, `Sources/LogiHIDPP/IOKitTransport.swift` |
| Channel | Serialized request/reply matching, timeout/cancellation and notifications | `Sources/LogiHIDPP/HIDPPChannel.swift`, `Sources/LogiHIDPP/HIDPPReport.swift` |
| Device coordinator | Discovery, connection/setup, requested diversion and lifecycle | `Sources/LogiHIDPP/LogiMouse.swift` |
| Feature helpers | Reprogrammable controls, wheels, SmartShift, haptics and force sensing | `Sources/LogiHIDPP/ReprogControls.swift`, `Sources/LogiHIDPP/ThumbWheel.swift`, `Sources/LogiHIDPP/Haptics.swift` |
| AppKit adapter | Frontmost-app integration | `Sources/LogiHIDPP/LogiMouse+AppKit.swift` |

`LogiMouse` is main-actor coordination; `HIDPPChannel` is an actor. IOKitTransport is Sendable with its own transport
synchronization. Client intent → device coordinator → feature request → channel → transport → matching reply or
notification → event delivery. Software ID and receiver/device addressing are part of matching, not display state.

## Lifetime and correctness boundaries

A cancelled/timed-out request can still receive a physical device reply. The channel's pending/tombstone matching
must keep that reply away from a later request. Do not remove late-reply handling to simplify the actor.
Connection setup/retry work, diversion wishes and foreground transitions belong to `LogiMouse`; stopping must
release diversion and stop retries. Hardware operations are not main-thread synchronous waits. Watching an input
and diverting it are different policies; preserve the foreground rule and release ordering documented in README.

Loupe and FrameScrub currently connect to MouseService through MouseClient for runtime input/haptics. They also
consume LogiHIDPP types. Do not add a second direct device owner in an app to bypass the service.

## Verification

`Tests/LogiHIDPPTests` covers protocol/channel/device policies with transport fixtures. Run `swift test --jobs 4`.
`Sources/logi-probe/main.swift` is the executable hardware diagnostic tool; use its documented commands deliberately
because real-device behavior cannot be established by transport fixtures alone. Read [README](../README.md) for
foreground, crash recovery, receiver, precision-scroll and haptic contracts before changing the relevant feature.
