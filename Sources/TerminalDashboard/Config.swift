import Foundation

// MARK: - Config structs

/// Git dashboard configuration.
struct GitConfig: Equatable {
    /// Path to the repository. Defaults to `"."` when not set.
    var repo: String?
    /// Shell command template for launching the external Git tool.
    /// Use `{dir}` as a placeholder for the repository path.
    var tool: String?
}

/// Crashes dashboard configuration.
struct CrashesConfig: Equatable {
    /// App name used to filter crash reports. Required for the dashboard to function.
    var app: String?
    /// Directory where crash reports are stored.
    var output: String?
}

/// Logs dashboard configuration.
struct LogsConfig: Equatable {
    /// OSLog subsystem to filter on. Required for the dashboard to function.
    var subsystem: String?
    /// OSLog categories to include. Empty array means all categories.
    var categories: [String]?
    /// Process name filter. Empty string means all processes.
    var process: String?
    /// Minimum log level to show (`"default"`, `"info"`, `"debug"`, `"error"`, `"fault"`).
    var level: String?
}

/// Top-level configuration loaded from a `.tuidash.toml` file.
///
/// Precedence (highest to lowest):
/// 1. Explicit override path passed to `Config.load(override:)`.
/// 2. `.tuidash.toml` in the current working directory.
/// 3. `~/.config/tuidash/config.toml` (global fallback).
///
/// Fields are `nil` when absent from every config source. Callers decide
/// how to handle missing required values — the parser never crashes on them.
struct Config: Equatable {
    var git: GitConfig?
    var crashes: CrashesConfig?
    var logs: LogsConfig?

    // MARK: - Loading

    /// Loads configuration by applying the precedence rules.
    ///
    /// - Parameter override: An explicit path supplied by the caller (e.g. from a CLI flag).
    ///   When non-nil this file is the *only* source consulted; the two default locations
    ///   are skipped.
    /// - Returns: A `Config` value. Returns an empty `Config()` when no file is found or
    ///   all files are unreadable, so callers always receive a valid struct.
    nonisolated static func load(override overridePath: String? = nil) -> Config {
        if let overridePath {
            return (try? parse(contentsOf: overridePath)) ?? Config()
        }

        let candidates: [String] = [
            ".tuidash.toml",
            (FileManager.default.homeDirectoryForCurrentUser.path as NSString)
                .appendingPathComponent(".config/tuidash/config.toml"),
        ]

        for path in candidates {
            if let config = try? parse(contentsOf: path) {
                return config
            }
        }
        return Config()
    }

    // MARK: - Parsing

    /// Parses the TOML file at `path` and returns a `Config`.
    ///
    /// Throws only when the file cannot be read (e.g. missing or permissions error).
    /// Unknown keys and malformed value lines are silently skipped so the parser is
    /// forward-compatible with future schema additions.
    nonisolated static func parse(contentsOf path: String) throws -> Config {
        let contents = try String(contentsOfFile: path, encoding: .utf8)
        return parse(toml: contents)
    }

