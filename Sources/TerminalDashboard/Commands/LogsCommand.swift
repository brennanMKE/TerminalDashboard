import ArgumentParser
import SwiftTUI

struct LogsCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "logs",
        abstract: "Display the Logs dashboard."
    )

    // MARK: - Options

    /// Path to a custom configuration file (mirrors the root --config flag).
    @Option(name: .long, help: "Path to a custom configuration file.")
    var config: String? = nil

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
        let hasOverrides = subsystem != nil || !category.isEmpty || process != nil || level != nil
        if hasOverrides {
            cfg.logs = LogsConfig(
                subsystem: subsystem ?? cfg.logs?.subsystem,
                categories: category.isEmpty ? cfg.logs?.categories : category,
                process: process ?? cfg.logs?.process,
                level: level ?? cfg.logs?.level
            )
        }

        let logsConfig = cfg.logs ?? LogsConfig()

        // 3. Create state and start on MainActor.
        //    ParsableCommand.run() is called on the main thread by ArgumentParser,
        //    so MainActor.assumeIsolated is safe here.
        let state = MainActor.assumeIsolated {
            let s = LogsState(config: logsConfig)
            s.start()
            return s
        }

        // 4. Launch the TUI — Application.start() calls dispatchMain() and never returns.
        //    Construct the Application on MainActor since the View conformance is isolated.
        MainActor.assumeIsolated {
            Application(rootView: LogsDashboardView(state: state, config: logsConfig)).start()
        }
    }
}
