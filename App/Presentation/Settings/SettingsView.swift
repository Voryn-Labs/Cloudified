import SwiftUI
import UIKit
import CloudifiedCore

public struct SettingsView: View {
    @ObservedObject public var environment: AppEnvironment
    @ObservedObject private var presentation: ScreenStateStore<SettingsViewState>
    private enum LinkSheet: String, Identifiable {
        case google, telegram, channel
        var id: String { rawValue }
    }
    @AppStorage("CloudifiedAppearance") private var appearance = AppAppearance.system
    @AppStorage("CloudifiedAwakeStyle") private var awakeStyle = AwakeStyle.dim
    @State private var linkSheet: LinkSheet?
    @State private var showingGoogleDisconnectAlert = false
    @State private var showingTelegramDisconnectAlert = false
    @State private var showingTelegramLogoutAlert = false
    @State private var showingTelegramResetAlert = false
    @State private var showingWalkthrough = false
    @State private var actionTask: Task<Void, Never>?
    @State private var isWorking = false
    @State private var actionError: String?

    public init(environment: AppEnvironment) { self.environment = environment; self.presentation = environment.settingsPresentation }
    private var state: SettingsViewState { environment.settingsState }
    private var busy: Bool {
        isWorking || state.isConnectingGoogle || state.isConnectingTelegram || state.isSettlingGoogle || state.isSettlingTelegram
    }
    private var controlsAvailable: Bool { environment.settingsState.controlsAvailable && !busy }
    private func status(connected: Bool, enabled: Bool) -> String {
        connected ? (enabled ? "Enabled" : "Disabled") : "Not connected"
    }

    public var body: some View {
        NavigationStack {
            List {
                Section {
                    NavigationLink { aboutSettings } label: { BrandHeader() }
                }
                Section("Accounts") {
                    NavigationLink { googlePhotosSettings } label: {
                        destinationRow("Google Photos", symbol: "photo.stack.fill",
                            status: state.isGoogleConnected ? (state.googleAccountEmail ?? "Connected") : "Not connected",
                            detail: status(connected: state.isGoogleConnected, enabled: state.isGoogleEnabled))
                    }
                    NavigationLink { telegramSettings } label: {
                        destinationRow("Telegram", symbol: "paperplane.fill",
                            status: state.isTelegramConnected ? (state.telegramChannelName ?? "Connected") : "Not connected",
                            detail: status(connected: state.isTelegramConnected, enabled: state.isTelegramEnabled))
                    }
                }
                Section("Preferences") {
                    NavigationLink { appearanceSettings } label: {
                        MenuRow(title: "Appearance", symbol: "moon", subtitle: appearance.title)
                    }
                    NavigationLink { backupPreferences } label: {
                        MenuRow(title: "Backup preferences", symbol: "slider.horizontal.3", subtitle: "Automatic backup, network and power")
                    }
                    NavigationLink { libraryAccessSettings } label: {
                        MenuRow(title: "Photos access", symbol: "photo.badge.checkmark", subtitle: state.photosAccess.description)
                    }
                    NavigationLink { AlbumExclusionsView(environment: environment) } label: {
                        MenuRow(title: "Excluded albums", symbol: "rectangle.stack.badge.minus", subtitle: "Separate Google Photos and Telegram rules")
                    }
                    NavigationLink { livePhotoSettings } label: {
                        MenuRow(title: "Live Photos", symbol: "livephoto", subtitle: state.livePhotoFallback.rawValue)
                    }
                }
                Section("Support") {
                    Button { showingWalkthrough = true } label: { MenuRow(title: "Getting started", symbol: "play.rectangle", subtitle: "Setup, storage and account risks") }
                    NavigationLink { HelpView(environment: environment) } label: { MenuRow(title: "Help & guides", symbol: "questionmark") }
                    NavigationLink { FeedbackView(environment: environment) } label: { MenuRow(title: "Report a problem", symbol: "bubble.left.and.text.bubble.right") }
                }
            }
            .cloudifiedList()
            .navigationTitle("Settings").navigationBarTitleDisplayMode(.inline)
            .fullScreenCover(isPresented: $showingWalkthrough) {
                WalkthroughView { _ in showingWalkthrough = false }
            }
            .sheet(item: $linkSheet) { sheet in
                switch sheet {
                case .google: GoogleAuthSheet(environment: environment)
                case .telegram: TelegramAuthSheet(environment: environment)
                case .channel:
                    NavigationStack {
                        TelegramChannelPicker(environment: environment) { linkSheet = nil }
                            .toolbar {
                                ToolbarItem(placement: .cancellationAction) {
                                    Button("Cancel") { linkSheet = nil }
                                        .disabled(state.isConnectingTelegram || state.isSettlingTelegram)
                                }
                            }
                    }
                    .interactiveDismissDisabled(state.isConnectingTelegram || state.isSettlingTelegram)
                }
            }
            .alert("Account operation failed", isPresented: Binding(
                get: { actionError != nil }, set: { if !$0 { actionError = nil } }
            )) { Button("OK", role: .cancel) { } }
            message: { Text(actionError ?? "") }
            .onDisappear { actionTask?.cancel() }
        }
    }

