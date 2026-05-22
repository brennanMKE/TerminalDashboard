import Foundation
import SwiftTUI

// MARK: - CrashesView

/// Renders the crashes dashboard: matched reports (bold), unmatched reports (dimmed),
/// a detail pane for the selected report, and a command footer.
///
/// Commands (via TextField + Return):
///   j  — move selection down
///   k  — move selection up
///   e  — extract selected crash to output directory
///   E  — extract all matched crashes
struct CrashesView: View {

    @ObservedObject var state: CrashesState
    let config: CrashesConfig?

    var body: some View {
        GeometryReader { size in
            CrashesContentView(
                state: state,
                config: config,
                terminalHeight: size.height == .infinity ? 24 : size.height.intValue
            )
        }
    }
}

// MARK: - CrashesContentView

private struct CrashesContentView: View {

    let state: CrashesState
    let config: CrashesConfig?
    let terminalHeight: Int

    // chrome: command-input row (1) + footer row (1) = 2
    private static let chromeRows = 2

    // 60 % list, 40 % detail
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

    // MARK: Derived helpers

    private var allReports: [CrashReport] {
        state.matchedReports + state.unmatchedReports
    }

    private var selectedReport: CrashReport? {
        let reports = allReports
        guard !reports.isEmpty, selectedIndex < reports.count else { return nil }
        return reports[selectedIndex]
    }

    // MARK: Body

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

    // MARK: Matched reports

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

    // MARK: Unmatched reports

    private var unmatchedOffset: Int {
        state.matchedReports.count
    }

    @ViewBuilder
    private var unmatchedSection: some View {
        let remaining = max(0, listHeight - state.matchedReports.count - 1) // -1 for divider
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
            TextField(placeholder: "j/k/e/E") { cmd in
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
            setFooter("Unknown command '\(first)'. Use: j↓  k↑  e extract  E extract-all", isError: true)
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
            // Try the system path
            let sysPath = "/Library/Logs/DiagnosticReports/\(filename)"
            guard let sysHandle = FileHandle(forReadingAtPath: sysPath) else { return [] }
            return extractLines(from: sysHandle, count: count)
        }
        return extractLines(from: handle, count: count)
    }

    private func extractLines(from handle: FileHandle, count: Int) -> [String] {
        // Read up to 16 KB which is plenty for the first 20 lines of any crash file.
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
