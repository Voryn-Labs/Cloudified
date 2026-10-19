import SwiftUI
import UIKit

public struct DashboardView: View {
    @ObservedObject public var environment: AppEnvironment
    @ObservedObject private var presentation: ScreenStateStore<DashboardViewState>
    @Environment(\.openURL) private var openURL
    @State private var showingGoogle = false
    @State private var showingTelegram = false
    @State private var showingKeepAwake = false
    @State private var showingConditions = false

    public init(environment: AppEnvironment) { self.environment = environment; presentation = environment.dashboardPresentation }
    private var state: DashboardViewState { presentation.value }
    private var providers: [ProviderCardState] { [state.googleStatus, state.telegramStatus].filter(\.isConnected) }
    private var issueSummary: String {
        let failed = providers.compactMap(\.failedCount).reduce(0, +)
        let waiting = providers.compactMap(\.waitingCount).reduce(0, +)
        if failed > 0 || waiting > 0 { return "\(failed.formatted()) failed · \(waiting.formatted()) waiting" }
        return "Issues, diagnostics and support"
    }

    public var body: some View {
        NavigationStack {
            List {
                if !state.photosAccess.canRead || state.accessibleLibraryTotal == nil { setupSection }
                Section {
                    OverallActivityCard(title: state.summaryTitle,
                        libraryTotal: state.accessibleLibraryTotal, savedToBoth: state.savedToBothCount,
                        canPause: state.canPause && state.controlsAvailable,
                        canResume: state.canResume && state.controlsAvailable && state.canStartBackup,
                        canStart: state.canStartBackup && state.controlsAvailable && !state.canPause,
                        transitionLabel: state.controlActivity,
                        onBackUp: environment.requestBackup, onPause: environment.requestPause, onResume: environment.requestResume)
                }
                Section("Destinations") {
                    ProviderStatusCard(state: state.googleStatus,
                        transfer: state.currentTransfers.first { $0.provider == "Google Photos" }, onSettingsTapped: { showingGoogle = true })
                    ProviderStatusCard(state: state.telegramStatus,
                        transfer: state.currentTransfers.first { $0.provider == "Telegram" }, onSettingsTapped: { showingTelegram = true })
                }
                Section {
                    NavigationLink { libraryDetails } label: {
                        MenuRow(title: "Library", symbol: "photo.stack", subtitle: librarySummary)
                    }
                    Button {
                        environment.visibleActivityPage = .issues; environment.selectedTab = .activity
                    } label: {
                        MenuRow(title: "Activity & issues", symbol: "list.bullet.rectangle", subtitle: issueSummary)
                    }.buttonStyle(.plain)
                }
            }
            .cloudifiedList()
            .navigationTitle("Cloudified").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) { BrandTitle() }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("Keep awake", systemImage: "moon.stars") { showingKeepAwake = true }.disabled(!state.workInProgress)
                        Button("Backup conditions", systemImage: "antenna.radiowaves.left.and.right") { showingConditions = true }
                    } label: { Label("Backup options", systemImage: "ellipsis.circle") }
                }
            }
            .sheet(isPresented: $showingGoogle) { GoogleAuthSheet(environment: environment) }
            .sheet(isPresented: $showingTelegram) { TelegramAuthSheet(environment: environment) }
            .sheet(isPresented: $showingConditions) {
                NavigationStack {
                    List { Section { backgroundDetails } }.cloudifiedList()
                        .navigationTitle("Backup conditions").navigationBarTitleDisplayMode(.inline)
                        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showingConditions = false } } }
                }
            }
            .fullScreenCover(isPresented: $showingKeepAwake) { KeepAwakeView(environment: environment) }
        }
    }

    private var librarySummary: String {
        guard let photos = state.photosSection.totalCount, let videos = state.videosSection.totalCount else { return "Photos and videos" }
        return "\(photos.formatted()) photos · \(videos.formatted()) videos"
    }
    private var libraryDetails: some View {
        List {
            Section {
                MediaSectionCard(state: state.photosSection)
                MediaSectionCard(state: state.videosSection)
            }
            Section("Photos access") {
                LabeledContent("Access", value: state.permissionScopeDescription).font(.subheadline)
                if let date = state.scanTimestamp { LabeledContent("Last scan", value: date.formatted(date: .abbreviated, time: .shortened)).font(.subheadline) }
                Button("Scan library again", systemImage: "arrow.clockwise", action: environment.requestPhotoLibraryAccess)
                    .disabled(!state.controlsAvailable || state.canPause || state.isReadingLibrary)
            }
        }
        .cloudifiedList().navigationTitle("Library").navigationBarTitleDisplayMode(.inline)
    }
    @ViewBuilder private var backgroundDetails: some View {
        if let status = state.backgroundStatus { Label(status, systemImage: "clock").font(.subheadline) }
        if state.lowPowerMode { Label("Low Power Mode is on. Background work and iCloud originals may be delayed.", systemImage: "battery.25").font(.subheadline) }
        if state.backgroundRefreshOff {
            IssueBlock(message: "Background App Refresh is unavailable. You can still back up with Cloudified open.")
            Button("Open iPhone Settings") { openURL(URL(string: UIApplication.openSettingsURLString)!) }
        }
        if let notice = state.interruptedRunNotice {
            IssueBlock(message: notice)
            Button("Dismiss notice", action: environment.acknowledgeInterruptedRun)
        }
        if let run = state.lastBackgroundRun { Text(run).font(.footnote).foregroundStyle(.secondary) }
        Text("Keep Awake keeps this app open on a black screen. It works best while charging. It does not enable uploads after the phone locks; iOS controls background time.")
            .font(.footnote).foregroundStyle(.secondary)
    }
    private var setupSection: some View {
        Section {
            FlowIntro(systemName: "photo.badge.checkmark", title: state.photosAccess.canRead ? "Read your library" : "Your originals, backed up",
                message: "Allow Photos access, then connect Google Photos or Telegram in Settings. Backup includes accessible hidden photos and every burst frame.")
            if state.photosAccess == .denied || state.photosAccess == .restricted {
                Button("Open iPhone Settings") { openURL(URL(string: UIApplication.openSettingsURLString)!) }
            } else {
                Button(state.photosAccess.canRead ? "Scan library" : "Allow Photos access", systemImage: "photo", action: environment.requestPhotoLibraryAccess)
                    .disabled(!state.controlsAvailable || state.isReadingLibrary)
            }
        }
    }
}
