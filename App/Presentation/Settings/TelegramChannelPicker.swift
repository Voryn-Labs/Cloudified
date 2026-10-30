import SwiftUI
import CloudifiedCore

public struct TelegramChannelPicker: View {
    @ObservedObject var environment: AppEnvironment
    @ObservedObject private var presentation: ScreenStateStore<SettingsViewState>
    let onMapped: () -> Void
    @State private var channels: [TelegramChannel] = []
    @State private var skipped = 0
    @State private var checked = 0
    @State private var candidateCount = 0
    @State private var hasMore = true
    @State private var isLoading = false
    @State private var isMapping = false
    @State private var query = ""
    @State private var activeQuery = ""
    @State private var discovery: TelegramChannelDiscovery?
    @State private var errorMessage: String?
    @State private var retryChannelID: Int64?
    @State private var selection: TelegramChannelSelection?
    @State private var selectionContext: TelegramDiscoveryContext?
    @State private var activeTask: Task<Void, Never>?
    @State private var mappingTask: Task<Void, Never>?
    @State private var generation = UUID()
    @State private var isVisible = false
    @State private var showManualEntry = false
    @State private var manualChannelID = ""

    public init(environment: AppEnvironment, onMapped: @escaping () -> Void) {
        self.environment = environment; self.presentation = environment.settingsPresentation
        self.onMapped = onMapped
    }
    private var context: TelegramDiscoveryContext { environment.telegramDiscoveryContext }
    private var available: Bool {
        context.available && [.readyForChannel, .connected].contains(environment.settingsState.telegramAuthStep)
    }

