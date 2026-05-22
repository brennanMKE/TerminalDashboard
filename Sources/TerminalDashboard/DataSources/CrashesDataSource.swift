import Foundation

// MARK: - Model

/// Metadata for a single crash/diagnostic report file.
struct CrashReport: Sendable, Identifiable {
    /// Filename (not the full path).
    let filename: String
    /// File modification date.
    let date: Date
    /// Whether this file's name matches the configured app filter.
    let matchesFilter: Bool
    /// The file extension without the leading dot (e.g. `"ips"`, `"crash"`, `"hang"`).
    let fileExtension: String

    var id: String { filename }
}

// MARK: - Actor

/// Watches the two macOS crash-log directories for new diagnostic files and
/// emits `DashboardEvent` values when files appear.
///
/// - Uses `DispatchSource.makeFileSystemObjectSource` for real-time notification
///   when a watched directory exists.
/// - Falls back to ≤5-second polling for directories that do not exist yet.
actor CrashesDataSource {

    // MARK: Monitored extensions

    private static let watchedExtensions: Set<String> = [
        "ips", "crash", "hang", "spin",
        "cpu_resource", "wakeups_resource", "diag", "panic",
    ]

    // MARK: Watched directories

    private static let watchedPaths: [String] = {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return [
            (home as NSString).appendingPathComponent("Library/Logs/DiagnosticReports"),
            "/Library/Logs/DiagnosticReports",
        ]
    }()

    // MARK: State (actor-isolated)

    private(set) var matchedReports: [CrashReport] = []
    private(set) var unmatchedReports: [CrashReport] = []
    private(set) var appFilter: String? = nil
    private(set) var errorMessage: String? = nil

    // MARK: Internal bookkeeping

    /// Filenames already seen — prevents duplicate events on re-scan.
    private var knownFiles: Set<String> = []

    /// Active `DispatchSource` objects for directories that exist at start.
    /// Stored as `AnyObject` to avoid the non-`Sendable` `DispatchSourceFileSystemObject` type.
    private var dispatchSources: [AnyObject] = []

    // MARK: AsyncStream

    private var eventContinuation: AsyncStream<DashboardEvent>.Continuation?

    // MARK: Configuration

    private let appFilterRaw: String?
    private let pollInterval: Duration

    // MARK: Init

    init(appFilter: String? = nil, pollInterval: Duration = .seconds(5)) {
        self.appFilterRaw = appFilter
        self.appFilter = appFilter
        self.pollInterval = pollInterval
    }

    // MARK: Public API

    /// Returns an `AsyncStream` of `DashboardEvent` values emitted by this source.
    nonisolated func makeEventStream() -> AsyncStream<DashboardEvent> {
        let (stream, continuation) = AsyncStream<DashboardEvent>.makeStream()
        Task { await self.storeContinuation(continuation) }
        return stream
    }

    /// Starts watching directories and performs an initial scan.
    func start() {
        Task { await runWatcher() }
    }

    /// Stops all watchers and finishes the event stream.
    func stop() {
        cancelDispatchSources()
        eventContinuation?.finish()
        eventContinuation = nil
    }

    // MARK: Private helpers

    private func storeContinuation(_ continuation: AsyncStream<DashboardEvent>.Continuation) {
        self.eventContinuation = continuation
    }

    private func runWatcher() async {
        // Initial scan of all existing files.
        for path in CrashesDataSource.watchedPaths {
            scanDirectory(at: path, emitEvents: false)
        }

        // Set up DispatchSource watchers for directories that currently exist.
        for path in CrashesDataSource.watchedPaths {
            attachDispatchSource(for: path)
        }

        // Polling loop — handles directories that may appear after launch and
        // surfaces any files missed between DispatchSource notifications.
        while !Task.isCancelled {
            try? await Task.sleep(for: pollInterval)
            for path in CrashesDataSource.watchedPaths {
                scanDirectory(at: path, emitEvents: true)
                // If we didn't manage to attach a source at startup, try again.
                attachDispatchSourceIfNeeded(for: path)
            }
        }
    }

    // MARK: - DispatchSource

    /// Attaches a `DispatchSource` watcher to `path` if the directory exists
    /// and we haven't already attached one for it.
    private func attachDispatchSource(for path: String) {
        guard FileManager.default.fileExists(atPath: path) else { return }

        // Guard against double-registration (actor is re-entrant between awaits
        // but `attachDispatchSource` is called only from synchronous context).
        let alreadyWatching = dispatchSources.contains { obj in
            // We tagged each source's handle via a wrapper — check by casting.
            (obj as? DispatchSourceWrapper)?.path == path
        }
        guard !alreadyWatching else { return }

        guard let fd = openDirectory(at: path) else { return }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: .write,          // directory content changed
            queue: DispatchQueue.global()
        )

        let wrapper = DispatchSourceWrapper(source: source, fd: fd, path: path)

        source.setEventHandler { [weak self] in
            guard let self else { return }
            Task {
                await self.scanDirectory(at: path, emitEvents: true)
            }
        }

        source.setCancelHandler {
            close(fd)
        }

        source.resume()
        dispatchSources.append(wrapper)
    }

    private func attachDispatchSourceIfNeeded(for path: String) {
        let alreadyWatching = dispatchSources.contains { obj in
            (obj as? DispatchSourceWrapper)?.path == path
        }
        guard !alreadyWatching else { return }
        attachDispatchSource(for: path)
    }

    private func cancelDispatchSources() {
        for obj in dispatchSources {
            (obj as? DispatchSourceWrapper)?.source.cancel()
        }
        dispatchSources.removeAll()
    }

    private func openDirectory(at path: String) -> Int32? {
        let fd = open(path, O_EVTONLY)
        return fd >= 0 ? fd : nil
    }

    // MARK: - Directory scanning

    /// Scans `path` for diagnostic files. When `emitEvents` is `true`, files
    /// not previously seen trigger `DashboardEvent` emissions and state updates.
    private func scanDirectory(at path: String, emitEvents: Bool) {
        guard FileManager.default.fileExists(atPath: path) else { return }

        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(atPath: path) else {
            errorMessage = "Cannot read directory: \(path)"
            return
        }
        errorMessage = nil

        var didChange = false

        for filename in entries {
            let ext = (filename as NSString).pathExtension.lowercased()
            guard CrashesDataSource.watchedExtensions.contains(ext) else { continue }
            guard !knownFiles.contains(filename) else { continue }

            // New file discovered.
            knownFiles.insert(filename)

            let fullPath = (path as NSString).appendingPathComponent(filename)
            let modDate = modificationDate(of: fullPath) ?? Date()
            let matches = matchesAppFilter(filename)

            let report = CrashReport(
                filename: filename,
                date: modDate,
                matchesFilter: matches,
                fileExtension: ext
            )

            if matches {
                matchedReports.append(report)
                matchedReports.sort { $0.date > $1.date }
            } else {
                unmatchedReports.append(report)
                unmatchedReports.sort { $0.date > $1.date }
            }

            didChange = true

            if emitEvents {
                let severity: Severity = matches ? .critical : .info
                let message: String
                if matches {
                    message = "Crash report for \(appFilterRaw ?? "app"): \(filename)"
                } else {
                    message = "New diagnostic report: \(filename)"
                }
                emit(DashboardEvent(
                    source: .crashes,
                    severity: severity,
                    message: message,
                    timestamp: modDate
                ))
            }
        }

        // Suppress unused-variable warning.
        _ = didChange
    }

    // MARK: - Helpers

    private func matchesAppFilter(_ filename: String) -> Bool {
        guard let filter = appFilterRaw, !filter.isEmpty else { return false }
        return filename.lowercased().hasPrefix(filter.lowercased())
    }

    private func modificationDate(of path: String) -> Date? {
        let attrs = try? FileManager.default.attributesOfItem(atPath: path)
        return attrs?[.modificationDate] as? Date
    }

    private func emit(_ event: DashboardEvent) {
        eventContinuation?.yield(event)
    }
}

