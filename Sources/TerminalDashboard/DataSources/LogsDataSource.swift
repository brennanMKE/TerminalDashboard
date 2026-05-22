import Foundation

// MARK: - Model

enum LogLevel: Sendable {
    case debug
    case info
    case notice
    case warning
    case error
    case fault
}

struct LogEntry: Sendable, Identifiable {
    let id: UUID
    let timestamp: String
    let level: LogLevel
    let subsystem: String
    let category: String
    let message: String
}

// MARK: - Errors

enum LogsDataSourceError: Error, Sendable {
    case logBinaryNotFound
    case noSubsystemConfigured
    case launchFailed(String)
}

// MARK: - Actor

/// Streams `log stream --style ndjson` output, parses each JSON line, and
/// emits `DashboardEvent` values. Maintains a ring buffer of up to 1000
/// recent `LogEntry` values.
actor LogsDataSource {

    // MARK: Ring-buffer capacity

    private static let ringBufferCapacity = 1000

    // MARK: State (actor-isolated)

    private(set) var entries: [LogEntry] = []
    private(set) var errorMessage: String? = nil

    // MARK: Configuration

    private let config: LogsConfig

    // MARK: Subprocess

    private var process: Process?
    private var readingTask: Task<Void, Never>?

    // MARK: Debounce

    /// The last time a `.error` severity `DashboardEvent` was emitted.
    private var lastErrorEventDate: Date = .distantPast
    private static let errorDebounceInterval: TimeInterval = 10

    // MARK: AsyncStream

    private var eventContinuation: AsyncStream<DashboardEvent>.Continuation?

    // MARK: Init

    init(config: LogsConfig) {
        self.config = config
    }

    // MARK: Public API

    /// Returns an `AsyncStream` of `DashboardEvent` values emitted by this source.
    nonisolated func makeEventStream() -> AsyncStream<DashboardEvent> {
        let (stream, continuation) = AsyncStream<DashboardEvent>.makeStream()
        Task { await self.storeContinuation(continuation) }
        return stream
    }

    /// Validates configuration, launches the `log stream` subprocess, and
    /// begins reading output asynchronously. Safe to call once.
    func start() {
        // Validate: subsystem required
        guard let subsystem = config.subsystem, !subsystem.isEmpty else {
            errorMessage = "No subsystem configured. Set `subsystem` in [logs] config."
            return
        }

        // Validate: `log` binary must exist
        guard let logPath = findLogBinary() else {
            errorMessage = "`log` binary not found at /usr/bin/log."
            return
        }

        // Build argument list
        var arguments = ["stream", "--style", "ndjson", "--subsystem", subsystem]

        if let categories = config.categories, !categories.isEmpty {
            // Combine multiple categories with a predicate
            let categoryPredicates = categories
                .map { "category == \"\($0)\"" }
                .joined(separator: " OR ")
            arguments += ["--predicate", categoryPredicates]
        }

        if let process = config.process, !process.isEmpty {
            arguments += ["--process", process]
        }

        if let level = config.level, !level.isEmpty {
            arguments += ["--level", level]
        }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: logPath)
        proc.arguments = arguments

        let stdout = Pipe()
        let stderr = Pipe()
        proc.standardOutput = stdout
        proc.standardError = stderr

        do {
            try proc.run()
        } catch {
            errorMessage = "Failed to launch `log stream`: \(error.localizedDescription)"
            return
        }

        self.process = proc
        errorMessage = nil

        // Read stdout asynchronously line by line
        let fileHandle = stdout.fileHandleForReading
        readingTask = Task { [weak self] in
            guard let self else { return }
            await self.readLines(from: fileHandle)
        }
    }

    /// Terminates the subprocess and finishes the event stream.
    func stop() {
        readingTask?.cancel()
        readingTask = nil
        if let proc = process, proc.isRunning {
            proc.terminate()
        }
        process = nil
        eventContinuation?.finish()
        eventContinuation = nil
    }

    // MARK: Private helpers

    private func storeContinuation(_ continuation: AsyncStream<DashboardEvent>.Continuation) {
        self.eventContinuation = continuation
    }

    /// Reads `fileHandle` line by line until the handle is exhausted or the
    /// task is cancelled, then processes each line.
    private func readLines(from fileHandle: FileHandle) async {
        // Accumulate bytes until we see a newline, then process the line.
        var buffer = Data()
        let newline = UInt8(ascii: "\n")

        while !Task.isCancelled {
            // availableData returns an empty Data when the pipe is closed.
            let chunk = fileHandle.availableData
            guard !chunk.isEmpty else {
                // Pipe closed — process any remaining data then exit
                if !buffer.isEmpty {
                    processLine(buffer)
                }
                break
            }

            buffer.append(chunk)

            // Extract complete lines from the buffer
            while let nlIndex = buffer.firstIndex(of: newline) {
                let lineData = buffer[buffer.startIndex..<nlIndex]
                buffer = buffer[buffer.index(after: nlIndex)...]
                processLine(lineData)
            }
        }
    }

    /// Parses a single ndjson line and appends the resulting `LogEntry`,
    /// then emits a `DashboardEvent` if appropriate.
    private func processLine(_ data: Data) {
        guard !data.isEmpty else { return }
        guard let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return
        }

        let timestamp = (parsed["timestamp"] as? String) ?? ""
        let messageType = (parsed["messageType"] as? String) ?? "Default"
        let subsystem = (parsed["subsystem"] as? String) ?? ""
        let category = (parsed["category"] as? String) ?? ""
        let message = (parsed["eventMessage"] as? String) ?? ""

        let level = mapLevel(messageType)

        let entry = LogEntry(
            id: UUID(),
            timestamp: timestamp,
            level: level,
            subsystem: subsystem,
            category: category,
            message: message
        )

        appendEntry(entry)
        maybeEmitEvent(for: entry)
    }

    /// Appends an entry to the ring buffer, evicting the oldest when at capacity.
    private func appendEntry(_ entry: LogEntry) {
        entries.append(entry)
        if entries.count > LogsDataSource.ringBufferCapacity {
            entries.removeFirst(entries.count - LogsDataSource.ringBufferCapacity)
        }
    }

    /// Emits a `DashboardEvent` based on the entry's log level.
    /// Error/fault events are debounced to at most one per 10 seconds.
    private func maybeEmitEvent(for entry: LogEntry) {
        let now = Date()
        switch entry.level {
        case .error, .fault:
            let elapsed = now.timeIntervalSince(lastErrorEventDate)
            guard elapsed >= LogsDataSource.errorDebounceInterval else { return }
            lastErrorEventDate = now
            emit(DashboardEvent(
                source: .logs,
                severity: .error,
                message: entry.message.isEmpty ? "Error/fault log entry." : entry.message,
                timestamp: now
            ))
        case .warning:
            emit(DashboardEvent(
                source: .logs,
                severity: .warning,
                message: entry.message.isEmpty ? "Warning log entry." : entry.message,
                timestamp: now
            ))
        case .notice:
            emit(DashboardEvent(
                source: .logs,
                severity: .info,
                message: entry.message.isEmpty ? "Notice log entry." : entry.message,
                timestamp: now
            ))
        case .debug, .info:
            emit(DashboardEvent(
                source: .logs,
                severity: .info,
                message: entry.message.isEmpty ? "Log entry." : entry.message,
                timestamp: now
            ))
        }
    }

    private func emit(_ event: DashboardEvent) {
        eventContinuation?.yield(event)
    }

    // MARK: - Level mapping

    /// Maps ndjson `messageType` strings to `LogLevel`.
    private func mapLevel(_ messageType: String) -> LogLevel {
        switch messageType {
        case "Default", "Debug":    return .debug
        case "Info":                return .info
        case "Notice":              return .notice
        case "Warning":             return .warning
        case "Error":               return .error
        case "Fault":               return .fault
        default:                    return .debug
        }
    }

    // MARK: - Binary search

    private func findLogBinary() -> String? {
        let path = "/usr/bin/log"
        return FileManager.default.isExecutableFile(atPath: path) ? path : nil
    }
}

