import Foundation
import SwiftTUI

// MARK: - Private error type

private struct AutoGitError: Error {
    let message: String
}

// MARK: - AutoDashboardView

/// Root view for `tuidash auto` (and bare `tuidash`).
///
/// Layout (top to bottom):
///   1. TabBar — always visible; shows active tab, badges, auto-mode indicator, banner.
///   2. Content area — shows the active view's dashboard (Git / Crashes / Logs).
///   3. Help overlay — replaces the entire screen when `showHelp` is true.
///
/// Navigation commands (typed into the active view's command field):
///   g — switch to Git view
///   c — switch to Crashes view
///   l — switch to Logs view
///   a — toggle Auto Mode
///   h — toggle this help overlay
struct AutoDashboardView: View {

    @ObservedObject var coordinator: AutoCoordinator

    // State objects — each observes its data source.
    @ObservedObject var gitState: GitState
    @ObservedObject var crashesState: CrashesState
    @ObservedObject var logsState: LogsState

    // Per-view configs (may be nil when not configured).
    let gitConfig: GitConfig?
    let crashesConfig: CrashesConfig?
    let logsConfig: LogsConfig?

    @State private var showHelp: Bool = false

    var body: some View {
        if showHelp {
            HelpOverlay(
                isDedicatedMode: false,
                activeView: coordinator.activeView,
                onDismiss: { showHelp = false }
            )
        } else {
            AutoDashboardContent(
                coordinator: coordinator,
                gitState: gitState,
                crashesState: crashesState,
                logsState: logsState,
                gitConfig: gitConfig,
                crashesConfig: crashesConfig,
                logsConfig: logsConfig,
                onHelp: { showHelp = true }
            )
        }
    }
}

// MARK: - AutoDashboardContent

/// Composes the TabBar + active view, passing navigation callbacks into each
/// view's command dispatcher via wrapper views.
private struct AutoDashboardContent: View {

    @ObservedObject var coordinator: AutoCoordinator

    @ObservedObject var gitState: GitState
    @ObservedObject var crashesState: CrashesState
    @ObservedObject var logsState: LogsState

    let gitConfig: GitConfig?
    let crashesConfig: CrashesConfig?
    let logsConfig: LogsConfig?

    let onHelp: () -> Void

    var body: some View {
        GeometryReader { size in
            AutoDashboardContentInner(
                coordinator: coordinator,
                gitState: gitState,
                crashesState: crashesState,
                logsState: logsState,
                gitConfig: gitConfig,
                crashesConfig: crashesConfig,
                logsConfig: logsConfig,
                terminalHeight: size.height == .infinity ? 24 : size.height.intValue,
                onHelp: onHelp
            )
        }
    }
}

// MARK: - AutoDashboardContentInner

private struct AutoDashboardContentInner: View {

    @ObservedObject var coordinator: AutoCoordinator

    let gitState: GitState
    let crashesState: CrashesState
    let logsState: LogsState

    let gitConfig: GitConfig?
    let crashesConfig: CrashesConfig?
    let logsConfig: LogsConfig?

    /// Full terminal height (rows) from GeometryReader.
    let terminalHeight: Int

    let onHelp: () -> Void

    /// Height available for the content area below the TabBar (1 row).
    private var contentHeight: Int {
        max(0, terminalHeight - 1)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            TabBar(
                activeView: coordinator.activeView,
                badgeCounts: coordinator.badgeCounts,
                isAutoMode: coordinator.isAutoMode,
                bannerMessage: coordinator.bannerMessage
            )
            contentView
        }
    }

    // MARK: - Content area

    @ViewBuilder
    private var contentView: some View {
        switch coordinator.activeView {
        case .git:
            AutoGitContent(
                state: gitState,
                config: gitConfig,
                terminalHeight: contentHeight,
                onSwitchView: { coordinator.switchToView($0) },
                onToggleAuto: { coordinator.toggleAutoMode() },
                onHelp: onHelp
            )
        case .crashes:
            AutoCrashesContent(
                state: crashesState,
                config: crashesConfig,
                terminalHeight: contentHeight,
                onSwitchView: { coordinator.switchToView($0) },
                onToggleAuto: { coordinator.toggleAutoMode() },
                onHelp: onHelp
            )
        case .logs:
            AutoLogsContent(
                state: logsState,
                config: logsConfig,
                terminalHeight: contentHeight,
                onSwitchView: { coordinator.switchToView($0) },
                onToggleAuto: { coordinator.toggleAutoMode() },
                onHelp: onHelp
            )
        }
    }
}

