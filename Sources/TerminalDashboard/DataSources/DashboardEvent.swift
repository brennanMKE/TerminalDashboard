import Foundation

enum Severity: Comparable, Sendable {
    case info
    case warning
    case error
    case critical
}

enum DashboardSource: Sendable {
    case git
    case crashes
    case logs
}

struct DashboardEvent: Sendable {
    let source: DashboardSource
    let severity: Severity
    let message: String
    let timestamp: Date
}
