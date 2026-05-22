import Foundation
import SwiftTUI

// MARK: - Supporting error type

private enum GitViewError: Error {
    case message(String)
}

extension GitViewError: CustomStringConvertible {
    var description: String {
        switch self {
        case .message(let s): return s
        }
    }
}

// MARK: - GitView

/// Renders the git working-tree dashboard: header, file list, and footer.
///
/// Commands are entered into the command field and confirmed with Return:
///   p — git push (with diverge-confirm if behind > 0)
///   u — git pull --ff-only
///   r — git pull --rebase
///   o — launch configured external tool (fire-and-forget)
struct GitView: View {

    @ObservedObject var state: GitState
    let config: GitConfig?

    /// Non-nil while waiting for the user to confirm a push against a diverged branch.
    @State private var confirmingPush: Bool = false

    /// Footer message from the last git operation (success or error).
    @State private var operationResult: String = ""

    var body: some View {
        GeometryReader { size in
            GitContentView(
                state: state,
                config: config,
                terminalHeight: size.height == .infinity ? 24 : size.height.intValue,
                confirmingPush: $confirmingPush,
                operationResult: $operationResult
            )
        }
    }
}

// MARK: - GitContentView

/// Full dashboard layout: header + file list + footer + command input.
private struct GitContentView: View {

    let state: GitState
    let config: GitConfig?
    let terminalHeight: Int
    let confirmingPush: Binding<Bool>
    let operationResult: Binding<String>

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
            TextField(placeholder: confirmingPush.wrappedValue ? "y/n" : "p/u/r/o") { cmd in
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
            operationResult.wrappedValue = "Unknown command '\(first)'. Use: p push  u pull  r rebase  o tool"
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
                operationResult.wrappedValue = "Error: \(err)"
            }
        }
    }

    private static func runGit(
        args: [String],
        repoPath: String
    ) async -> Result<String, GitViewError> {
        guard let gitPath = findGitBinary() else {
            return .failure(.message("git binary not found"))
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
            return .failure(.message("Failed to launch: \(error.localizedDescription)"))
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
            return .failure(.message(err.isEmpty ? "exit \(exitCode)" : err))
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