    /// Parses a TOML string and returns a `Config`.
    ///
    /// This is a minimal parser that understands only the known `.tuidash.toml` schema.
    /// It is intentionally **not** a general-purpose TOML parser.
    ///
    /// Supported syntax:
    /// - Section headers: `[section]`
    /// - String values: `key = "value"`
    /// - String arrays: `key = ["a", "b"]`
    /// - Inline comments (`# …`) are stripped.
    /// - Leading/trailing whitespace on each line is ignored.
    nonisolated static func parse(toml: String) -> Config {
        var gitFields: [String: TOMLValue] = [:]
        var crashesFields: [String: TOMLValue] = [:]
        var logsFields: [String: TOMLValue] = [:]

        var currentSection: String? = nil

        for rawLine in toml.components(separatedBy: .newlines) {
            let line = stripComment(rawLine).trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }

            // Section header
            if line.hasPrefix("[") && line.hasSuffix("]") {
                currentSection = String(line.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
                continue
            }

            // Key = value
            guard let eqRange = line.range(of: "=") else { continue }
            let key = line[line.startIndex..<eqRange.lowerBound]
                .trimmingCharacters(in: .whitespaces)
            let rawValue = line[eqRange.upperBound...]
                .trimmingCharacters(in: .whitespaces)

            guard let value = parseTOMLValue(rawValue) else { continue }

            switch currentSection {
            case "git":     gitFields[key] = value
            case "crashes": crashesFields[key] = value
            case "logs":    logsFields[key] = value
            default:        break
            }
        }

        let git: GitConfig? = gitFields.isEmpty ? nil : GitConfig(
            repo: gitFields["repo"]?.string,
            tool: gitFields["tool"]?.string
        )

        let crashes: CrashesConfig? = crashesFields.isEmpty ? nil : CrashesConfig(
            app: crashesFields["app"]?.string,
            output: crashesFields["output"]?.string
        )

        let logs: LogsConfig? = logsFields.isEmpty ? nil : LogsConfig(
            subsystem: logsFields["subsystem"]?.string,
            categories: logsFields["categories"]?.array,
            process: logsFields["process"]?.string,
            level: logsFields["level"]?.string
        )

        return Config(git: git, crashes: crashes, logs: logs)
    }

    // MARK: - Private helpers

    /// Strips a trailing inline comment (`# …`) from a raw line.
    ///
    /// A `#` inside a quoted string is **not** treated as a comment.
    private nonisolated static func stripComment(_ line: String) -> String {
        var inString = false
        var escaped = false
        for (offset, char) in line.enumerated() {
            if escaped {
                escaped = false
                continue
            }
            if char == "\\" && inString {
                escaped = true
                continue
            }
            if char == "\"" {
                inString.toggle()
                continue
            }
            if char == "#" && !inString {
                return String(line.prefix(offset))
            }
        }
        return line
    }

    /// Parses a single TOML value token (the right-hand side of an assignment).
    ///
    /// Returns `nil` when the token is not a recognised string or string-array literal.
    private nonisolated static func parseTOMLValue(_ raw: String) -> TOMLValue? {
        let s = raw.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("[") {
            return .array(parseStringArray(s))
        }
        if let str = parseQuotedString(s) {
            return .string(str)
        }
        return nil
    }

    /// Parses a TOML inline array of quoted strings: `["a", "b", "c"]`.
    ///
    /// Non-string elements and malformed entries are silently skipped.
    private nonisolated static func parseStringArray(_ raw: String) -> [String] {
        // Strip outer brackets
        var inner = raw.trimmingCharacters(in: .whitespaces)
        guard inner.hasPrefix("[") && inner.hasSuffix("]") else { return [] }
        inner = String(inner.dropFirst().dropLast())

        // Split naively on commas and parse each element as a quoted string
        return inner
            .components(separatedBy: ",")
            .compactMap { parseQuotedString($0.trimmingCharacters(in: .whitespaces)) }
    }

    /// Extracts the content of a double-quoted TOML string literal.
    ///
    /// Returns `nil` when `raw` is not wrapped in `"…"`.
    private nonisolated static func parseQuotedString(_ raw: String) -> String? {
        let s = raw.trimmingCharacters(in: .whitespaces)
        guard s.hasPrefix("\"") && s.hasSuffix("\"") && s.count >= 2 else { return nil }
        var result = String(s.dropFirst().dropLast())
        // Handle basic TOML escape sequences
        result = result
            .replacingOccurrences(of: "\\n", with: "\n")
            .replacingOccurrences(of: "\\t", with: "\t")
            .replacingOccurrences(of: "\\\\", with: "\\")
            .replacingOccurrences(of: "\\\"", with: "\"")
        return result
    }
}

// MARK: - Internal value type

/// An intermediate representation of a parsed TOML value used only during parsing.
private enum TOMLValue {
    case string(String)
    case array([String])

    nonisolated var string: String? {
        if case .string(let s) = self { return s }
        return nil
    }

    nonisolated var array: [String]? {
        if case .array(let a) = self { return a }
        return nil
    }
}
