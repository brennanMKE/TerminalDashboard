import ArgumentParser

struct AutoCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "auto",
        abstract: "Automatically surface the most relevant dashboard view based on event severity."
    )

    mutating func run() throws {
        print("auto: not yet implemented")
    }
}
