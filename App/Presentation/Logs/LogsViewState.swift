import Foundation

/// Origin filter for diagnostics logs.
public enum LogOriginFilter: String, CaseIterable, Identifiable, Sendable {
    case all = "All"
    case google = "Google Photos"
    case telegram = "Telegram"
    case system = "System"

    public var id: String { rawValue }
}

/// Severity filter for diagnostics logs.
public enum LogSeverityFilter: String, CaseIterable, Identifiable, Sendable {
    case all = "All"
    case info = "Info"
    case warning = "Warning"
    case error = "Error"

    public var id: String { rawValue }
}

/// Structured diagnostic log entry.
public struct DiagnosticLogEntry: Identifiable, Equatable, Sendable {
    public let id: String
    public let timestamp: Date
    public let origin: String
    public let severity: String
    public let stage: String
    public let attemptNumber: Int?
    public let message: String
    public let safeErrorCode: String?

    public init(
        id: String = UUID().uuidString,
        timestamp: Date = Date(),
        origin: String,
        severity: String = "info",
        stage: String,
        attemptNumber: Int? = nil,
        message: String,
        safeErrorCode: String? = nil
    ) {
        self.id = id
        self.timestamp = timestamp
        self.origin = origin
        self.severity = severity
        self.stage = stage
        self.attemptNumber = attemptNumber
        self.message = message
        self.safeErrorCode = safeErrorCode
    }
}

/// State representation for the Logs screen.
public struct LogRunChoice: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let title: String
}

public struct LogsViewState: Equatable, Sendable {
    public var originFilter: LogOriginFilter
    public var severityFilter: LogSeverityFilter
    public var runs: [LogRunChoice] = []
    public var selectedRunID: UUID?
    public var hasOlderRuns = false
    public var hasLoaded = false
    public var isLoading = false
    public var hasOlder = false
    public var hasNewer = false
    public var prunedEventCount: Int64 = 0
    public var pageError: String?
    public var fallbackEntries: [DiagnosticLogEntry] = []
    public var entries: [DiagnosticLogEntry]

    public init(
        originFilter: LogOriginFilter = .all,
        severityFilter: LogSeverityFilter = .all,
        entries: [DiagnosticLogEntry] = []
    ) {
        self.originFilter = originFilter
        self.severityFilter = severityFilter
        self.entries = entries
    }

    public var filteredEntries: [DiagnosticLogEntry] {
        return entries.filter { entry in
            switch originFilter {
            case .all:
                break
            case .google:
                guard entry.origin.localizedCaseInsensitiveContains("Google") else { return false }
            case .telegram:
                guard entry.origin.localizedCaseInsensitiveContains("Telegram") else { return false }
            case .system:
                guard entry.origin.localizedCaseInsensitiveContains("System") || entry.origin.localizedCaseInsensitiveContains("Source") else { return false }
            }

            switch severityFilter {
            case .all:
                break
            case .info:
                guard entry.severity.localizedCaseInsensitiveCompare("info") == .orderedSame else { return false }
            case .warning:
                guard entry.severity.localizedCaseInsensitiveCompare("warning") == .orderedSame else { return false }
            case .error:
                guard entry.severity.localizedCaseInsensitiveCompare("error") == .orderedSame else { return false }
            }

            return true
        }
    }
}
