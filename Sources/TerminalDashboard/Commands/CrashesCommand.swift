import ArgumentParser
import SwiftTUI

struct CrashesCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "crashes",
        abstract: "Display the Crashes dashboard."
    )

    // MARK: - Options

    /// Path to a custom configuration file (mirrors the root --config flag).
    @Option(name: .long, help: "Path to a custom configuration file.")
    var config: String? = nil

    /// Override the app name filter from config.
    @Option(name: .long, help: "App name prefix used to filter crash reports (overrides config).")
    var app: String? = nil

    /// Override the crash output directory from config.
    @Option(name: .customLong("crash-output"), help: "Directory for extracted crash reports (overrides config).")
    var crashOutput: String? = nil

    // MARK: - Run

    mutating func run() throws {
        // 1. Load config (nonisolated — pure file I/O)
        var cfg = Config.load(override: config)

        // 2. Merge CLI flags over config values
        if app != nil || crashOutput != nil {
            cfg.crashes = CrashesConfig(
                app: app ?? cfg.crashes?.app,
                output: crashOutput ?? cfg.crashes?.output
            )
        }

        let crashesConfig = cfg.crashes
        let appFilter = crashesConfig?.app

        // 3. Create state and start on MainActor.
        //    ParsableCommand.run() is called on the main thread by ArgumentParser,
        //    so MainActor.assumeIsolated is safe here.
        let state = MainActor.assumeIsolated {
            let s = CrashesState(appFilter: appFilter)
            s.start()
            return s
        }

        // 4. Launch the TUI — Application.start() calls dispatchMain() and never returns.
        //    Construct the Application on MainActor since the View conformance is isolated.
        MainActor.assumeIsolated {
            Application(rootView: CrashesDashboardView(state: state, config: crashesConfig)).start()
        }
    }
}
