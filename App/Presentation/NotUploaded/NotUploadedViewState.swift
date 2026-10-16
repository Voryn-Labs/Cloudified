import Foundation
import CloudifiedCore

public enum DestinationFilter: String, CaseIterable, Identifiable, Sendable {
    case all = "All"
    case google = "Google Photos"
    case telegram = "Telegram"

    public var id: String { rawValue }
}

public enum MediaTypeFilter: String, CaseIterable, Identifiable, Sendable {
    case all = "All"
    case photos = "Photos"
    case videos = "Videos"

    public var id: String { rawValue }
}

public enum FailureStatusFilter: String, CaseIterable, Identifiable, Sendable {
    case failed = "Failed"
    case waiting = "Waiting"
    case pending = "Pending retry"
    case all = "All"

    public var id: String { rawValue }
}

public struct NotUploadedItem: Identifiable, Equatable, Sendable {
    public let id: String
    public let destinationID: UUID
    public let sourceAsset: AssetIdentity?
    public let canRetry: Bool
    public let needsRecovery: Bool
    public let jobID: UUID?
    public let localIdentifier: String
    public let filename: String
    public let captureDate: Date?
    public let mediaType: String
    public let durationSeconds: TimeInterval?
    public let provider: String
    public let status: String
    public let attemptCount: Int?
    public let maxAttempts: Int
    public let stage: String
    public let errorCategory: String
    public let technicalCode: String?
    public let plainLanguageReason: String
    public let suggestedRemedy: String?
    public let confirmedComponents: [String]
    public let missingObligations: [String]
    public let nextRetryDate: Date?

    public init(
        id: String,
        destinationID: UUID,
        sourceAsset: AssetIdentity? = nil,
        canRetry: Bool = false,
        needsRecovery: Bool = false,
        jobID: UUID? = nil,
        localIdentifier: String = "",
        filename: String,
        captureDate: Date?,
        mediaType: String,
        durationSeconds: TimeInterval? = nil,
        provider: String,
        status: String = "Failed",
        attemptCount: Int? = nil,
        maxAttempts: Int = 3,
        stage: String = "Transfer",
        errorCategory: String = "Network error",
        technicalCode: String? = nil,
        plainLanguageReason: String,
        suggestedRemedy: String? = nil,
        confirmedComponents: [String] = [],
        missingObligations: [String] = [],
        nextRetryDate: Date? = nil
    ) {
        self.destinationID = destinationID; self.sourceAsset = sourceAsset
        self.canRetry = canRetry; self.needsRecovery = needsRecovery
        self.id = id
        self.jobID = jobID
        self.localIdentifier = localIdentifier
        self.filename = filename
        self.captureDate = captureDate
        self.mediaType = mediaType
        self.durationSeconds = durationSeconds
        self.provider = provider
        self.status = status
        self.attemptCount = attemptCount
        self.maxAttempts = maxAttempts
        self.stage = stage
        self.errorCategory = errorCategory
        self.technicalCode = technicalCode
        self.plainLanguageReason = plainLanguageReason
        self.suggestedRemedy = suggestedRemedy
        self.confirmedComponents = confirmedComponents
        self.missingObligations = missingObligations
        self.nextRetryDate = nextRetryDate
    }

    public var attemptText: String {
        return attemptCount.map { "\($0)/\(maxAttempts)" } ?? "Not started"
    }

    public var statusTitle: String {
        if needsRecovery { return "Verify upload" }
        if status.localizedCaseInsensitiveContains("fail") { return "Failed" }
        if status.localizedCaseInsensitiveContains("pend") { return "Retry scheduled" }
        return "Waiting"
    }

    public var identificationText: String {
        var fields = [filename, "\(provider) · \(mediaType)"]
        if let captureDate { fields.append("Captured: \(captureDate.formatted(date: .abbreviated, time: .shortened))") }
        fields.append("Status: \(statusTitle)")
        fields.append(plainLanguageReason)
        if let technicalCode { fields.append("Technical code: \(technicalCode)") }
        return fields.joined(separator: "\n")
    }
}

public struct NotUploadedViewState: Equatable, Sendable {
    public var destinationFilter: DestinationFilter
    public var mediaTypeFilter: MediaTypeFilter
    public var statusFilter: FailureStatusFilter
    public var hasLoaded = false
    public var isLoading = false
    public var hasOlder = false
    public var hasNewer = false
    public var pageError: String?
    public var items: [NotUploadedItem]

    public init(
        destinationFilter: DestinationFilter = .all,
        mediaTypeFilter: MediaTypeFilter = .all,
        statusFilter: FailureStatusFilter = .all,
        items: [NotUploadedItem] = []
    ) {
        self.destinationFilter = destinationFilter
        self.mediaTypeFilter = mediaTypeFilter
        self.statusFilter = statusFilter
        self.items = items
    }

    public var filteredItems: [NotUploadedItem] {
        return items.filter { item in
            switch destinationFilter {
            case .all:
                break
            case .google:
                guard item.provider.localizedCaseInsensitiveContains("Google") else { return false }
            case .telegram:
                guard item.provider.localizedCaseInsensitiveContains("Telegram") else { return false }
            }

            switch mediaTypeFilter {
            case .all:
                break
            case .photos:
                guard item.mediaType.localizedCaseInsensitiveContains("Photo") else { return false }
            case .videos:
                guard item.mediaType.localizedCaseInsensitiveContains("Video") else { return false }
            }

            switch statusFilter {
            case .all:
                break
            case .failed:
                guard item.status.localizedCaseInsensitiveContains("Fail") else { return false }
            case .waiting:
                guard item.status.localizedCaseInsensitiveContains("Wait") else { return false }
            case .pending:
                guard item.status.localizedCaseInsensitiveContains("Pend") else { return false }
            }

            return true
        }
    }
}
