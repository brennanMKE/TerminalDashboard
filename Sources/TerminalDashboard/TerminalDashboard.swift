import ArgumentParser

@main
struct TerminalDashboard: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "tuidash",
        abstract: "A collection of live terminal dashboards for Git, Crashes, and Logs.",
        subcommands: [
            AutoCommand.self,
            GitCommand.self,
            CrashesCommand.self,
            LogsCommand.self,
            ConfigCommand.self,
        ],
        defaultSubcommand: AutoCommand.self
    )

    @Option(name: .long, help: "Path to a custom configuration file.")
    var config: String?
}