// MARK: - DispatchSource wrapper

/// A simple reference-type wrapper so we can store `DispatchSourceFileSystemObject`
/// (which is non-`Sendable`) inside an actor without triggering Swift 6 diagnostics.
/// The wrapper is only ever accessed from within the actor's isolation domain.
private final class DispatchSourceWrapper: @unchecked Sendable {
    let source: any DispatchSourceFileSystemObject
    let fd: Int32
    let path: String

    nonisolated init(source: any DispatchSourceFileSystemObject, fd: Int32, path: String) {
        self.source = source
        self.fd = fd
        self.path = path
    }
}

// MARK: - Observable wrapper

/// A `@MainActor` `ObservableObject` that owns a `CrashesDataSource` actor and
/// mirrors its state onto `@Published` properties for use in SwiftTUI views.
@MainActor
final class CrashesState: ObservableObject {

    @Published var matchedReports: [CrashReport] = []
    @Published var unmatchedReports: [CrashReport] = []
    @Published var appFilter: String? = nil
    @Published var errorMessage: String? = nil

    private let source: CrashesDataSource
    private var watchTask: Task<Void, Never>?
    private var eventTask: Task<Void, Never>?

    /// Called on the `MainActor` whenever the data source emits a `DashboardEvent`.
    var onEvent: (@MainActor (DashboardEvent) -> Void)?

    init(appFilter: String? = nil, pollInterval: Duration = .seconds(5)) {
        self.source = CrashesDataSource(appFilter: appFilter, pollInterval: pollInterval)
        self.appFilter = appFilter
    }

    /// Starts the filesystem watcher and subscribes to the event stream.
    func start() {
        let eventStream = source.makeEventStream()

        watchTask = Task { [weak self] in
            guard let self else { return }
            await self.source.start()
        }

        eventTask = Task { [weak self] in
            guard let self else { return }
            for await event in eventStream {
                await self.syncState()
                self.onEvent?(event)
            }
        }

        // Periodic sync independent of events to catch the initial scan.
        Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                await self?.syncState()
            }
        }
    }

    /// Stops the watcher and cancels background tasks.
    func stop() {
        watchTask?.cancel()
        eventTask?.cancel()
        Task { await source.stop() }
    }

    // MARK: - Private

    private func syncState() async {
        let matched = await source.matchedReports
        let unmatched = await source.unmatchedReports
        let filter = await source.appFilter
        let err = await source.errorMessage

        matchedReports = matched
        unmatchedReports = unmatched
        appFilter = filter
        errorMessage = err
    }
}
