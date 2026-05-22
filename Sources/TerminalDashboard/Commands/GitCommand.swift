import ArgumentParser

struct GitCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "git",
        abstract: "Display the Git status dashboard."
    )

    mutating func run() throws {
        print("git: not yet implemented")
    }
}