// MARK: - AutoGitContent

/// Git content view for auto mode.
/// Inherits all Git operations plus navigation shortcuts (g/c/l/a/h).
private struct AutoGitContent: View {

    let state: GitState
    let config: GitConfig?
    let terminalHeight: Int
    let onSwitchView: (DashboardSource) -> Void
    let onToggleAuto: () -> Void
    let onHelp: () -> Void

    // Forwarded push-confirm state.
    @State private var confirmingPush: Bool = false
    @State private var operationResult: String = ""

    var body: some View {
        AutoGitContentInner(
            state: state,
            config: config,
            terminalHeight: terminalHeight,
            confirmingPush: $confirmingPush,
            operationResult: $operationResult,
            onSwitchView: onSwitchView,
            onToggleAuto: onToggleAuto,
            onHelp: onHelp
        )
    }
}

private struct AutoGitContentInner: View {

    let state: GitState
    let config: GitConfig?
    let terminalHeight: Int
    let confirmingPush: Binding<Bool>
    let operationResult: Binding<String>
    let onSwitchView: (DashboardSource) -> Void
    let onToggleAuto: () -> Void
    let onHelp: () -> Void

    // Header (1) + command-input row (1) + footer (1) = 3 chrome rows.
    private static let chromeRows = 3

    private var visibleCount: Int {
        let available = max(0, terminalHeight - Self.chromeRows)
        return min(state.files.count, available)
    }

