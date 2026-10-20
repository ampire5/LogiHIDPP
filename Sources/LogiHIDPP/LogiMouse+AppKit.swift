import AppKit

extension LogiMouse {
    /// Applies the foreground rule for `app`: `setActive(true)` when it becomes active, `setActive(false)` when it
    /// resigns, and `releaseAllSync()` when it terminates; calls `systemDidWake()` when the Mac wakes. Takes the app's
    /// current state at once. A second call replaces the first. Call `start()` as well.
    public func follow(app: NSApplication) {
        for (center, observer) in appObservers { center.removeObserver(observer) }
        let center = NotificationCenter.default
        let workspace = NSWorkspace.shared.notificationCenter
        // queue nil: the block runs synchronously on the posting thread — the main thread for these notifications —
        // so `releaseAllSync()` finishes before the app goes on terminating.
        appObservers = [
            (center, center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: app, queue: nil) { [weak self] _ in
                MainActor.assumeIsolated { self?.setActive(true) }
            }),
            (center, center.addObserver(forName: NSApplication.didResignActiveNotification, object: app, queue: nil) { [weak self] _ in
                MainActor.assumeIsolated { self?.setActive(false) }
            }),
            (center, center.addObserver(forName: NSApplication.willTerminateNotification, object: app, queue: nil) { [weak self] _ in
                MainActor.assumeIsolated { self?.releaseAllSync() }
            }),
            (workspace, workspace.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.systemDidWake() }
            }),
        ]
        setActive(app.isActive)
    }
}
