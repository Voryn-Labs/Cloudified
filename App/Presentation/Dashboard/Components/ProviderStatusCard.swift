import SwiftUI

public struct ProviderStatusCard: View {
    public let state: ProviderCardState
    public let transfer: CurrentTransferState?
    public let onSettingsTapped: () -> Void

    public init(state: ProviderCardState, transfer: CurrentTransferState? = nil, onSettingsTapped: @escaping () -> Void = {}) {
        self.state = state; self.transfer = transfer; self.onSettingsTapped = onSettingsTapped
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            NavigationLink { details } label: {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 10) {
                        SymbolTile(systemName: symbol, pulse: state.savedCount ?? 0)
                        Text(state.name).font(.headline).foregroundStyle(.primary).lineLimit(1).layoutPriority(1)
                        Spacer(minLength: 4)
                        StatusPill(title: status, symbol: statusSymbol, color: statusColor)
                    }
                    HStack(alignment: .firstTextBaseline) {
                        Text(state.savedCount.map { $0.formatted() } ?? "—").font(.title2.weight(.semibold)).foregroundStyle(.primary)
                        Text(state.totalCount.map { "of \($0.formatted()) saved" } ?? "Not scanned")
                            .font(.caption).foregroundStyle(.secondary)
                        Spacer(minLength: 0)
                    }.monospacedDigit()
                    BackupMeter(fraction: fraction)
                    Text(footer).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                        .lineLimit(2, reservesSpace: true).frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.vertical, 8)
            }
            .accessibilityHint("Opens current upload, remaining counts, issues and account settings")
            accountNotice
        }
    }
    @ViewBuilder private var accountNotice: some View {
        if let attention = state.attention, let message = state.attentionMessage {
            VStack(alignment: .leading, spacing: 8) {
                Label(attention.title, systemImage: attention == .rateLimit ? "clock.badge.exclamationmark" : "exclamationmark.circle")
                    .font(.subheadline.weight(.semibold)).foregroundStyle(.orange)
                Text(message).font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if attention == .storage {
                    if state.name == "Google Photos" { Link("Manage storage", destination: URL(string: "https://one.google.com/storage")!) }
                    else { Button("Review account settings", action: onSettingsTapped).buttonStyle(.bordered) }
                } else if let title = attention.actionTitle {
                    Button(title, action: onSettingsTapped).buttonStyle(.bordered)
                }
            }
            .padding(.bottom, 8)
        }
    }

    private var symbol: String { state.name == "Telegram" ? "paperplane.fill" : "photo.stack.fill" }
    private var fraction: Double? {
        guard let saved = state.savedCount, let total = state.totalCount, total > 0 else { return nil }
        return Double(saved) / Double(total)
    }
    private var status: String {
        if !state.isConnected { return "Connect" }
        if !state.isEnabled { return "Off" }
        if let attention = state.attention { return attention == .rateLimit ? "Limited" : "Action needed" }
        if let transfer { return transfer.fractionCompleted == nil ? "Working" : (transfer.fractionCompleted == 1 ? "Verifying" : "Uploading") }
        if (state.failedCount ?? 0) > 0 { return "Issues" }
        if state.remainingCount == 0 { return "Saved" }
        if (state.waitingCount ?? 0) > 0 { return "Waiting" }
        return "Ready"
    }
    private var statusSymbol: String {
        if !state.isConnected { return "link" }
        if state.attention != nil || (state.failedCount ?? 0) > 0 { return "exclamationmark.circle" }
        if transfer != nil { return "arrow.up" }
        if state.isEnabled && state.remainingCount == 0 { return "checkmark" }
        return state.isEnabled ? "clock" : "pause"
    }
    private var statusColor: Color {
        if state.attention != nil || (state.failedCount ?? 0) > 0 || (state.waitingCount ?? 0) > 0 && transfer == nil { return .orange }
        return state.isEnabled && state.isConnected ? .accentColor : .secondary
    }
    private var footer: String {
        guard state.isConnected else { return "Link an account to back up originals" }
        guard state.isEnabled else { return "Backup is switched off for this destination" }
        let remaining = state.remainingCount.map { "\($0.formatted()) remaining" } ?? "Counts available after scanning"
        if let transfer { return "\(remaining) · \(transfer.totalBytes == nil ? transfer.activity : transfer.byteProgressText)" }
        if let waiting = state.waitingCount, waiting > 0 { return "\(remaining) · \(waiting.formatted()) waiting for verification or retry" }
        return remaining
    }
    private var details: some View {
        List {
            Section {
                FlowIntro(systemName: symbol, title: state.name, message: state.connectionDescription).privacySensitive()
                CurrentTransferCard(transfer: transfer, provider: state.name, idleActivity: state.currentActivity)
            }
            if state.attention != nil { Section { accountNotice } }
            Section("Backup progress") {
                stat("Saved", state.savedCount)
                stat("Remaining", state.remainingCount)
                stat("Waiting", state.waitingCount)
                stat("Failed", state.failedCount)
                if let date = state.lastConfirmedDate { LabeledContent("Last saved", value: date.formatted(date: .abbreviated, time: .shortened)).font(.subheadline) }
            }
            if state.name == "Telegram", (state.protectedUnresolvedCount ?? 0) > 0 {
                Section("Awaiting verification") {
                    IssueBlock(message: "\(state.protectedUnresolvedCount ?? 0) older sends have no verified result. They are not counted as saved. Their originals stay protected while other eligible files continue.")
                    Text("Open Activity → Issues to identify each file and check its upload. Verification can remain unresolved; it is not safe to resend just because a timer elapsed.")
                        .font(.footnote).foregroundStyle(.secondary)
                    LabeledContent("Protected upload slots", value: state.retainedTransferCount.map { "\($0) of 8" } ?? "Unavailable")
                }
            }
            Section {
                Button(action: onSettingsTapped) { Label(state.isConnected ? "Account settings" : "Connect account", systemImage: "person.crop.circle") }
                if state.attention == .storage && state.name == "Google Photos" { Link("Manage Google storage", destination: URL(string: "https://one.google.com/storage")!) }
            }
        }
        .cloudifiedList().navigationTitle(state.name).navigationBarTitleDisplayMode(.inline)
    }
    private func stat(_ title: String, _ count: Int?) -> some View {
        LabeledContent(title, value: count.map { $0.formatted() } ?? "—").monospacedDigit()
    }
}