    private var overflowCount: Int {
        max(0, state.files.count - visibleCount)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            headerRow
            fileListSection
            footerRow
            commandInputRow
        }
    }

    // MARK: Header

    private var headerRow: some View {
        HStack(spacing: 1) {
            Text(repoName).bold()
            Text(branchLabel).foregroundColor(.cyan)
            aheadBehindLabels
            Text(timestampLabel).foregroundColor(.gray)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private var repoName: String {
        let path = config?.repo ?? "."
        let url = URL(fileURLWithPath: path).standardizedFileURL
        let name = url.lastPathComponent
        return name.isEmpty ? path : name
    }

    private var branchLabel: String {
        state.branch.isEmpty ? "(detached)" : state.branch
    }

    private var aheadBehindLabels: some View {
        HStack(spacing: 1) {
            if state.ahead > 0 {
                Text("↑\(state.ahead)").foregroundColor(.green)
            }
            if state.behind > 0 {
                Text("↓\(state.behind)").foregroundColor(.yellow)
            }
        }
    }

    private var timestampLabel: String {
        guard state.lastUpdated != .distantPast else { return "" }
        let fmt = DateFormatter()
        fmt.dateFormat = "HH:mm:ss"
        return fmt.string(from: state.lastUpdated)
    }

    // MARK: File list

    private var fileListSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let err = state.errorMessage {
                Text(err).foregroundColor(.red)
            } else if state.files.isEmpty {
                Text("No changes.").foregroundColor(.gray)
            } else {
                ForEach(Array(state.files.prefix(visibleCount)), id: \.id) { file in
                    fileRow(for: file)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private func fileRow(for file: GitFileStatus) -> some View {
        HStack(spacing: 1) {
            Text(String(file.stagedFlag)).foregroundColor(stagedColor(for: file))
            Text(String(file.worktreeFlag)).foregroundColor(worktreeColor(for: file))
            Text(file.path)
        }
    }

    private func stagedColor(for file: GitFileStatus) -> Color {
        switch file.stagedFlag {
        case "M": return .green
        case "A": return .green
        case "D": return .red
        case "R": return .cyan
        case "C": return .cyan
        case "u": return .red
        default:  return .default
        }
    }

    private func worktreeColor(for file: GitFileStatus) -> Color {
        switch file.worktreeFlag {
        case "M": return .yellow
        case "D": return .red
        case "?": return .gray
        case "u": return .red
        default:  return .default
        }
    }

    // MARK: Footer

    private var footerRow: some View {
        footerContent
            .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private var footerContent: some View {
        let msg = footerMessage
        if overflowCount > 0 {
            let suffix = msg.isEmpty ? "" : "  \(msg)"
            Text("… \(overflowCount) more file(s) not shown\(suffix)")
                .foregroundColor(.gray)
        } else if !msg.isEmpty {
            Text(msg).foregroundColor(footerIsError ? .red : .gray)
        } else {
            Text(" ")
        }
    }

    private var footerMessage: String {
        if !operationResult.wrappedValue.isEmpty { return operationResult.wrappedValue }
        if let err = state.errorMessage { return err }
        return ""
    }

    private var footerIsError: Bool {
        state.errorMessage != nil || operationResult.wrappedValue.hasPrefix("Error:")
    }

    // MARK: Command input

    private var commandInputRow: some View {
        HStack(spacing: 1) {
            Text(">").foregroundColor(.gray)
            TextField(placeholder: confirmingPush.wrappedValue ? "y/n" : "g/c/l/a/p/u/r/o/h") { cmd in
                handleCommand(cmd.trimmingCharacters(in: .whitespaces))
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    // MARK: Command dispatch

    private func handleCommand(_ cmd: String) {
        guard let first = cmd.first else { return }

        if confirmingPush.wrappedValue {
            confirmingPush.wrappedValue = false
            if first == "y" || first == "Y" {
                runOperation(args: ["push"])
            } else {
                operationResult.wrappedValue = "Push cancelled."
            }
            return
        }

        switch first {
        case "g": onSwitchView(.git)
        case "c": onSwitchView(.crashes)
        case "l": onSwitchView(.logs)
        case "a": onToggleAuto()
        case "h": onHelp()
        case "p":
            if state.behind > 0 {
                confirmingPush.wrappedValue = true
                operationResult.wrappedValue =
                    "Branch is behind remote. Type y to push anyway, n to cancel."
            } else {
                runOperation(args: ["push"])
            }
        case "u":
            runOperation(args: ["pull", "--ff-only"])
        case "r":
            runOperation(args: ["pull", "--rebase"])
        case "o":
            launchTool()
        default:
            operationResult.wrappedValue =
                "Unknown command '\(first)'. Use: g/c/l switch  a auto  h help  p push  u pull  r rebase  o tool"
        }
    }

    // MARK: Git subprocess

    private func runOperation(args: [String]) {
        let repoPath = config?.repo ?? "."
        let displayCmd = args.joined(separator: " ")
        operationResult.wrappedValue = "Running git \(displayCmd)…"

        Task { @MainActor in
            let result = await Self.runGit(args: args, repoPath: repoPath)
            switch result {
            case .success(let msg):
                operationResult.wrappedValue = msg.isEmpty ? "Done." : msg
            case .failure(let err):
                operationResult.wrappedValue = "Error: \(err.message)"
            }
        }
    }

    private static func runGit(
        args: [String],
        repoPath: String
    ) async -> Result<String, AutoGitError> {
        guard let gitPath = findGitBinary() else {
            return .failure(AutoGitError(message: "git binary not found"))
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: gitPath)
        process.arguments = args
        process.currentDirectoryURL = URL(fileURLWithPath: repoPath)

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
        } catch {
            return .failure(AutoGitError(message: "Failed to launch: \(error.localizedDescription)"))
        }

        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            process.terminationHandler = { _ in cont.resume() }
        }

        let exitCode = process.terminationStatus
        if exitCode == 0 {
            let data = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
            let out = String(decoding: data, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return .success(out)
        } else {
            let data = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            let err = String(decoding: data, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return .failure(AutoGitError(message: err.isEmpty ? "exit \(exitCode)" : err))
        }
    }

    // MARK: External tool (fire-and-forget)

    private func launchTool() {
        guard let template = config?.tool, !template.isEmpty else {
            operationResult.wrappedValue = "No tool configured."
            return
        }
        let repoPath = config?.repo ?? "."
        let cmd = template.replacingOccurrences(of: "{dir}", with: repoPath)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", cmd]
        process.terminationHandler = { _ in }
        try? process.run()
        operationResult.wrappedValue = "Launched: \(template)"
    }

    // MARK: Helpers

    private static func findGitBinary() -> String? {
        let candidates = [
            "/usr/bin/git",
            "/usr/local/bin/git",
            "/opt/homebrew/bin/git",
        ]
        return candidates.first {
            FileManager.default.isExecutableFile(atPath: $0)
        }
    }
}

// MARK: - AutoCrashesContent

/// Crashes content view for auto mode.
/// Inherits all Crashes operations plus navigation shortcuts (g/c/l/a/h).
private struct AutoCrashesContent: View {

    let state: CrashesState
    let config: CrashesConfig?
    let terminalHeight: Int
    let onSwitchView: (DashboardSource) -> Void
    let onToggleAuto: () -> Void
    let onHelp: () -> Void

    var body: some View {
        AutoCrashesContentInner(
            state: state,
            config: config,
            terminalHeight: terminalHeight,
            onSwitchView: onSwitchView,
            onToggleAuto: onToggleAuto,
            onHelp: onHelp
        )
    }
}

private struct AutoCrashesContentInner: View {

    let state: CrashesState
    let config: CrashesConfig?
    let terminalHeight: Int
    let onSwitchView: (DashboardSource) -> Void
    let onToggleAuto: () -> Void
    let onHelp: () -> Void

    // chrome: command-input row (1) + footer row (1) = 2
    private static let chromeRows = 2

    private var listHeight: Int {
        let available = max(0, terminalHeight - Self.chromeRows)
        return max(1, available * 6 / 10)
    }

    private var detailHeight: Int {
        let available = max(0, terminalHeight - Self.chromeRows)
        return max(1, available - listHeight)
    }

    @State private var selectedIndex: Int = 0
    @State private var detailLines: [String] = []
    @State private var footerMessage: String = ""
    @State private var footerIsError: Bool = false

    private var allReports: [CrashReport] {
        state.matchedReports + state.unmatchedReports
    }

    private var selectedReport: CrashReport? {
        let reports = allReports
        guard !reports.isEmpty, selectedIndex < reports.count else { return nil }
        return reports[selectedIndex]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            listSection
            detailSection
            footerRow
            commandInputRow
        }
        .onAppear {
            loadDetailForCurrent()
        }
    }

    // MARK: - List section

    @ViewBuilder
    private var listSection: some View {
        if let filter = state.appFilter, !filter.isEmpty {
            populatedListSection
        } else {
            notConfiguredSection
        }
    }

    private var notConfiguredSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Not configured — set [crashes] app = \"MyApp\" in .tuidash.toml")
                .foregroundColor(.yellow)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private var populatedListSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            matchedSection
            if !state.unmatchedReports.isEmpty {
                Divider()
                unmatchedSection
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private var matchedSection: some View {
        if state.matchedReports.isEmpty {
            Text("No matched crash reports.").foregroundColor(.gray)
        } else {
            ForEach(Array(state.matchedReports.prefix(listHeight).enumerated()), id: \.offset) { offset, report in
                matchedRow(report: report, listIndex: offset)
            }
        }
    }

    private func matchedRow(report: CrashReport, listIndex: Int) -> some View {
        let isSelected = selectedIndex == listIndex
        return HStack(spacing: 1) {
            Text(isSelected ? ">" : " ").foregroundColor(.cyan)
            Text(report.filename).bold()
            Text(formattedDate(report.date)).foregroundColor(.cyan)
            Text(report.fileExtension).foregroundColor(.gray)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private var unmatchedOffset: Int {
        state.matchedReports.count
    }

    @ViewBuilder
    private var unmatchedSection: some View {
        let remaining = max(0, listHeight - state.matchedReports.count - 1)
        if remaining > 0 {
            ForEach(Array(state.unmatchedReports.prefix(remaining).enumerated()), id: \.offset) { offset, report in
                unmatchedRow(report: report, listIndex: unmatchedOffset + offset)
            }
        }
    }

    private func unmatchedRow(report: CrashReport, listIndex: Int) -> some View {
        let isSelected = selectedIndex == listIndex
        return HStack(spacing: 1) {
            Text(isSelected ? ">" : " ").foregroundColor(.cyan)
            Text(report.filename).foregroundColor(.gray)
            Text(formattedDate(report.date)).foregroundColor(.gray)
            Text(report.fileExtension).foregroundColor(.gray)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    // MARK: - Detail section

    private var detailSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            if detailLines.isEmpty {
                Text("No report selected.").foregroundColor(.gray)
            } else {
                ForEach(Array(detailLines.prefix(detailHeight).enumerated()), id: \.offset) { _, line in
                    Text(line).foregroundColor(.default)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    // MARK: - Footer

    private var footerRow: some View {
        Group {
            if !footerMessage.isEmpty {
                Text(footerMessage)
                    .foregroundColor(footerIsError ? .red : .green)
            } else if let err = state.errorMessage {
                Text(err).foregroundColor(.red)
            } else {
                Text(" ")
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    // MARK: - Command input

    private var commandInputRow: some View {
        HStack(spacing: 1) {
            Text(">").foregroundColor(.gray)
            TextField(placeholder: "g/c/l/a/j/k/e/E/h") { cmd in
                handleCommand(cmd.trimmingCharacters(in: .whitespaces))
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    // MARK: - Command dispatch

    private func handleCommand(_ cmd: String) {
        guard let first = cmd.first else { return }
        let reports = allReports
        switch first {
        case "g": onSwitchView(.git)
        case "c": onSwitchView(.crashes)
        case "l": onSwitchView(.logs)
        case "a": onToggleAuto()
        case "h": onHelp()
        case "j":
            if !reports.isEmpty {
                selectedIndex = min(selectedIndex + 1, reports.count - 1)
                loadDetailForCurrent()
            }
        case "k":
            if !reports.isEmpty {
                selectedIndex = max(selectedIndex - 1, 0)
                loadDetailForCurrent()
            }
        case "e":
            extractSelected()
        case "E":
            extractAllMatched()
        default:
            setFooter("Unknown command '\(first)'. Use: g/c/l switch  a auto  h help  j↓  k↑  e extract  E extract-all", isError: true)
        }
    }

    // MARK: - Selection / detail loading

    private func loadDetailForCurrent() {
        guard let report = selectedReport else {
            detailLines = []
            return
        }
        detailLines = readFirstLines(of: report.filename, count: 20)
    }

    // MARK: - File reading

    private func reportPath(for filename: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return (home as NSString)
            .appendingPathComponent("Library/Logs/DiagnosticReports")
            .appending("/\(filename)")
    }

    private func readFirstLines(of filename: String, count: Int) -> [String] {
        let path = reportPath(for: filename)
        guard let handle = FileHandle(forReadingAtPath: path) else {
            let sysPath = "/Library/Logs/DiagnosticReports/\(filename)"
            guard let sysHandle = FileHandle(forReadingAtPath: sysPath) else { return [] }
            return extractLines(from: sysHandle, count: count)
        }
        return extractLines(from: handle, count: count)
    }

    private func extractLines(from handle: FileHandle, count: Int) -> [String] {
        let data = handle.readData(ofLength: 16_384)
        handle.closeFile()
        let raw = String(decoding: data, as: UTF8.self)
        let lines = raw.components(separatedBy: .newlines)
        return Array(lines.prefix(count))
    }

    // MARK: - Extraction

    private func outputDirectory() -> String {
        config?.output ?? "./crashes"
    }

    private func extract(report: CrashReport) -> Result<String, Error> {
        let srcPath = reportPath(for: report.filename)
        let outDir = outputDirectory()
        let fm = FileManager.default

        do {
            if !fm.fileExists(atPath: outDir) {
                try fm.createDirectory(atPath: outDir, withIntermediateDirectories: true)
            }
            let destPath = (outDir as NSString).appendingPathComponent(report.filename)
            if fm.fileExists(atPath: destPath) {
                try fm.removeItem(atPath: destPath)
            }
            try fm.copyItem(atPath: srcPath, toPath: destPath)
            return .success(destPath)
        } catch {
            return .failure(error)
        }
    }

    private func extractSelected() {
        guard let report = selectedReport else {
            setFooter("No report selected.", isError: true)
            return
        }
        switch extract(report: report) {
        case .success(let dest):
            setFooter("Extracted to \(dest)", isError: false)
        case .failure(let err):
            setFooter("Error: \(err.localizedDescription)", isError: true)
        }
    }

    private func extractAllMatched() {
        let matched = state.matchedReports
        guard !matched.isEmpty else {
            setFooter("No matched reports to extract.", isError: true)
            return
        }
        var succeeded = 0
        var lastError: String?
        for report in matched {
            switch extract(report: report) {
            case .success:
                succeeded += 1
            case .failure(let err):
                lastError = err.localizedDescription
            }
        }
        if let err = lastError, succeeded == 0 {
            setFooter("Error: \(err)", isError: true)
        } else if let err = lastError {
            setFooter("Extracted \(succeeded)/\(matched.count) — last error: \(err)", isError: true)
        } else {
            setFooter("Extracted \(succeeded) report(s) to \(outputDirectory())", isError: false)
        }
    }

    // MARK: - Helpers

    private func setFooter(_ message: String, isError: Bool) {
        footerMessage = message
        footerIsError = isError
    }

    private func formattedDate(_ date: Date) -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd HH:mm"
        return fmt.string(from: date)
    }
}

// MARK: - AutoLogsContent

/// Logs content view for auto mode.
/// Inherits all Logs operations plus navigation shortcuts (g/c/l/a/h).
private struct AutoLogsContent: View {

    let state: LogsState
    let config: LogsConfig?
    let terminalHeight: Int
    let onSwitchView: (DashboardSource) -> Void
    let onToggleAuto: () -> Void
    let onHelp: () -> Void

    var body: some View {
        AutoLogsContentInner(
            state: state,
            config: config,
            terminalHeight: terminalHeight,
            onSwitchView: onSwitchView,
            onToggleAuto: onToggleAuto,
            onHelp: onHelp
        )
    }
}

private struct AutoLogsContentInner: View {

    let state: LogsState
    let config: LogsConfig?
    let terminalHeight: Int
    let onSwitchView: (DashboardSource) -> Void
    let onToggleAuto: () -> Void
    let onHelp: () -> Void

    // chrome: footer row (1) + command-input row (1) = 2
    private static let chromeRows = 2

    private var visibleCount: Int {
        max(0, terminalHeight - Self.chromeRows)
    }

    private var visibleEntries: [LogEntry] {
        let count = visibleCount
        guard count > 0 else { return [] }
        return Array(state.entries.suffix(count))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            logListSection
            footerRow
            commandInputRow
        }
    }

    // MARK: Log list

    @ViewBuilder
    private var logListSection: some View {
        if let err = state.errorMessage, err.contains("subsystem") || err.contains("No subsystem") {
            notConfiguredSection
        } else {
            populatedLogSection
        }
    }

    private var notConfiguredSection: some View {
        Text("Not configured — set [logs] subsystem = \"com.example.app\" in .tuidash.toml")
            .foregroundColor(.yellow)
    }

    @ViewBuilder
    private var populatedLogSection: some View {
        if state.entries.isEmpty {
            Text("Waiting for log entries…").foregroundColor(.gray)
        } else {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(visibleEntries, id: \.id) { entry in
                    logEntryRow(for: entry)
                }
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }

    private func logEntryRow(for entry: LogEntry) -> some View {
        let line = formatEntry(entry)
        return entryText(line, level: entry.level)
    }

    @ViewBuilder
    private func entryText(_ line: String, level: LogLevel) -> some View {
        switch level {
        case .debug:
            Text(line).foregroundColor(.gray)
        case .info:
            Text(line)
        case .notice:
            Text(line).foregroundColor(.cyan)
        case .warning:
            Text(line).foregroundColor(.yellow)
        case .error:
            Text(line).foregroundColor(.red)
        case .fault:
            Text(line).foregroundColor(.red).bold()
        }
    }

    private func formatEntry(_ entry: LogEntry) -> String {
        let levelTag = levelString(entry.level)
        return "[\(entry.timestamp)] [\(levelTag)] \(entry.message)"
    }

    private func levelString(_ level: LogLevel) -> String {
        switch level {
        case .debug:   return "DEBUG"
        case .info:    return "INFO"
        case .notice:  return "NOTICE"
        case .warning: return "WARN"
        case .error:   return "ERROR"
        case .fault:   return "FAULT"
        }
    }

    // MARK: Footer

    private var footerRow: some View {
        HStack(spacing: 1) {
            pauseIndicator
            Text("|").foregroundColor(.gray)
            Text(state.filterSummary).foregroundColor(.gray)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private var pauseIndicator: some View {
        if state.isPaused {
            Text("PAUSED").foregroundColor(.yellow).bold()
        } else {
            Text("LIVE").foregroundColor(.green)
        }
    }

    // MARK: Command input

    private var commandInputRow: some View {
        HStack(spacing: 1) {
            Text(">").foregroundColor(.gray)
            TextField(placeholder: "g/c/l/a/p/h") { cmd in
                handleCommand(cmd.trimmingCharacters(in: .whitespaces))
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    // MARK: Command dispatch

    private func handleCommand(_ cmd: String) {
        guard let first = cmd.first else { return }
        switch first {
        case "g": onSwitchView(.git)
        case "c": onSwitchView(.crashes)
        case "l": onSwitchView(.logs)
        case "a": onToggleAuto()
        case "h": onHelp()
        case "p", " ":
            state.togglePause()
        // Note: "c" is taken by navigation in auto mode; log buffer clear is
        // not available via single-key in auto mode.
        default:
            break
        }
    }
}
