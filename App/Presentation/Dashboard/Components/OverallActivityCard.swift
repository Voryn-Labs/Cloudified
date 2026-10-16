import SwiftUI

public struct OverallActivityCard: View {
    public let title: String
    public let libraryTotal: Int?
    public let savedToBoth: Int?
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
        guard let savedToBoth, let libraryTotal, libraryTotal > 0 else { return nil }
        return Double(savedToBoth) / Double(libraryTotal)
    }
    private var summary: String {
        if let savedToBoth, let libraryTotal { return "\(savedToBoth.formatted()) of \(libraryTotal.formatted()) saved to both" }
        if let libraryTotal { return "\(libraryTotal.formatted()) photos and videos" }
        return "Connect a destination to get started"
    }
    private func action() {
        if canPause { onPause() } else if canResume { onResume() } else { onBackUp() }
    }
}
