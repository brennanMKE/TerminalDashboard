import ArgumentParser

struct LogsCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "logs",
        abstract: "Display the Logs dashboard."
    )

    mutating func run() throws {
        print("logs: not yet implemented")
    }
}
