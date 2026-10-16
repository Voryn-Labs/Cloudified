import SwiftUI

public struct MediaSectionCard: View {
    public let state: MediaSectionState
    public init(state: MediaSectionState) { self.state = state }

    public var body: some View {
        NavigationLink {
            details
        } label: {
            HStack(spacing: 12) {
                SymbolTile(systemName: state.title == "Videos" ? "video.fill" : "photo.fill")
                VStack(alignment: .leading, spacing: 2) {
                    Text(state.title)
                        .font(.body.weight(.medium))
                    Text(state.title == "Videos" ? "Original videos" : "Original photos")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .lineLimit(2)
                }
                Spacer(minLength: 8)
                Text(state.totalCount.map { $0.formatted() } ?? "—")
                    .font(.body)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 2)
        }
    }

    private var details: some View {
        List {
            if let total = state.totalCount {
                Section {
                    LabeledContent("In library", value: total.formatted())
                        .monospacedDigit()
                }
            }
            Section("Google Photos") {
                stat("Saved", state.googleSaved)
                stat("Remaining", state.googleRemaining)
                if let failed = state.googleFailed, failed > 0 {
                    stat("Failed", Optional(failed), color: .red)
                }
            }
            Section("Telegram") {
                stat("Saved", state.telegramSaved)
                stat("Remaining", state.telegramRemaining)
                if let failed = state.telegramFailed, failed > 0 {
                    stat("Failed", Optional(failed), color: .red)
                }
            }
            if let operation = state.activeOperation {
                Section("In progress") {
                    Text(operation)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    if let bytes = state.byteProgress {
                        Text(bytes)
                            .font(.caption)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
            }
            Section {
                Text(state.subtitle)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .cloudifiedList().navigationTitle(state.title)
        .navigationBarTitleDisplayMode(.inline)
    }

    private func stat(_ label: String, _ value: Int?, color: Color = .primary) -> some View {
        LabeledContent(label, value: value.map { $0.formatted() } ?? "—")
            .monospacedDigit()
            .foregroundStyle(color)
    }
}
