import Foundation

// MARK: - Errors

enum GitDataSourceError: Error, Sendable {
    case gitNotFound
    case launchFailed(String)
    case notARepository(String)
    case gitFailed(Int32, String)
}

// MARK: - Model

/// Status of a single file reported by `git status --porcelain=v2`.
struct GitFileStatus: Sendable, Identifiable {
    /// Repository-relative file path.
    let path: String
    /// Staged status character (X column): M, A, D, R, C, or `.`
    let stagedFlag: Character
    /// Working-tree status character (Y column): M, D, or `.`; `?` for untracked.
    let worktreeFlag: Character

    var id: String { path }
}

// MARK: - Actor

/// Polls `git status --porcelain=v2 --branch` every 2 seconds and emits
/// `DashboardEvent` values when meaningful changes occur.
actor GitDataSource {

    // MARK: State (actor-isolated)

    private(set) var branch: String = ""
    private(set) var ahead: Int = 0
    private(set) var behind: Int = 0
    private(set) var files: [GitFileStatus] = []
    private(set) var lastUpdated: Date = .distantPast
    private(set) var errorMessage: String? = nil

    // MARK: Configuration

    private let repoPath: String
    private let pollInterval: Duration

    // MARK: AsyncStream continuation

    private var eventContinuation: AsyncStream<DashboardEvent>.Continuation?

    // MARK: Polling task

    /// The currently running polling task, if any. Held so it can be cancelled
    /// when `suspend()` or `stop()` is called.
    private var pollingTask: Task<Void, Never>? = nil

    // MARK: Init

    init(repoPath: String = ".", pollInterval: Duration = .seconds(2)) {
        self.repoPath = repoPath
        self.pollInterval = pollInterval
    }

    // MARK: Public API

    /// Returns an `AsyncStream` of `DashboardEvent` values.
    /// Call `start()` to begin polling; the stream ends when the actor is
    /// deallocated or `stop()` is called.
    nonisolated func makeEventStream() -> AsyncStream<DashboardEvent> {
        // The continuation is stored via a separate async call below.
        let (stream, continuation) = AsyncStream<DashboardEvent>.makeStream()
        Task { await self.storeContinuation(continuation) }
        return stream
    }

    /// Starts the polling loop. Safe to call multiple times (subsequent calls
    /// are no-ops if a polling task is already running).
    func start() {
        guard pollingTask == nil else { return }
        pollingTask = Task { await runLoop() }
    }

    /// Stops the polling loop and finishes the event stream.
    func stop() {
        pollingTask?.cancel()
        pollingTask = nil
        eventContinuation?.finish()
        eventContinuation = nil
    }

    /// Suspends polling without closing the event stream. The actor's state
    /// (branch, files, etc.) is preserved so the UI continues to reflect the
    /// last known status until `resume()` is called.
    func suspend() {
        pollingTask?.cancel()
        pollingTask = nil
    }

    /// Resumes polling after a `suspend()`. Safe to call when not suspended
    /// (no-op if a polling task is already running).
    func resume() {
        guard pollingTask == nil else { return }
        pollingTask = Task { await runLoop() }
    }

    // MARK: Private helpers

    private func storeContinuation(_ continuation: AsyncStream<DashboardEvent>.Continuation) {
        self.eventContinuation = continuation
    }

    private func runLoop() async {
        while !Task.isCancelled {
            await poll()
            try? await Task.sleep(for: pollInterval)
        }
    }

    private func poll() async {
        let result = await runGitStatus(in: repoPath)
        switch result {
        case .failure(let err):
            switch err {
            case .gitNotFound:
                errorMessage = "git binary not found in PATH."
            case .launchFailed(let msg):
                errorMessage = "Failed to launch git: \(msg)"
            case .notARepository(let path):
                errorMessage = "Not a git repository: \(path)"
            case .gitFailed(let code, let msg):
                errorMessage = "git exited \(code): \(msg)"
            }
            lastUpdated = Date()
        case .success(let output):
            errorMessage = nil
            let parsed = parse(output: output)
            let previousBehind = self.behind
            let previousFileCount = self.files.count

            branch = parsed.branch
            ahead = parsed.ahead
            behind = parsed.behind
            files = parsed.files
            lastUpdated = Date()

            // Emit events for significant changes
            if parsed.behind > 0 && previousBehind == 0 {
                emit(.init(
                    source: .git,
                    severity: .warning,
                    message: "Branch is behind remote by \(parsed.behind) commit(s).",
                    timestamp: Date()
                ))
            } else if parsed.files.count != previousFileCount {
                emit(.init(
                    source: .git,
                    severity: .info,
                    message: "Working tree changed: \(parsed.files.count) file(s) modified.",
                    timestamp: Date()
                ))
            }
        }
    }

    private func emit(_ event: DashboardEvent) {
        eventContinuation?.yield(event)
    }

    // MARK: - git subprocess

    /// Runs `git status --porcelain=v2 --branch` in `directory` and returns
    /// the raw stdout on success or a `GitDataSourceError` on failure.
    private func runGitStatus(in directory: String) async -> Result<String, GitDataSourceError> {
        // Resolve git binary
        guard let gitPath = findGitBinary() else {
            return .failure(.gitNotFound)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: gitPath)
        process.arguments = ["status", "--porcelain=v2", "--branch"]
        process.currentDirectoryURL = URL(fileURLWithPath: directory)

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        do {
            try process.run()
        } catch {
            return .failure(.launchFailed(error.localizedDescription))
        }

        // Wait for completion on a background thread to avoid blocking the actor.
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            process.terminationHandler = { _ in continuation.resume() }
        }

        let exitCode = process.terminationStatus
        guard exitCode == 0 else {
            let errData = stderr.fileHandleForReading.readDataToEndOfFile()
            let errText = String(decoding: errData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            if errText.contains("not a git repository") || exitCode == 128 {
                return .failure(.notARepository(directory))
            }
            return .failure(.gitFailed(exitCode, errText))
        }

        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        return .success(String(decoding: data, as: UTF8.self))
    }

    /// Searches common locations for the `git` binary.
    private func findGitBinary() -> String? {
        let candidates = ["/usr/bin/git", "/usr/local/bin/git", "/opt/homebrew/bin/git"]
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        return nil
    }

    // MARK: - Porcelain v2 parser

    private struct ParsedStatus {
        var branch: String = ""
        var ahead: Int = 0
        var behind: Int = 0
        var files: [GitFileStatus] = []
    }

    private func parse(output: String) -> ParsedStatus {
        var result = ParsedStatus()

        for line in output.components(separatedBy: "\n") {
            guard !line.isEmpty else { continue }

            if line.hasPrefix("# branch.head ") {
                result.branch = String(line.dropFirst("# branch.head ".count))
            } else if line.hasPrefix("# branch.ab ") {
                let ab = String(line.dropFirst("# branch.ab ".count))
                result.ahead = parseAhead(from: ab)
                result.behind = parseBehind(from: ab)
            } else if line.hasPrefix("1 ") || line.hasPrefix("2 ") {
                // Ordinary changed entry or rename/copy entry.
                // Format: `XY sub mH mI mW hH hI path` (and for type 2: `\t origPath`)
                let columns = line.split(separator: " ", maxSplits: 8, omittingEmptySubsequences: false)
                guard columns.count >= 9 else { continue }
                let xy = columns[1]
                guard xy.count >= 2 else { continue }
                let x = xy[xy.startIndex]
                let y = xy[xy.index(xy.startIndex, offsetBy: 1)]
                // For renamed files the path field is `newPath\torigPath`
                let rawPath = String(columns[8])
                let path = rawPath.components(separatedBy: "\t").first ?? rawPath
                result.files.append(GitFileStatus(path: path, stagedFlag: x, worktreeFlag: y))
            } else if line.hasPrefix("? ") {
                // Untracked file
                let path = String(line.dropFirst(2))
                result.files.append(GitFileStatus(path: path, stagedFlag: "?", worktreeFlag: "?"))
            } else if line.hasPrefix("u ") {
                // Unmerged entry — treat both flags as 'u'
                let columns = line.split(separator: " ", maxSplits: 11, omittingEmptySubsequences: false)
                guard columns.count >= 11 else { continue }
                let rawPath = String(columns[10])
                let path = rawPath.components(separatedBy: "\t").first ?? rawPath
                result.files.append(GitFileStatus(path: path, stagedFlag: "u", worktreeFlag: "u"))
            }
        }

        return result
    }

    /// Parses ahead count from a `+N -N` string.
    private func parseAhead(from ab: String) -> Int {
        // ab looks like "+3 -1"
        let parts = ab.split(separator: " ")
        guard let first = parts.first, first.hasPrefix("+") else { return 0 }
        return Int(first.dropFirst()) ?? 0
    }

    /// Parses behind count from a `+N -N` string.
    private func parseBehind(from ab: String) -> Int {
        let parts = ab.split(separator: " ")
        guard parts.count >= 2 else { return 0 }
        let second = parts[1]
        guard second.hasPrefix("-") else { return 0 }
        return Int(second.dropFirst()) ?? 0
    }
}