// MARK: - Observable wrapper

/// A `@MainActor` `ObservableObject` that owns a `LogsDataSource` actor and
/// mirrors its state onto `@Published` properties for use in SwiftTUI views.
@MainActor
final class LogsState: ObservableObject {

    @Published var entries: [LogEntry] = []
    @Published var isPaused: Bool = false
    @Published var filterSummary: String = ""
    @Published var errorMessage: String? = nil

    /// Called on the `MainActor` whenever the data source emits a `DashboardEvent`.
    var onEvent: (@MainActor (DashboardEvent) -> Void)?

    private let source: LogsDataSource
    private var streamTask: Task<Void, Never>?
    private var syncTask: Task<Void, Never>?

    /// Buffer for entries received while `isPaused` is `true`.
    private var pauseBuffer: [LogEntry] = []

    init(config: LogsConfig) {
        self.source = LogsDataSource(config: config)
        self.filterSummary = Self.buildFilterSummary(config)
    }

    /// Starts the `log stream` subprocess and subscribes to the event stream.
    func start() {
        let eventStream = source.makeEventStream()

        streamTask = Task { [weak self] in
            guard let self else { return }
            await self.source.start()
        }

        syncTask = Task { [weak self] in
            guard let self else { return }
            for await event in eventStream {
                await self.syncEntries()
                self.onEvent?(event)
            }
        }

        // Periodic sync independent of events
        Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                await self?.syncEntries()
            }
        }
    }

    /// Stops the subprocess and cancels background tasks.
    func stop() {
        streamTask?.cancel()
        syncTask?.cancel()
        Task { await source.stop() }
    }

    /// Resumes delivery of entries: flushes the pause buffer and re-enables live updates.
    func resume() {
        isPaused = false
        if !pauseBuffer.isEmpty {
            // Append buffered entries (respecting capacity)
            let combined = entries + pauseBuffer
            entries = Array(combined.suffix(1000))
            pauseBuffer.removeAll()
        }
    }

    // MARK: - Private

    private func syncEntries() async {
        let sourceEntries = await source.entries
        let err = await source.errorMessage

        errorMessage = err

        if isPaused {
            // Determine which entries are new since last sync and buffer them
            let known = Set(entries.map { $0.id }).union(pauseBuffer.map { $0.id })
            let newEntries = sourceEntries.filter { !known.contains($0.id) }
            pauseBuffer.append(contentsOf: newEntries)
            // Keep pause buffer from growing without bound
            if pauseBuffer.count > 1000 {
                pauseBuffer.removeFirst(pauseBuffer.count - 1000)
            }
        } else {
            entries = sourceEntries
        }
    }

    // MARK: - Filter summary

    private static func buildFilterSummary(_ config: LogsConfig) -> String {
        var parts: [String] = []

        if let subsystem = config.subsystem, !subsystem.isEmpty {
            parts.append("subsystem: \(subsystem)")
        }

        if let categories = config.categories, !categories.isEmpty {
            parts.append("categories: \(categories.joined(separator: ", "))")
        }

        if let process = config.process, !process.isEmpty {
            parts.append("process: \(process)")
        }

        if let level = config.level, !level.isEmpty {
            parts.append("level: \(level)")
        }

        return parts.isEmpty ? "No filters configured" : parts.joined(separator: " | ")
    }
}
