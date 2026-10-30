import SwiftUI
import UIKit

enum AwakeStyle: String, CaseIterable, Identifiable {
    case dim = "Dim", comfortable = "Comfortable"
    var id: String { rawValue }
}

struct KeepAwakeView: View {
    @ObservedObject private var presentation: ScreenStateStore<DashboardViewState>
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.colorSchemeContrast) private var contrast
    @AppStorage("CloudifiedAwakeStyle") private var style = AwakeStyle.dim
    @State private var battery = BatteryReading.current
    @State private var previousBatteryMonitoring = false
    @State private var previousIdleTimer = false

    init(environment: AppEnvironment) { presentation = environment.dashboardPresentation }
    private var state: DashboardViewState { presentation.value }
    private var lowBattery: Bool { battery.unplugged && battery.level >= 0 && battery.level < 0.2 }
    private var keepsAwake: Bool { state.keepAwakeAllowed && !lowBattery && scenePhase == .active }
    private var bright: Bool { style == .comfortable || contrast == .increased }
    private var ink: Color { bright ? Color(red: 0.58, green: 0.89, blue: 0.79) : Color(red: 0.44, green: 0.70, blue: 0.62) }
    private var secondary: Color { .white.opacity(bright ? 0.76 : 0.60) }
    private var totals: (saved: Int, total: Int)? {
        let enabled = [state.googleStatus, state.telegramStatus].filter { $0.isEnabled && $0.isConnected }
        guard !enabled.isEmpty, enabled.allSatisfy({ $0.savedCount != nil && $0.totalCount != nil }) else { return nil }
        return (enabled.compactMap(\.savedCount).reduce(0, +), enabled.compactMap(\.totalCount).reduce(0, +))
    }
    private var fraction: Double? {
        guard let totals, totals.total > 0 else { return nil }
        return min(1, max(0, Double(totals.saved) / Double(totals.total)))
    }
    var body: some View {
        NavigationStack {
            GeometryReader { geometry in
                ScrollView {
                    VStack(spacing: 32) {
                        Spacer(minLength: 8)
                        VStack(spacing: 16) {
                            ZStack {
                                Circle().stroke(.white.opacity(0.12), lineWidth: 4)
                                Circle().trim(from: 0, to: fraction ?? 0)
                                    .stroke(ink, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                                    .rotationEffect(.degrees(-90))
                                Text(fraction.map { "\(Int(($0 * 100).rounded()))%" } ?? "—")
                                    .font(.system(.largeTitle, design: .rounded, weight: .medium))
                                    .monospacedDigit().foregroundStyle(ink)
                            }
                            .frame(width: 148, height: 148)
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel("Destination progress")
                            .accessibilityValue(fraction.map { "\(Int(($0 * 100).rounded())) percent" } ?? "Unavailable")
                            Text(state.summaryTitle).font(.headline).foregroundStyle(.white.opacity(bright ? 0.94 : 0.80))
                                .multilineTextAlignment(.center).frame(minHeight: 44)
                            Text(totals.map { "\($0.saved.formatted()) / \($0.total.formatted()) destination saves" } ?? "Waiting for backup counts")
                                .font(.caption).monospacedDigit().foregroundStyle(secondary)
                                .multilineTextAlignment(.center)
                        }
                        VStack(spacing: 24) {
                            provider(state.googleStatus)
                            provider(state.telegramStatus)
                        }
                        Spacer(minLength: 8)
                        VStack(spacing: 12) {
                            Label(lockMessage, systemImage: keepsAwake ? "display" : "lock")
                                .font(.caption).foregroundStyle(secondary).multilineTextAlignment(.center)
                            if battery.level >= 0 {
                                Label("\(Int((battery.level * 100).rounded()))%\(battery.unplugged ? "" : " · Charging")",
                                      systemImage: battery.unplugged ? "battery.50" : "battery.100.bolt")
                                    .font(.caption).monospacedDigit().foregroundStyle(secondary)
                            }
                        }
                    }
                    .frame(maxWidth: 360).frame(minHeight: max(0, geometry.size.height - 48))
                    .padding(.horizontal, 24).padding(.vertical, 24).frame(maxWidth: .infinity)
                }
            }
            .background(Color.black.ignoresSafeArea())
            .navigationTitle("Cloudified").navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Color.black, for: .navigationBar).toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark").frame(width: 44, height: 44).contentShape(Rectangle())
                    }.foregroundStyle(secondary).accessibilityLabel("Return to backup")
                }
            }
        }
        .tint(ink).preferredColorScheme(.dark).statusBarHidden().persistentSystemOverlays(.hidden)
        .accessibilityAction(named: "Return to backup") { dismiss() }
        .onAppear {
            previousBatteryMonitoring = UIDevice.current.isBatteryMonitoringEnabled
            previousIdleTimer = UIApplication.shared.isIdleTimerDisabled
            UIDevice.current.isBatteryMonitoringEnabled = true
            battery = .current; UIApplication.shared.isIdleTimerDisabled = keepsAwake
        }
        .onDisappear {
            UIApplication.shared.isIdleTimerDisabled = previousIdleTimer
            UIDevice.current.isBatteryMonitoringEnabled = previousBatteryMonitoring
        }
        .onChange(of: keepsAwake) { _, awake in UIApplication.shared.isIdleTimerDisabled = awake }
        .onReceive(NotificationCenter.default.publisher(for: UIDevice.batteryStateDidChangeNotification)) { _ in battery = .current }
        .onReceive(NotificationCenter.default.publisher(for: UIDevice.batteryLevelDidChangeNotification)) { _ in battery = .current }
    }
    private var lockMessage: String {
        if lowBattery { return "Low battery · Auto-lock allowed" }
        if keepsAwake { return "Keep Cloudified open to continue" }
        return state.waitingForProtectedSends ? "Verifying uploads · Auto-lock allowed" : "Auto-lock allowed"
    }
    private func provider(_ provider: ProviderCardState) -> some View {
        let transfer = state.currentTransfers.first { $0.provider == provider.name }
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Label(provider.name, systemImage: provider.name == "Telegram" ? "paperplane" : "photo.stack")
                    .font(.subheadline.weight(.medium))
                Spacer(minLength: 8)
                Text(provider.isEnabled ? provider.savedCount.map { $0.formatted() } ?? "—" : "Off")
                    .monospacedDigit().foregroundStyle(ink)
            }.foregroundStyle(.white.opacity(bright ? 0.94 : 0.80))
            BackupMeter(fraction: providerFraction(provider), color: ink)
            HStack(alignment: .firstTextBaseline) {
                Text(provider.isEnabled ? provider.remainingCount.map { "\($0.formatted()) remaining" } ?? "Not scanned" : "Destination disabled")
                Spacer(minLength: 8)
                Text(transfer?.percentageText ?? " ")
            }.font(.caption).monospacedDigit().foregroundStyle(secondary)
            Text(transfer?.totalBytes == nil ? "No active transfer" : transfer?.byteProgressText ?? "No active transfer")
                .font(.caption).foregroundStyle(secondary).monospacedDigit().lineLimit(1, reservesSpace: true)
        }.accessibilityElement(children: .combine)
    }
    private func providerFraction(_ provider: ProviderCardState) -> Double? {
        guard let saved = provider.savedCount, let total = provider.totalCount, total > 0 else { return nil }
        return min(1, max(0, Double(saved) / Double(total)))
    }
}

private struct BatteryReading: Equatable {
    let unplugged: Bool
    let level: Float
    @MainActor static var current: BatteryReading {
        let device = UIDevice.current
        return BatteryReading(unplugged: device.batteryState == .unplugged || device.batteryState == .unknown, level: device.batteryLevel)
    }
}