// MARK: - Observable wrapper

/// A `@MainActor` `ObservableObject` that owns a `GitDataSource` actor and
/// mirrors its state onto `@Published` properties for use in SwiftTUI views.
@MainActor
final class GitState: ObservableObject {

    @Published var branch: String = ""
    @Published var ahead: Int = 0
    @Published var behind: Int = 0
    @Published var files: [GitFileStatus] = []
    @Published var lastUpdated: Date = .distantPast
    @Published var errorMessage: String? = nil

    private let source: GitDataSource
    private var pollingTask: Task<Void, Never>?
    private var eventTask: Task<Void, Never>?

    /// Owns the display sleep/wake notification subscription for the lifetime
    /// of the state object. Set via `attachSleepWakeMonitor()`.
    private var sleepWakeMonitor: SleepWakeMonitor? = nil

    /// `onEvent` is called on the `MainActor` whenever the data source emits
    /// a `DashboardEvent` (e.g. for use by the coordinator).
    var onEvent: (@MainActor (DashboardEvent) -> Void)?

    init(repoPath: String = ".", pollInterval: Duration = .seconds(2)) {
        self.source = GitDataSource(repoPath: repoPath, pollInterval: pollInterval)
    }

    /// Starts polling and subscribes to the event stream.
    func start() {
        let eventStream = source.makeEventStream()

        // Polling loop
        pollingTask = Task { [weak self] in
            guard let self else { return }
            await self.source.start()
        }

        // State-sync loop — reads actor state after each event so @Published
        // properties stay in sync. We also poll state periodically in the
        // absence of events via a separate timer task.
        eventTask = Task { [weak self] in
            guard let self else { return }
            for await event in eventStream {
                await self.syncState()
                self.onEvent?(event)
            }
        }

        // Kick off a periodic sync independent of events (covers the first
        // poll and subsequent refreshes that don't emit events).
        Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                await self?.syncState()
            }
        }
    }

    /// Stops polling and cancels background tasks.
    func stop() {
        pollingTask?.cancel()
        eventTask?.cancel()
        Task { await source.stop() }
    }

    /// Suspends the underlying data source's polling. The published state is
    /// preserved so the UI still shows the last known status.
    func suspend() {
        Task { await source.suspend() }
    }

    /// Resumes the underlying data source's polling after a `suspend()`.
    func resume() {
        Task { await source.resume() }
    }

    /// Creates and starts a `SleepWakeMonitor` whose callbacks suspend and
    /// resume this data source. The monitor is retained by the state for the
    /// lifetime of the run. Safe to call multiple times (no-op if already
    /// attached).
    func attachSleepWakeMonitor() {
        guard sleepWakeMonitor == nil else { return }
        let monitor = SleepWakeMonitor()
        monitor.onSleep = { [weak self] in
            self?.suspend()
        }
        monitor.onWake = { [weak self] in
            self?.resume()
        }
        monitor.start()
        sleepWakeMonitor = monitor
    }

    // MARK: - Private

    private func syncState() async {
        let b = await source.branch
        let a = await source.ahead
        let bh = await source.behind
        let f = await source.files
        let lu = await source.lastUpdated
        let err = await source.errorMessage

        branch = b
        ahead = a
        behind = bh
        files = f
        lastUpdated = lu
        errorMessage = err
    }
}