    private var appearanceSettings: some View {
        List {
            Section { BrandHeader() }
            Section {
                Picker("Keep Awake", selection: $awakeStyle) {
                    ForEach(AwakeStyle.allCases) { Text($0.rawValue).tag($0) }
                }
                Picker("Appearance", selection: $appearance) {
                    ForEach(AppAppearance.allCases) { Text($0.title).tag($0) }
                }.pickerStyle(.inline)
            } header: { Text("Theme") } footer: {
                Text("System follows your iPhone. Night uses dark surfaces throughout Cloudified. Keep Awake always uses pure black.")
            }
        }.cloudifiedList().navigationTitle("Appearance").navigationBarTitleDisplayMode(.inline)
    }

    private var backupPreferences: some View {
        List {
            Section {
                Toggle(isOn: Binding(get: { state.automaticBackup }, set: { environment.setAutomaticBackup($0) })) {
                    Label("Automatic backup", systemImage: "arrow.trianglehead.2.clockwise")
                }
                Toggle(isOn: Binding(get: { state.notificationsEnabled }, set: { environment.setNotifications($0) })) {
                    Label("Backup notifications", systemImage: "bell")
                }
                if state.notificationsRefused {
                    Link("Enable notifications in iPhone Settings", destination: URL(string: UIApplication.openSettingsURLString)!)
                }
            } header: { Text("Scheduling") } footer: { Text("Backup starts when you open Cloudified. Pause stays in effect until you resume. iOS decides when background work can run.") }
            Section {
                Toggle(isOn: Binding(get: { state.isWiFiOnlyEnabled }, set: { environment.setWiFiOnly($0) })) { Label("Wi-Fi only", systemImage: "wifi") }.disabled(busy)
                Toggle(isOn: Binding(get: { state.pauseInLowPower }, set: { environment.setPauseInLowPower($0) })) { Label("Pause in Low Power Mode", systemImage: "battery.25") }.disabled(busy)
            } header: { Text("Network & power") } footer: { Text("These rules pause new work. A Google transfer already managed by iOS may finish.") }
            if let run = state.lastBackgroundRun { Section("Last background run") { Text(run).font(.subheadline).foregroundStyle(.secondary) } }
        }
        .cloudifiedList().navigationTitle("Backup preferences").navigationBarTitleDisplayMode(.inline)
    }

    private var libraryAccessSettings: some View {
        List {
            Section {
                FlowIntro(systemName: "photo.badge.checkmark", title: "Photos access", message: state.photosAccess.description)
                photosAccessActions
            } footer: { Text("Backup includes accessible hidden photos and every burst frame. Limited Photos access restricts backup to the items iOS makes available. Cloudified does not edit or delete your Photos library.") }
        }
        .cloudifiedList().navigationTitle("Photos access").navigationBarTitleDisplayMode(.inline)
    }

