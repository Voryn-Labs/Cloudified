import SwiftUI
import UIKit

struct KeepAwakeView: View {
    @ObservedObject private var presentation: ScreenStateStore<DashboardViewState>
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.scenePhase) private var scenePhase
    @State private var battery = BatteryReading.current
    @State private var previousBatteryMonitoring = false
    @State private var previousIdleTimer = false

    init(environment: AppEnvironment) { presentation = environment.dashboardPresentation }
    private var state: DashboardViewState { presentation.value }
    private var lowBattery: Bool { battery.unplugged && battery.level >= 0 && battery.level < 0.2 }
    private var keepsAwake: Bool { state.keepAwakeAllowed && !lowBattery && scenePhase == .active }
    private let ink = Color(red: 0.49, green: 0.88, blue: 0.77)

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center) {
                Label("Keep Awake", systemImage: "moon.stars").font(.subheadline)
                    .foregroundStyle(.white.opacity(0.4))
                Spacer(minLength: 16)
                Button { dismiss() } label: {
                    Image(systemName: "xmark").font(.body.weight(.medium))
                        .frame(width: 44, height: 44).contentShape(Rectangle())
                }
                .buttonStyle(.plain).foregroundStyle(.white.opacity(0.6))
                .accessibilityLabel("Return to backup")
            }
            .padding(.horizontal, 20).padding(.top, 8)
            GeometryReader { geometry in
                ScrollView {
                    VStack(spacing: 0) {
                        Spacer(minLength: 32)
                        VStack(spacing: 12) {
                            Image("BrandMark").resizable().scaledToFit().frame(width: 52, height: 52)
                                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous)).accessibilityHidden(true)
                            Text(state.savedToBothCount.map { $0.formatted() } ?? "—")
                                .font(.system(.largeTitle, design: .rounded, weight: .medium)).monospacedDigit()
                                .foregroundStyle(.white.opacity(0.85))
                            Text(state.accessibleLibraryTotal.map { "of \($0.formatted()) saved to both" } ?? "Library not scanned")
                                .font(.subheadline).foregroundStyle(.white.opacity(0.5)).monospacedDigit()
                            Text(state.summaryTitle).font(.caption.weight(.medium)).foregroundStyle(ink)
                        }
                        .multilineTextAlignment(.center).frame(maxWidth: .infinity)
                        .padding(.bottom, 40)
                        VStack(spacing: 28) {
                            provider(state.googleStatus)
                            provider(state.telegramStatus)
                        }
                        Spacer(minLength: 32)
                        VStack(spacing: 16) {
                            Label(lockMessage, systemImage: keepsAwake ? "display" : "lock")
                                .font(.caption).foregroundStyle(.white.opacity(0.45))
                                .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                            if battery.level >= 0 {
                                Label("\(Int((battery.level * 100).rounded()))%\(battery.unplugged ? "" : " · plugged in")",
                                      systemImage: battery.unplugged ? "battery.50" : "battery.100.bolt")
                                    .font(.caption2).monospacedDigit().foregroundStyle(.white.opacity(0.35))
                            }
                        }
                    }
                    .frame(maxWidth: 340).frame(minHeight: max(0, geometry.size.height - 48))
                    .padding(.horizontal, 28).padding(.vertical, 24).frame(maxWidth: .infinity)
                    .opacity(contrast == .increased ? 1 : 0.65)
                }
            }
        }
        .background(Color.black.ignoresSafeArea())
        .statusBarHidden().persistentSystemOverlays(.hidden).preferredColorScheme(.dark)
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
        if lowBattery { return "Low battery · auto-lock allowed" }
        if keepsAwake { return "Screen stays awake while backup runs" }
        return state.waitingForProtectedSends ? "Waiting for verification · auto-lock allowed" : "Auto-lock allowed"
    }
    private func provider(_ provider: ProviderCardState) -> some View {
        let transfer = state.currentTransfers.first { $0.provider == provider.name }
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Label(provider.name, systemImage: provider.name == "Telegram" ? "paperplane" : "photo.stack")
                    .font(.subheadline.weight(.medium)).foregroundStyle(.white.opacity(0.75))
                Spacer(minLength: 4)
                Text(provider.savedCount.map { $0.formatted() } ?? "—")
                    .font(.subheadline.weight(.medium)).monospacedDigit().foregroundStyle(ink)
            }
            BackupMeter(fraction: fraction(provider), color: ink.opacity(0.7))
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(provider.isEnabled ? (provider.remainingCount.map { "\($0.formatted()) remaining" } ?? "Not scanned") : "Off")
                Spacer(minLength: 4)
                Text(transfer?.percentageText ?? " ")
            }
            .font(.caption).monospacedDigit().foregroundStyle(.white.opacity(0.45))
            Text(transfer?.totalBytes == nil ? " " : transfer?.byteProgressText ?? " ")
                .font(.caption2).foregroundStyle(.white.opacity(0.35)).monospacedDigit()
                .lineLimit(1, reservesSpace: true)
        }.accessibilityElement(children: .combine)
    }
    private func fraction(_ provider: ProviderCardState) -> Double? {
        guard let saved = provider.savedCount, let total = provider.totalCount, total > 0 else { return nil }
        return Double(saved) / Double(total)
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
