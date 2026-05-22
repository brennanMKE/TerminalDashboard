import ArgumentParser
import Foundation

struct ConfigCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "config",
        abstract: "Interactive wizard to create or edit .tuidash.toml in the working directory."
    )

    mutating func run() throws {
        let configPath = ".tuidash.toml"
        let fileManager = FileManager.default

        // Check if config already exists
        if fileManager.fileExists(atPath: configPath) {
            print(".tuidash.toml already exists.")
            print("Overwrite? [y/N]: ", terminator: "")
            let answer = readLine() ?? ""
            guard answer.lowercased() == "y" || answer.lowercased() == "yes" else {
                print("Aborted. No changes made.")
                return
            }
        }

        print("")
        print("tuidash config wizard — press Enter to keep the default shown in [brackets].")
        print("")

        // MARK: git section
        print("[git]")
        let gitRepo = prompt("Git repo path", default: ".")
        let gitTool = prompt("Git tool command", default: "gitup {dir} -t")

        // MARK: crashes section
        print("")
        print("[crashes]")
        let crashesApp = prompt("Crashes app name prefix", default: "MyApp")
        let crashesOutput = prompt("Crashes output directory", default: "./crashes")

        // MARK: logs section
        print("")
        print("[logs]")
        let logsSubsystem = prompt("Logs subsystem", default: "com.example.MyApp")
        let logsCategoriesRaw = prompt("Logs categories (comma-separated, empty = all)", default: "")
        let logsProcess = prompt("Logs process name (empty = all)", default: "")
        let logsLevel = prompt("Logs minimum level", default: "info")

        // Parse categories
        let categoriesArray: [String]
        if logsCategoriesRaw.trimmingCharacters(in: .whitespaces).isEmpty {
            categoriesArray = []
        } else {
            categoriesArray = logsCategoriesRaw
                .components(separatedBy: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
        }

        // Build TOML content
        let categoriesFormatted: String
        if categoriesArray.isEmpty {
            categoriesFormatted = "[]"
        } else {
            let quoted = categoriesArray.map { "\"\($0)\"" }.joined(separator: ", ")
            categoriesFormatted = "[\(quoted)]"
        }

        let toml = """
        # .tuidash.toml — project-level configuration

        [git]
        repo = "\(gitRepo)"                          # path relative to config file location
        tool = "\(gitTool)"             # optional; {dir} is replaced with the repo path at runtime

        [crashes]
        app = "\(crashesApp)"                       # crash log filename prefix filter
        output = "\(crashesOutput)"                # extraction destination

        [logs]
        subsystem = "\(logsSubsystem)"
        categories = \(categoriesFormatted) # optional; empty = all categories
        process = "\(logsProcess)"                        # optional process name filter
        level = "\(logsLevel)"                      # minimum log level
        """

        do {
            try toml.write(toFile: configPath, atomically: true, encoding: .utf8)
            print("")
            print("Written: \(configPath)")
        } catch {
            print("Error writing \(configPath): \(error.localizedDescription)")
            throw ExitCode.failure
        }
    }

    // MARK: - Helpers

    /// Prompts the user with a label and a default value shown in brackets.
    /// Returns the user's input, or the default when the user presses Enter with no input.
    private func prompt(_ label: String, default defaultValue: String) -> String {
        if defaultValue.isEmpty {
            print("\(label) []: ", terminator: "")
        } else {
            print("\(label) [\(defaultValue)]: ", terminator: "")
        }
        let input = readLine() ?? ""
        return input.isEmpty ? defaultValue : input
    }
}
