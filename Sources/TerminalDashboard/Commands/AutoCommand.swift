import ArgumentParser
import SwiftTUI

struct AutoCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "auto",
        abstract: "Automatically surface the most relevant dashboard view based on event severity."
    )

    // MARK: - Options

    /// Path to a custom configuration file (mirrors the root --config flag).
    @Option(name: .long, help: "Path to a custom configuration file.")
    var config: String? = nil

    // Git overrides

    /// Override the repository path from config.
    @Option(name: .long, help: "Path to the git repository (overrides config).")
    var repo: String? = nil

    /// Override the external tool command from config.
    @Option(name: .long, help: "External tool command template; use {dir} for the repo path (overrides config).")
    var tool: String? = nil

    // Crashes overrides

    /// Override the app name filter from config.
    @Option(name: .long, help: "App name prefix used to filter crash reports (overrides config).")
    var app: String? = nil

    /// Override the crash output directory from config.
    @Option(name: .customLong("crash-output"), help: "Directory for extracted crash reports (overrides config).")
    var crashOutput: String? = nil

    // Logs overrides

    /// Override the OSLog subsystem from config.
    @Option(name: .long, help: "OSLog subsystem to filter on (overrides config).")
    var subsystem: String? = nil

    /// Override / append OSLog categories from config. Repeatable.
    @Option(name: .long, help: "OSLog category to include (repeatable; overrides config when any are given).")
    var category: [String] = []

    /// Override the process name filter from config.
    @Option(name: .long, help: "Process name filter (overrides config).")
    var process: String? = nil

    /// Override the minimum log level from config.
    @Option(name: .long, help: "Minimum log level: default, info, debug, error, fault (overrides config).")
    var level: String? = nil

    // MARK: - Run

    mutating func run() throws {
        // 1. Load config (nonisolated — pure file I/O)
        var cfg = Config.load(override: config)

        // 2. Merge CLI flags over config values

        // Git
        if repo != nil || tool != nil {
            cfg.git = GitConfig(
                repo: repo ?? cfg.git?.repo,
                tool: tool ?? cfg.git?.tool
            )
        }

        // Crashes
        if app != nil || crashOutput != nil {
            cfg.crashes = CrashesConfig(
                app: app ?? cfg.crashes?.app,
                output: crashOutput ?? cfg.crashes?.output
            )
        }

        // Logs
        let hasLogsOverrides = subsystem != nil || !category.isEmpty || process != nil || level != nil
        if hasLogsOverrides {
            cfg.logs = LogsConfig(
                subsystem: subsystem ?? cfg.logs?.subsystem,
                categories: category.isEmpty ? cfg.logs?.categories : category,
                process: process ?? cfg.logs?.process,
                level: level ?? cfg.logs?.level
            )
        }

        let gitConfig = cfg.git
        let crashesConfig = cfg.crashes
        let logsConfig = cfg.logs ?? LogsConfig()

        // Determine initial view: first view for which config values are present,
        // falling back to Git.
        let initialView: DashboardSource = {
            if cfg.git != nil { return .git }
            if cfg.crashes != nil { return .crashes }
            if cfg.logs != nil { return .logs }
            return .git
        }()

        // 3. Create state objects and coordinator on MainActor.
        //    ParsableCommand.run() is called on the main thread by ArgumentParser,
        //    so MainActor.assumeIsolated is safe here.
        let (gitState, crashesState, logsState, coordinator) = MainActor.assumeIsolated {
            let git = GitState(repoPath: gitConfig?.repo ?? ".")
            let crashes = CrashesState(appFilter: crashesConfig?.app)
            let logs = LogsState(config: logsConfig)
            let coord = AutoCoordinator()
            coord.activeView = initialView
            coord.homeView = initialView
            coord.start(gitState: git, crashesState: crashes, logsState: logs)
            // Attach the display sleep/wake monitor — suspends all three data
            // sources when the display sleeps and resumes them on wake.
            coord.attachSleepWakeMonitor()
            return (git, crashes, logs, coord)
        }

        // 4. Launch the TUI — Application.start() calls dispatchMain() and never returns.
        //    Construct the Application on MainActor since the View conformance is isolated.
        MainActor.assumeIsolated {
            Application(
                rootView: AutoDashboardView(
                    coordinator: coordinator,
                    gitState: gitState,
                    crashesState: crashesState,
                    logsState: logsState,
                    gitConfig: gitConfig,
                    crashesConfig: crashesConfig,
                    logsConfig: logsConfig
                )
            ).start()
        }
    }
}
