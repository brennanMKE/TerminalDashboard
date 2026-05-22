import ArgumentParser
import SwiftTUI

struct GitCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "git",
        abstract: "Display the Git status dashboard."
    )

    // MARK: - Options

    /// Path to a custom configuration file (mirrors the root --config flag).
    @Option(name: .long, help: "Path to a custom configuration file.")
    var config: String? = nil

    /// Override the repository path from config.
    @Option(name: .long, help: "Path to the git repository (overrides config).")
    var repo: String? = nil

    /// Override the external tool command from config.
    @Option(name: .long, help: "External tool command template; use {dir} for the repo path (overrides config).")
    var tool: String? = nil

    // MARK: - Run

    mutating func run() throws {
        // 1. Load config (nonisolated — pure file I/O)
        var cfg = Config.load(override: config)

        // 2. Merge CLI flags over config values
        if repo != nil || tool != nil {
            cfg.git = GitConfig(
                repo: repo ?? cfg.git?.repo,
                tool: tool ?? cfg.git?.tool
            )
        }

        let gitConfig = cfg.git
        let repoPath = gitConfig?.repo ?? "."

        // 3. Create state and start on MainActor.
        //    ParsableCommand.run() is called on the main thread by ArgumentParser,
        //    so MainActor.assumeIsolated is safe here.
        let state = MainActor.assumeIsolated {
            let s = GitState(repoPath: repoPath)
            s.start()
            return s
        }

        // 4. Launch the TUI — Application.start() calls dispatchMain() and never returns.
        //    Construct the Application on MainActor since the View conformance is isolated.
        MainActor.assumeIsolated {
            Application(rootView: GitDashboardView(state: state, config: gitConfig)).start()
        }
    }
}
