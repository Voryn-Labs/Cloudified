import SwiftUI
import CloudifiedCore

public struct TelegramAuthSheet: View {
    @ObservedObject public var environment: AppEnvironment
    @ObservedObject private var presentation: ScreenStateStore<SettingsViewState>
    @Environment(\.dismiss) private var dismiss

    @State private var apiIdText = ""
    @State private var apiHashText = ""

    @State private var phoneNumber = ""
    @State private var verificationCode = ""
    @State private var password = ""
    @State private var email = ""
    @State private var emailCode = ""
    @State private var confirmLogout = false
    @State private var showingPicker = false
    @State private var actionTask: Task<Void, Never>?
    @State private var isWorking = false
    @State private var actionError: String?

    private var busy: Bool {
        isWorking || environment.settingsState.isConnectingTelegram || environment.settingsState.isSettlingTelegram
    }
    private var controlsAvailable: Bool { environment.settingsState.controlsAvailable && !busy }

    public init(environment: AppEnvironment) {
        self.environment = environment; self.presentation = environment.settingsPresentation
    }

    public var body: some View {
        NavigationStack {
            Form {
                switch environment.settingsState.telegramAuthStep {
                case .initializing:
                    Section {
                        FlowIntro(systemName: "paperplane.fill", title: "Starting Telegram", message: "The session has to be ready before a phone number or channel can be chosen.")
                        if environment.settingsState.telegramAuthErrorMessage != nil && !busy {
                            Button("Try again") { perform { try await environment.reconnectTelegram() } }
                                .disabled(!controlsAvailable)
                        } else {
                            ProgressView("Starting Telegram…")
                        }
                    }
                case .unconfigured:
                    apiCredentialsSection
                case .enterPhoneNumber:
                    phoneNumberSection
                case .enterCode:
                    codeSection
                case .enterPassword:
                    passwordSection
                case .enterEmail:
                    emailSection
                case .enterEmailCode:
                    emailCodeSection
                case .otherDeviceConfirmation:
                    otherDeviceSection
                case .registration:
                    registrationSection
                case .premiumPurchase:
                    premiumSection
                case .readyForChannel, .connected:
                    channelMappingSection
                case .closing, .closed, .error:
                    errorOrClosedSection
                }
                Section { NavigationLink("Telegram setup guide") { TelegramGuideView() } }
                if busy { Section { WorkingBlock(title: "Updating Telegram", message: "This step finishes before the next one opens.") } }
                if let message = actionError ?? environment.settingsState.telegramAuthErrorMessage {
                    Section("Connection issue") { IssueBlock(message: message) }
                }
            }
            .disabled(busy)
            .cloudifiedList().navigationTitle("Connect Telegram")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { actionTask?.cancel(); clearInputs(); dismiss() }
                }
            }
            .interactiveDismissDisabled(busy)
            .alert("Log out of this app's Telegram session?", isPresented: $confirmLogout) {
                Button("Cancel", role: .cancel) { }
                Button("Log out", role: .destructive) { perform { try await environment.logoutTelegram() } }
            } message: { Text("Other Telegram apps and devices stay signed in. This app's current destination will be disconnected.") }
            .sheet(isPresented: $showingPicker) {
                NavigationStack {
                    TelegramChannelPicker(environment: environment) { showingPicker = false; dismiss() }
                        .toolbar {
                            ToolbarItem(placement: .cancellationAction) {
                                Button("Cancel") { showingPicker = false }.disabled(busy)
                            }
                        }
                }
                .interactiveDismissDisabled(busy)
            }
            .onDisappear { clearInputs(); actionTask?.cancel(); actionTask = nil }
        }
    }

    private var apiCredentialsSection: some View {
        Section {
            FlowIntro(systemName: "key.fill", title: "Telegram API credentials", message: "These identify this app to Telegram. They are not your phone number or password.")
            Link("Get credentials at my.telegram.org", destination: URL(string: "https://my.telegram.org/apps")!)
            TextField("API ID", text: $apiIdText)
                .keyboardType(.numberPad)
            SecureField("API hash", text: $apiHashText)
                .textContentType(.password)
                .autocorrectionDisabled()
            Button("Continue", action: saveCredentials)
                .disabled((Int32(apiIdText.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0) <= 0 || apiHashText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !controlsAvailable)
        } footer: {
            Text("Create an application on my.telegram.org, then enter its API ID and API hash here.")
        }
    }

    private var phoneNumberSection: some View {
        Section {
            FlowIntro(systemName: "phone.fill", title: "Phone number", message: "Use the number on the Telegram account that should own the archive.")
            TextField("Phone number", text: $phoneNumber)
                .keyboardType(.phonePad)
                .textContentType(.telephoneNumber)
            Button("Continue", action: submitPhone)
                .disabled(phoneNumber.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !controlsAvailable)
        } footer: {
            Text("Start with + and the country code. Spaces and brackets are fine.")
        }
    }

    private var codeSection: some View {
        Section {
            FlowIntro(systemName: "number", title: "Verification code", message: "Enter the code Telegram sent to your other devices or by SMS.")
            TextField("Code", text: $verificationCode)
                .keyboardType(.numberPad)
                .textContentType(.oneTimeCode)
            Button("Continue", action: submitCode)
                .disabled(verificationCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !controlsAvailable)
        }
    }

    private var passwordSection: some View {
        Section {
            FlowIntro(systemName: "lock.fill", title: "Two-step password", message: "This is the cloud password on the Telegram account, not the phone’s passcode.")
            SecureField("Password", text: $password)
                .textContentType(.password)
            Button("Continue", action: submitPassword)
                .disabled(password.isEmpty || !controlsAvailable)
        }
    }

    private var emailSection: some View {
        Section {
            FlowIntro(systemName: "envelope.fill", title: "Email address", message: "Telegram asked for the recovery email on this account.")
            TextField("Email", text: $email)
                .keyboardType(.emailAddress)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button("Continue", action: submitEmail)
                .disabled(email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !controlsAvailable)
        }
    }

    private var emailCodeSection: some View {
        Section {
            FlowIntro(systemName: "envelope.badge", title: "Email code", message: "Enter the code Telegram sent to that email.")
            TextField("Code", text: $emailCode)
                .keyboardType(.numberPad)
            Button("Continue", action: submitEmailCode)
                .disabled(emailCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !controlsAvailable)
        }
    }

    private var otherDeviceSection: some View {
        Section {
            FlowIntro(systemName: "ipad.and.iphone", title: "Confirm on another device", message: "Open Telegram somewhere this account is already signed in and approve the request. This screen updates when Telegram does.")
        }
    }

    private var registrationSection: some View {
        Section {
            FlowIntro(systemName: "person.crop.circle.badge.exclamationmark", title: "This number is not on Telegram", message: "Register it in the official Telegram app first, then come back and sign in here.")
        }
    }

    private var premiumSection: some View {
        Section {
            FlowIntro(systemName: "star.circle", title: "Telegram Premium is required", message: "Telegram will not finish this sign-in until the account has Telegram Premium.")
        }
    }

    private var channelMappingSection: some View {
        Section {
            FlowIntro(systemName: "paperplane.fill", title: "Choose the archive channel", message: "Pick a private channel you own, with auto-delete turned off. Existing uploads are checked before this destination is enabled.")
            Button("Select channel") { showingPicker = true }
                .disabled(!controlsAvailable)
            Button("Log out to switch account", role: .destructive) { confirmLogout = true }
                .disabled(!controlsAvailable)
        }
    }

    private var errorOrClosedSection: some View {
        Section {
            FlowIntro(systemName: "exclamationmark.arrow.circlepath", title: "Telegram needs to start again", message: "The session is \(environment.settingsState.telegramAuthStep.rawValue). Starting again does not delete messages already sent.")
            Button("Start Telegram again") { perform { try await environment.reconnectTelegram() } }
                .disabled(!controlsAvailable)
        }
    }

    private func saveCredentials() {
        guard let id = Int32(apiIdText.trimmingCharacters(in: .whitespacesAndNewlines)), id > 0 else { return }
        let hash = apiHashText.trimmingCharacters(in: .whitespacesAndNewlines)
        apiHashText = ""
        perform { try await environment.saveTelegramAPICredentials(apiId: id, apiHash: hash) }
    }
    private func submitPhone() {
        let phone = phoneNumber.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !phone.isEmpty else { return }
        perform { try await environment.submitTelegramPhone(phone); phoneNumber = "" }
    }
    private func submitCode() {
        let code = verificationCode.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !code.isEmpty else { return }
        perform { try await environment.submitTelegramCode(code); verificationCode = "" }
    }
    private func submitPassword() {
        let pwd = password
        guard !pwd.isEmpty else { return }
        password = ""
        perform { try await environment.submitTelegramPassword(pwd) }
    }
    private func submitEmail() {
        let em = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !em.isEmpty else { return }
        perform { try await environment.submitTelegramEmail(em); email = "" }
    }
    private func submitEmailCode() {
        let code = emailCode.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !code.isEmpty else { return }
        perform { try await environment.submitTelegramEmailCode(code); emailCode = "" }
    }

    private func perform(_ operation: @escaping @MainActor () async throws -> Void) {
        guard controlsAvailable else { return }
        isWorking = true; actionError = nil
        actionTask = Task {
            defer { isWorking = false; actionTask = nil }
            do { try Task.checkCancellation(); try await operation() }
            catch is CancellationError { }
            catch { actionError = FailureExplanation.message(ProviderSupport.safe(error, domain: .tdlib)) }
        }
    }
    private func clearInputs() {
        apiIdText = ""; apiHashText = ""; phoneNumber = ""; verificationCode = ""
        password = ""; email = ""; emailCode = ""
    }

}
