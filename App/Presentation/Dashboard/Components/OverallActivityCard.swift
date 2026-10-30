import SwiftUI

public struct OverallActivityCard: View {
    public let title: String
    public let total: Int?
    public let saved: Int?
    public let canPause: Bool
    public let canResume: Bool
    public let canStart: Bool
    public var transitionLabel: String? = nil
    public let onBackUp: () -> Void
    public let onPause: () -> Void
    public let onResume: () -> Void

    public var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 16) {
                ProgressOrbit(fraction: fraction, symbol: canPause ? "arrow.up" : (canResume ? "pause.fill" : "cloud"))
                    .frame(width: 56, height: 56)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.title3.weight(.semibold))
                    Text(summary).font(.subheadline).foregroundStyle(.secondary).monospacedDigit()
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Button(action: action) {
                HStack(spacing: 8) {
                    if transitionLabel != nil { ProgressView().controlSize(.small) }
                    Label(transitionLabel ?? (canPause ? "Pause backup" : (canResume ? "Resume backup" : "Back up now")),
                        systemImage: canPause ? "pause.fill" : "arrow.up")
                }
                .font(.subheadline.weight(.semibold)).frame(maxWidth: .infinity, minHeight: 36)
            }
            .buttonStyle(.borderedProminent).buttonBorderShape(.roundedRectangle(radius: 12))
            .disabled(!(canPause || canResume || canStart))
        }
        .padding(.vertical, 10)
    }

    private var fraction: Double? {
        guard let saved, let total, total > 0 else { return nil }
        return Double(saved) / Double(total)
    }
    private var summary: String {
        if let saved, let total { return "\(saved.formatted()) of \(total.formatted()) destination saves" }
        if let total { return "\(total.formatted()) photos and videos" }
        return "Backup counts unavailable"
    }
    private func action() {
        if canPause { onPause() } else if canResume { onResume() } else { onBackUp() }
    }
}
