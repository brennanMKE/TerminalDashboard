import ArgumentParser

struct CrashesCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "crashes",
        abstract: "Display the Crashes dashboard."
    )

    mutating func run() throws {
        print("crashes: not yet implemented")
    }
}
