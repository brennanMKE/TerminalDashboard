import Foundation

// MARK: - AutoCoordinator

/// Subscribes to all three data sources, manages badge counts, drives view
/// switching, and runs a 10-second revert timer when an auto switch occurs.
///
/// All state mutations happen on the `MainActor`, matching the `@MainActor`
/// `ObservableObject` pattern used by the state wrappers.
@MainActor
final class AutoCoordinator: ObservableObject {

    // MARK: - Published state

    /// The view currently shown to the user.
    @Published var activeView: DashboardSource = .git

    /// The "home" view — where auto mode reverts after a countdown.
    @Published var homeView: DashboardSource = .git

    /// Whether auto mode is active (default: `true`).
    @Published var isAutoMode: Bool = true

    /// Badge counts per source; incremented on events, cleared when the view
    /// becomes active.
    @Published var badgeCounts: [DashboardSource: Int] = [
        .git: 0,
        .crashes: 0,
        .logs: 0,
    ]

    /// Shown in the tab bar during a countdown; `nil` otherwise.
    @Published var bannerMessage: String? = nil

    /// Remaining seconds on the current countdown; `nil` when no countdown.
    @Published var countdownSeconds: Int? = nil

    // MARK: - Private state

    /// The event that triggered the current auto switch (used to decide whether
    /// a new event should supersede it).
    private var activeEventSeverity: Severity? = nil

    /// The running countdown task; cancelled on manual switch, mode toggle, or
    /// when a new higher-priority event fires.
    private var countdownTask: Task<Void, Never>? = nil

    // MARK: - Constants

    private static let countdownDuration = 10

    // MARK: - Public API

    /// Wires up `onEvent` callbacks on all three state objects and starts the
    /// data sources.
    func start(gitState: GitState, crashesState: CrashesState, logsState: LogsState) {
        gitState.onEvent = { [weak self] event in
            self?.handle(event)
        }
        crashesState.onEvent = { [weak self] event in
            self?.handle(event)
        }
        logsState.onEvent = { [weak self] event in
            self?.handle(event)
        }

        gitState.start()
        crashesState.start()
        logsState.start()
    }

    /// Manual view switch: new view becomes home, countdown is cancelled, auto
    /// mode remains active, badge for the target view is cleared.
    func switchToView(_ view: DashboardSource) {
        cancelCountdown()
        activeView = view
        homeView = view
        clearBadge(for: view)
    }

    /// Flips auto mode. Turning off during a countdown keeps the user on the
    /// current view (no revert).
    func toggleAutoMode() {
        if isAutoMode {
            // Turning off — cancel any running countdown, stay on current view.
            isAutoMode = false
            cancelCountdown()
        } else {
            isAutoMode = true
        }
    }

    // MARK: - Event handling

    private func handle(_ event: DashboardEvent) {
        // Always increment the badge for the source view (unless it's active).
        if event.source != activeView {
            badgeCounts[event.source, default: 0] += 1
        }

        guard isAutoMode else { return }

        switch event.severity {
        case .info, .warning:
            // Badge only — no view switch.
            break

        case .error:
            // Switch only if the current view does NOT already have an active
            // error or critical event in progress.
            guard !(activeEventSeverity == .error || activeEventSeverity == .critical) else {
                break
            }
            autoSwitch(to: event.source, severity: event.severity, message: event.message)

        case .critical:
            // Always switch, superseding any existing countdown.
            autoSwitch(to: event.source, severity: event.severity, message: event.message)
        }
    }

    // MARK: - Auto switch

    private func autoSwitch(to source: DashboardSource, severity: Severity, message: String) {
        // Record where to return to (if not already mid-countdown).
        if countdownTask == nil {
            homeView = activeView
        }

        // Move to the new view.
        activeView = source
        clearBadge(for: source)
        activeEventSeverity = severity

        // Cancel any existing countdown and start a fresh one.
        cancelCountdown(keepBanner: false)
        startCountdown(viewName: displayName(for: source), message: message)
    }

    // MARK: - Countdown

    private func startCountdown(viewName: String, message: String) {
        var remaining = Self.countdownDuration
        countdownSeconds = remaining
        bannerMessage = "Auto → \(viewName): \(message) — returning in \(remaining)s"

        countdownTask = Task { [weak self] in
            guard let self else { return }
            for await _ in AsyncTimerSequence() {
                guard !Task.isCancelled else { break }
                remaining -= 1
                guard remaining > 0 else {
                    self.finishCountdown()
                    return
                }
                self.countdownSeconds = remaining
                self.bannerMessage = "Auto → \(viewName): \(message) — returning in \(remaining)s"
            }
        }
    }

    private func finishCountdown() {
        let destination = homeView
        activeView = destination
        clearBadge(for: destination)
        countdownSeconds = nil
        bannerMessage = nil
        activeEventSeverity = nil
        countdownTask = nil
    }

    /// Cancels the countdown and resets countdown-related state.
    private func cancelCountdown(keepBanner: Bool = false) {
        countdownTask?.cancel()
        countdownTask = nil
        countdownSeconds = nil
        activeEventSeverity = nil
        if !keepBanner {
            bannerMessage = nil
        }
    }

    // MARK: - Helpers

    private func clearBadge(for source: DashboardSource) {
        badgeCounts[source] = 0
    }

    private func displayName(for source: DashboardSource) -> String {
        switch source {
        case .git:     return "Git"
        case .crashes: return "Crashes"
        case .logs:    return "Logs"
        }
    }
}

// MARK: - AsyncTimerSequence

/// A non-blocking `AsyncSequence` that yields `Void` once per second using
/// `ContinuousClock`, compatible with Swift 6 strict concurrency.
private struct AsyncTimerSequence: AsyncSequence {
    typealias Element = Void

    func makeAsyncIterator() -> AsyncIterator {
        AsyncIterator()
    }

    struct AsyncIterator: AsyncIteratorProtocol {
        mutating func next() async -> Void? {
            guard !Task.isCancelled else { return nil }
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return nil }
            return ()
        }
    }
}
