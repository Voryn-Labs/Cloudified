import SwiftUI

public struct CurrentTransferCard: View {
    public let transfer: CurrentTransferState?
    public let provider: String
    public let idleActivity: String

    public init(transfer: CurrentTransferState?, provider: String? = nil, idleActivity: String = "No file transfer") {
        self.transfer = transfer; self.provider = provider ?? transfer?.provider ?? "Destination"
        self.idleActivity = idleActivity
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(transfer?.filename ?? provider)
                        .font(.subheadline.weight(.medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .privacySensitive(transfer != nil)
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1, reservesSpace: true)
                }
                Spacer(minLength: 8)
                Text(transfer?.fractionCompleted == nil ? " " : (transfer?.percentageText ?? " "))
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .accessibilityHidden(transfer?.fractionCompleted == nil)
            }
            ZStack {
                Color.clear.frame(height: 4)
                BackupMeter(fraction: transfer?.fractionCompleted)
            }
            .accessibilityHidden(true)
            Text(transfer?.totalBytes == nil ? " " : (transfer?.byteProgressText ?? " "))
                .font(.caption2)
                .monospacedDigit()
                .foregroundStyle(.tertiary)
                .lineLimit(1, reservesSpace: true)
                .accessibilityHidden(transfer?.totalBytes == nil)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }

    private var detail: String {
        guard let transfer else { return idleActivity }
        var parts = [transfer.provider, transfer.activity]
        if let component = transfer.componentOrPart { parts.append(component) }
        if let attempt = transfer.attemptNumber {
            parts.append("Attempt \(attempt) of \(transfer.maxAttempts)")
        }
        return parts.joined(separator: " · ")
    }
}