    public var body: some View {
        List {
            if selection == nil && !isMapping {
                Section { NavigationLink("Channel mapping guide") { TelegramGuideView() } }
            }
            if let selection {
                Section {
                    FlowIntro(systemName: "checkmark.circle", title: "Use this channel?", message: "Private channel you own, with auto-delete off. Existing uploads are checked before it is enabled.")
                    LabeledContent("Account", value: selection.accountName).privacySensitive()
                    LabeledContent("Account ID", value: String(selection.accountID)).privacySensitive()
                    LabeledContent("Channel", value: selection.channel.title).privacySensitive()
                    LabeledContent("Channel ID", value: String(selection.channel.id)).privacySensitive()
                }
                Section {
                    Button("Use this channel", action: mapSelection).disabled(isMapping || !available)
                    Button("Choose another channel") { self.selection = nil; selectionContext = nil }
                        .disabled(isMapping)
                }
            }
            if isMapping {
                Section { WorkingBlock(title: "Checking this channel", message: "Existing uploads are compared before the destination is enabled.") }
            }
            if let errorMessage {
                Section("Connection issue") {
                    IssueBlock(message: errorMessage)
                    if selection == nil {
                        Button("Try again") {
                            if let retryChannelID { review(retryChannelID) } else { loadMore() }
                        }
                        .disabled(isLoading || !available)
                    }
                }
            }
            if selection == nil {
                Section {
                    if channels.isEmpty && !isLoading {
                        ContentUnavailableView("No eligible channel", systemImage: "number", description: Text(activeQuery.isEmpty ? "None of the checked chats is a private channel you own with auto-delete off." : "No match in the checked results. Try a more specific title or a channel ID."))
                            .listRowBackground(Color.clear)
                    }
                    ForEach(channels) { channel in
                        Button { review(channel.id) } label: {
                            HStack(spacing: 12) {
                                SymbolTile(systemName: "number")
                                Text(channel.title)
                                    .foregroundStyle(.primary)
                                    .privacySensitive()
                                Spacer()
                            }
                        }
                        .disabled(isLoading || !available)
                    }
                    if isLoading { ProgressView("Checking channels…") }
                    if hasMore {
                        Button("Check more results", action: loadMore).disabled(isLoading || !available)
                    }
                } header: {
                    Text(activeQuery.isEmpty ? "Recent chats" : "Search results")
                } footer: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("\(checked) of \(candidateCount) loaded candidates checked" + (skipped > 0 ? " · \(skipped) unavailable" : "")).monospacedDigit()
                        Text(activeQuery.isEmpty
                            ? "Recent discovery checks up to 50 main and 50 archived chats. Search by title, or enter a channel ID, for anything else."
                            : "Only private channels you own with auto-delete off are listed. Search results may be incomplete.")
                        if !available {
                            Text("Finish signing in before choosing a channel.")
                        }
                    }
                }
                Section {
                    DisclosureGroup("Use a channel ID", isExpanded: $showManualEntry) {
                        TextField("Numeric channel ID", text: $manualChannelID)
                            .keyboardType(.numbersAndPunctuation)
                        Button("Check channel") {
                            if let id = Int64(manualChannelID.trimmingCharacters(in: .whitespacesAndNewlines)) { review(id) }
                        }
                        .disabled(isLoading || !available || (Int64(manualChannelID.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0) == 0)
                    }
                } footer: {
                    Text("Use this when the channel is not in the recent list.")
                }
            }
        }
        .cloudifiedList()
        .searchable(text: $query, prompt: "Channel title")
        .onSubmit(of: .search) { restart() }
        .navigationTitle("Select channel")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(isMapping)
        .interactiveDismissDisabled(isMapping)
        .toolbar {
            if !activeQuery.isEmpty && selection == nil {
                ToolbarItem(placement: .primaryAction) {
                    Button("Recent") { query = ""; restart() }
                        .disabled(isLoading || !available)
                }
            }
        }
        .onAppear { isVisible = true; restart() }
        .onChange(of: context) { if !isMapping { restart() } }
        .onDisappear {
            isVisible = false; generation = UUID(); activeTask?.cancel(); activeTask = nil
            discovery = nil; isLoading = false; selection = nil; selectionContext = nil
            channels = []; manualChannelID = ""; query = ""; mappingTask?.cancel(); mappingTask = nil
        }
    }

    private func restart() {
        guard isVisible, !isMapping else { return }
        activeTask?.cancel(); generation = UUID(); discovery = nil
        channels = []; checked = 0; skipped = 0; candidateCount = 0; hasMore = true
        selection = nil; selectionContext = nil; errorMessage = nil; retryChannelID = nil; isLoading = false
        activeQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if available { loadMore() }
    }
    private func loadMore() {
        guard isVisible, available, !isLoading, !isMapping else { return }
        retryChannelID = nil
        runRead({ try await $0.discoverMore() }) { page in
            channels = page.channels; checked = page.checked; skipped = page.skipped
            candidateCount = page.candidateCount; hasMore = page.hasMore
        }
    }
    private func review(_ id: Int64) {
        guard available, !isMapping else { return }
        retryChannelID = id
        runRead({ try await $0.selection(chatID: id) }) { result in
            selection = result; selectionContext = context
        }
    }
    private func runRead<Result: Sendable>(
        _ operation: @escaping @Sendable (TelegramChannelDiscovery) async throws -> Result,
        apply: @escaping @MainActor (Result) -> Void
    ) {
        let previous = activeTask; previous?.cancel()
        let id = UUID(); generation = id
        let capturedContext = context
        isLoading = true; errorMessage = nil
        activeTask = Task {
            await previous?.value
            guard isCurrent(id, capturedContext) else { return }
            defer { if generation == id { isLoading = false; activeTask = nil } }
            do {
                if discovery == nil { discovery = try environment.createTelegramChannelDiscovery(query: activeQuery) }
                guard let discovery else { return }
                let result = try await operation(discovery)
                guard isCurrent(id, capturedContext) else { return }
                apply(result)
            } catch is CancellationError { }
            catch {
                guard isCurrent(id, capturedContext) else { return }
                let safe = ProviderSupport.safe(error, domain: .tdlib)
                if let discovery {
                    let page = await discovery.snapshot()
                    guard isCurrent(id, capturedContext) else { return }
                    channels = page.channels; checked = page.checked; skipped = page.skipped
                    candidateCount = page.candidateCount; hasMore = page.hasMore
                }
                errorMessage = FailureExplanation.message(safe)
                await environment.recordTelegramDiscoveryFailure(safe)
            }
        }
    }
    private func isCurrent(_ id: UUID, _ capturedContext: TelegramDiscoveryContext) -> Bool {
        !Task.isCancelled && isVisible && generation == id && context == capturedContext
    }
    private func mapSelection() {
        guard let selection, selectionContext == context, available, !isMapping else { return }
        let previous = activeTask; previous?.cancel()
        let capturedContext = context
        generation = UUID(); discovery = nil; isLoading = false
        isMapping = true; errorMessage = nil
        mappingTask = Task {
            defer { isMapping = false; mappingTask = nil }
            do {
                await previous?.value
                try Task.checkCancellation()
                guard isVisible, context == capturedContext else { throw CancellationError() }
                try await environment.mapTelegramChannel(chatID: selection.channel.id)
                try Task.checkCancellation()
                if isVisible { onMapped() }
            } catch is CancellationError {
                if !Task.isCancelled && isVisible && context != capturedContext {
                    self.selection = nil; selectionContext = nil
                    channels = []; checked = 0; skipped = 0; candidateCount = 0; hasMore = true
                    errorMessage = FailureExplanation.message(SafeFailure(.authentication, domain: .tdlib, cause: .accountChanged))
                }
            }
            catch {
                if isVisible {
                    errorMessage = FailureExplanation.message(ProviderSupport.safe(error, domain: .tdlib))
                    self.selection = nil; selectionContext = nil
                    channels = []; checked = 0; skipped = 0; candidateCount = 0; hasMore = true
                }
            }
        }
    }
}
