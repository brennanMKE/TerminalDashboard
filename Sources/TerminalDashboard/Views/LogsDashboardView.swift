import Foundation
import SwiftTUI

/// Full-screen root view for `tuidash logs`.
///
/// Wraps the live log stream layout and provides help overlay
/// toggling via the command field (type `h` + Return).
struct LogsDashboardView: View {

    @ObservedObject var state: LogsState
    let config: LogsConfig?

    @State private var showHelp: Bool = false

    var body: some View {
        if showHelp {
            HelpOverlay(
                isDedicatedMode: true,
                activeView: .logs,
                onDismiss: { showHelp = false }
            )
        } else {
            LogsDashboardContent(
                state: state,
                config: config,
                onHelp: { showHelp = true }
            )
        }
    }
}

// MARK: - LogsDashboardContent

private struct LogsDashboardContent: View {

    @ObservedObject var state: LogsState
    let config: LogsConfig?
    let onHelp: () -> Void

    var body: some View {
        GeometryReader { size in
            LogsDashboardContentInner(
                state: state,
                config: config,
                terminalHeight: size.height == .infinity ? 24 : size.height.intValue,
                onHelp: onHelp
            )
        }
    }
}

// MARK: - LogsDashboardContentInner

private struct LogsDashboardContentInner: View {

    let state: LogsState
    let config: LogsConfig?
    let terminalHeight: Int
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
            TextField(placeholder: "p pause  c clear  h help") { cmd in
                handleCommand(cmd.trimmingCharacters(in: .whitespaces))
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    // MARK: Command dispatch

    private func handleCommand(_ cmd: String) {
        guard let first = cmd.first else { return }
        switch first {
        case "h":
            onHelp()
        case "p", " ":
            state.togglePause()
        case "c":
            state.clear()
        default:
            break
        }
    }
}
