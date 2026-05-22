import ArgumentParser

struct ConfigCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "config",
        abstract: "Show or edit the tuidash configuration."
    )

    mutating func run() throws {
        print("config: not yet implemented")
    }
}
