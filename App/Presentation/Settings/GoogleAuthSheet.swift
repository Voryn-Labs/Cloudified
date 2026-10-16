import SwiftUI
public struct GoogleAuthSheet: View {
    @ObservedObject public var environment: AppEnvironment
    @ObservedObject private var presentation: ScreenStateStore<SettingsViewState>
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var oauthToken = ""
    @State private var showBrowser = false
    @State private var loading = true
    @State private var browserError: String?
    @State private var exchanging = false
    @State private var connected = false
    @State private var loginTask: Task<Void, Never>?
    private var busy: Bool { exchanging || environment.settingsState.isConnectingGoogle || environment.settingsState.isSettlingGoogle }
    private var controlsAvailable: Bool { environment.settingsState.controlsAvailable && !busy }
    public init(environment: AppEnvironment) { self.environment = environment; self.presentation = environment.settingsPresentation }

    public var body: some View {
        NavigationStack {
            Group {
                if connected {
                    List {
                        Section {
                            FlowIntro(systemName: "checkmark.circle.fill", title: "Google Photos connected", message: "This account is ready. Return to Backup when you want uploads to run.")
                            LabeledContent("Account", value: environment.settingsState.googleAccountEmail ?? "Verified account")
                                .privacySensitive()
                        }
                        Section {
                            Button("Done") { dismiss() }
                                .frame(maxWidth: .infinity)
                        } footer: {
                            Link("Manage Google devices", destination: URL(string: "https://myaccount.google.com/device-activity")!)
                        }
                    }
                } else if exchanging {
                    WorkingBlock(title: "Verifying your account", message: "Checking the destination before enabling uploads.", fillsScreen: true)
                } else if showBrowser {
                    VStack(spacing: 0) {
                        Text("Sign in with the account you want to back up to. This page closes itself when Google finishes.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)
                            .background(.bar)
                        ZStack {
                            GoogleAccountLoginView(active: scenePhase == .active,
                                onToken: connect, onLoading: { loading = $0 }, onFailure: { message, failure in
                                    showBrowser = false; browserError = message
                                    loginTask = Task { await environment.report(failure, provider: .google) }
                                })
                            if loading {
                                WorkingBlock(title: "Loading Google", message: "The sign-in page is separate from Safari.", fillsScreen: true)
                                    .background(.background)
                            }
                        }
                    }
                } else {
                    List {
                        Section {
                            FlowIntro(systemName: "photo.on.rectangle.angled", title: "Choose the backup account", message: "Sign in with the Google account that should receive original photos and videos. This session is separate from Safari and your other Google apps.")
                            Button("Sign in to Google") { loading = true; browserError = nil; showBrowser = true }
                                .disabled(!controlsAvailable)
                        } footer: {
                            Text("Google lists this sign-in as a separate Android device. Removing it in Google Account → Security → Your devices signs Cloudified out. Keep another working verification method; Cloudified cannot receive Google’s own security prompts.")
                        }
                        if environment.canRetryGoogleVerification && (browserError ?? environment.settingsState.googleAuthErrorMessage) == nil {
                            Section {
                                Button("Use saved sign-in") { retrySaved() }
                                    .disabled(!controlsAvailable)
                            } header: {
                                Text("Saved sign-in found")
                            } footer: {
                                Text("This iPhone still holds a Google sign-in from before, for example from an earlier install. It is checked again before any upload. Signing in above replaces it.")
                            }
                        }
                        if let error = browserError ?? environment.settingsState.googleAuthErrorMessage {
                            Section("Connection issue") {
                                IssueBlock(message: error)
                                if environment.canRetryGoogleVerification {
                                    Button("Retry saved connection") { retrySaved() }
                                        .disabled(!controlsAvailable)
                                }
                            }
                        }
                        Section {
                            DisclosureGroup("If sign-in cannot finish here") {
                                Text("Safari cannot share its protected login cookie with this app. Opening Safari alone does not connect the account.")
                                Text("On a desktop browser, open Google’s EmbeddedSetup page in a private window and sign in. Copy only the oauth_token cookie for accounts.google.com, paste it below, then close that window.")
                                Text("Paste that value only in Cloudified. A normal API token, master token, or password will not work.")
                                Link("Open Google’s sign-in page", destination: URL(string: "https://accounts.google.com/EmbeddedSetup")!)
                            }
                        }
                        Section {
                            DisclosureGroup("Use a login token") {
                                SecureField("Google login token", text: $oauthToken)
                                    .autocorrectionDisabled()
                                    .textInputAutocapitalization(.never)
                                Button("Connect with token") {
                                    let value = oauthToken.trimmingCharacters(in: .whitespacesAndNewlines)
                                    oauthToken = ""
                                    connect(value)
                                }
                                .disabled(!controlsAvailable || oauthToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            }
                        }
                    }
                }
            }
            .cloudifiedList().navigationTitle("Google Photos")
            .navigationBarTitleDisplayMode(.inline)
            .interactiveDismissDisabled(busy)
            .onDisappear { oauthToken = ""; showBrowser = false; loginTask?.cancel() }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(showBrowser ? "Back" : "Cancel") {
                        if showBrowser { showBrowser = false } else { dismiss() }
                    }
                    .disabled(busy)
                }
            }
        }
    }

    private func retrySaved() {
        guard controlsAvailable else { return }
        exchanging = true
        loginTask = Task {
            defer { exchanging = false }
            do { try await environment.retryGoogleVerification(); connected = true }
            catch { }
        }
    }

    private func connect(_ token: String) {
        guard controlsAvailable, !token.isEmpty else { return }
        showBrowser = false; exchanging = true; browserError = nil
        loginTask = Task {
            defer { exchanging = false }
            do {
                try await environment.connectGoogle(oauthToken: token)
                connected = true
            } catch { }
        }
    }
}