    private var aboutSettings: some View {
        List {
            Section { BrandHeader() }
            Section {
                LabeledContent("Version", value: bundleValue("CFBundleShortVersionString"))
                LabeledContent("Runtime", value: AppRuntime.description)
                DisclosureGroup("Build details") {
                    LabeledContent("Build", value: bundleValue("CFBundleVersion"))
                    LabeledContent("Revision", value: bundleValue("CloudifiedRevision")).font(.caption).textSelection(.enabled)
                }
            }
            Section {
                Link(destination: CloudifiedSupport.repository) { MenuRow(title: "Cloudified on GitHub", symbol: "chevron.left.forwardslash.chevron.right") }
                Link(destination: CloudifiedSupport.companyPage) {
                    HStack(spacing: 12) {
                        Image("VorynMark").resizable().scaledToFit().frame(width: 36, height: 36)
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous)).accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Voryn Labs").font(.body.weight(.medium))
                            Text("Independent software studio").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "arrow.up.right").font(.caption).foregroundStyle(.secondary)
                    }.padding(.vertical, 4)
                }
                ShareLink(item: CloudifiedSupport.source) { MenuRow(title: "Share Voryn Labs source", symbol: "square.and.arrow.up") }
            }
        }
        .cloudifiedList().navigationTitle("About Cloudified").navigationBarTitleDisplayMode(.inline)
    }

    private var googlePhotosSettings: some View {
        List {
            Section {
                FlowIntro(systemName: "photo.on.rectangle.angled", title: "Google Photos", message: "Uploads run on their own. Turning this off leaves Telegram running.")
                Toggle("Enable uploads", isOn: Binding(get: { state.isGoogleEnabled }, set: { environment.setGoogleEnabled($0) }))
                    .disabled(!controlsAvailable || !state.isGoogleConnected)
            }
            Section("Account") {
                if state.isGoogleConnected {
                    LabeledContent("Email", value: state.googleAccountEmail ?? "Unavailable").privacySensitive()
                }
                Button(state.isGoogleConnected ? "Change account" : "Connect Google Photos") { linkSheet = .google }
                    .disabled(!controlsAvailable)
            }
            if let error = state.googleAuthErrorMessage {
                Section("Connection issue") { IssueBlock(message: error) }
            }
            if isWorking { Section { WorkingBlock(title: "Updating account", message: "Checking the destination before uploads continue.") } }
            if state.isGoogleConnected {
                Section {
                    Button("Disconnect Google Photos", role: .destructive) { showingGoogleDisconnectAlert = true }
                        .disabled(!controlsAvailable)
                } footer: {
                    Text("Uploads to this account stop. Photos already saved in Google Photos stay there.")
                }
            }
        }
        .cloudifiedList().navigationTitle("Google Photos")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(isWorking)
        .alert("Disconnect Google Photos?", isPresented: $showingGoogleDisconnectAlert) {
            Button("Cancel", role: .cancel) { }
            Button("Disconnect", role: .destructive) { perform { try await environment.disconnectGoogle() } }
        } message: { Text("Uploads to this account stop. Photos already saved in Google Photos remain there.") }
    }

    private var telegramSettings: some View {
        List {
            Section {
                FlowIntro(systemName: "paperplane.fill", title: "Telegram", message: "Original photos and videos are sent as files to a private channel you own.")
                Toggle("Enable uploads", isOn: Binding(get: { state.isTelegramEnabled }, set: { environment.setTelegramEnabled($0) }))
                    .disabled(!controlsAvailable || !state.isTelegramConnected)
            }
            Section { NavigationLink("Telegram setup guide") { TelegramGuideView() } }
            Section("Account and channel") {
                if state.isTelegramConnected {
                    LabeledContent("Account", value: state.telegramAccountName ?? "Unavailable").privacySensitive()
                    LabeledContent("Channel", value: state.telegramChannelName ?? "Unavailable").privacySensitive()
                    if let id = state.telegramChatID { LabeledContent("Channel ID", value: String(id)).privacySensitive() }
                    Button("Change channel") { linkSheet = .channel }.disabled(!controlsAvailable)
                } else {
                    Button("Connect Telegram") { linkSheet = .telegram }.disabled(!controlsAvailable)
                }
            }
            if let error = state.telegramAuthErrorMessage {
                Section("Connection issue") { IssueBlock(message: error) }
            }
            if environment.telegramLocalResetAvailable {
                Section {
                    Button("Reset local Telegram connection", role: .destructive) { showingTelegramResetAlert = true }
                        .disabled(!controlsAvailable)
                } footer: {
                    Text("Use only if restoring the original signing identity did not help. Reset is blocked while unresolved uploads need this connection.")
                }
            }
            if isWorking { Section { WorkingBlock(title: "Updating Telegram", message: "The session stays open until this finishes.") } }
            if state.isTelegramConnected || [.readyForChannel, .connected].contains(state.telegramAuthStep) {
                Section {
                    if state.isTelegramConnected {
                        Button("Disconnect destination", role: .destructive) { showingTelegramDisconnectAlert = true }
                            .disabled(!controlsAvailable)
                    }
                    Button("Log out of this app", role: .destructive) { showingTelegramLogoutAlert = true }
                        .disabled(!controlsAvailable)
                } footer: {
                    Text("Disconnect removes this channel mapping. Log out ends only this app’s Telegram session.")
                }
            }
        }
        .cloudifiedList().navigationTitle("Telegram")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(isWorking)
        .alert("Disconnect destination?", isPresented: $showingTelegramDisconnectAlert) {
            Button("Cancel", role: .cancel) { }
            Button("Disconnect", role: .destructive) { perform { try await environment.disconnectTelegram() } }
        } message: { Text("This removes the local channel mapping. Your Telegram session and saved files remain.") }
        .alert("Log out of this app's Telegram session?", isPresented: $showingTelegramLogoutAlert) {
            Button("Cancel", role: .cancel) { }
            Button("Log out", role: .destructive) { perform { try await environment.logoutTelegram() } }
        } message: { Text("Other Telegram apps and devices stay signed in. This app's current destination will be disconnected.") }
        .alert("Reset local Telegram connection?", isPresented: $showingTelegramResetAlert) {
            Button("Cancel", role: .cancel) { }
            Button("Reset connection", role: .destructive) { perform { try await environment.resetTelegramConnectionAfterKeyLoss() } }
        } message: {
            Text("This removes the unreadable local Telegram database and cache. Sign in and choose your channel again. Messages already uploaded to Telegram and Cloudified's backup record stay intact. Reset cannot continue while an upload still needs the local data.")
        }
    }

    private var livePhotoSettings: some View {
        List {
            Section {
                FlowIntro(systemName: "livephoto", title: "Live Photos", message: "Telegram always keeps the original photo and the original motion video. Google follows the choice below.")
                Picker("Google Photos", selection: Binding(get: { state.livePhotoFallback }, set: { environment.updateLivePhotoPolicy($0) })) {
                    ForEach(LivePhotoFallbackOption.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.inline)
                .disabled(!controlsAvailable)
            } footer: {
                Text(state.livePhotoFallback.summaryDescription)
            }
        }
        .cloudifiedList().navigationTitle("Live Photos")
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder private var photosAccessActions: some View {
        if environment.settingsState.photosAccess == .notDetermined {
            Button("Allow Photos access", action: environment.requestPhotoLibraryAccess).disabled(!controlsAvailable)
        } else if environment.settingsState.photosAccess == .restricted {
            Text("Photos access is restricted by this device's settings.").foregroundStyle(.secondary)
        } else {
            Link("Change Photos access", destination: URL(string: UIApplication.openSettingsURLString)!)
            if environment.settingsState.photosAccess.canRead {
                Button("Scan library", action: environment.requestPhotoLibraryAccess)
                    .disabled(!controlsAvailable || environment.settingsState.backupCanPause)
            }
        }
    }

    private func destinationRow(_ title: String, symbol: String, status: String, detail: String) -> some View {
        MenuRow(title: title, symbol: symbol,
            subtitle: status == "Not connected" ? status : "\(status) · \(detail)").privacySensitive()
    }

    private func bundleValue(_ key: String) -> String {
        Bundle.main.object(forInfoDictionaryKey: key) as? String ?? "Unavailable"
    }
    private func perform(_ operation: @escaping @MainActor () async throws -> Void) {
        guard controlsAvailable else { return }
        isWorking = true; actionError = nil
        actionTask = Task {
            defer { isWorking = false; actionTask = nil }
            do { try Task.checkCancellation(); try await operation() }
            catch is CancellationError { }
            catch { actionError = FailureExplanation.message(ProviderSupport.safe(error, domain: .core)) }
        }
    }
}
