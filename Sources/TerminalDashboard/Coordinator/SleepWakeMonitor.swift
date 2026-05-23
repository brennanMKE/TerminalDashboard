import Foundation
#if canImport(AppKit)
import AppKit
#endif

// MARK: - SleepWakeMonitor

/// Subscribes to display sleep and wake notifications and invokes user-supplied
/// closures when they fire.
///
/// Uses `NSWorkspace.shared.notificationCenter` `screensDidSleepNotification`
/// and `screensDidWakeNotification` — the simpler alternative to IOKit's
/// `IORegisterForSystemPower`. The monitor must be created and used on the
/// `MainActor` since it drives UI-adjacent state (the data source wrappers and
/// the `AutoCoordinator`).
///
/// The monitor owns its observer tokens and tears them down in `deinit` so that
/// the lifetime of the subscription matches the lifetime of the monitor.
@MainActor
final class SleepWakeMonitor {

    // MARK: - Callbacks

    /// Invoked on the `MainActor` when the display goes to sleep.
    var onSleep: (@MainActor () -> Void)?

    /// Invoked on the `MainActor` when the display wakes.
    var onWake: (@MainActor () -> Void)?

    // MARK: - Private state

    #if canImport(AppKit)
    private var sleepObserver: NSObjectProtocol?
    private var wakeObserver: NSObjectProtocol?
    #endif

    /// `true` once `start()` has been called and observers are registered.
    private(set) var isRunning: Bool = false

    // MARK: - Lifecycle

    init() {}

    // Note: observer tokens are not `Sendable`, so we cannot tear them down
    // from a nonisolated `deinit`. Callers must invoke `stop()` explicitly
    // when they no longer need the monitor. In practice, monitors are owned
    // by `AutoCoordinator` / `*State` instances and live for the lifetime of
    // the process (`Application.start()` calls `dispatchMain()` and never
    // returns), so explicit teardown is not required.

    // MARK: - Public API

    /// Begins listening for display sleep and wake notifications.
    /// Safe to call multiple times — subsequent calls are no-ops.
    func start() {
        guard !isRunning else { return }
        isRunning = true

        #if canImport(AppKit)
        let center = NSWorkspace.shared.notificationCenter
        let mainQueue = OperationQueue.main

        sleepObserver = center.addObserver(
            forName: NSWorkspace.screensDidSleepNotification,
            object: nil,
            queue: mainQueue
        ) { [weak self] _ in
            // The block is delivered on `mainQueue` (OperationQueue.main), which
            // runs on the main thread. Hop onto the MainActor to invoke the
            // callback safely.
            Task { @MainActor [weak self] in
                self?.onSleep?()
            }
        }

        wakeObserver = center.addObserver(
            forName: NSWorkspace.screensDidWakeNotification,
            object: nil,
            queue: mainQueue
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.onWake?()
            }
        }
        #endif
    }

    /// Stops listening for display sleep and wake notifications.
    /// Safe to call multiple times.
    func stop() {
        guard isRunning else { return }
        isRunning = false

        #if canImport(AppKit)
        let center = NSWorkspace.shared.notificationCenter
        if let token = sleepObserver {
            center.removeObserver(token)
            sleepObserver = nil
        }
        if let token = wakeObserver {
            center.removeObserver(token)
            wakeObserver = nil
        }
        #endif
    }
}
