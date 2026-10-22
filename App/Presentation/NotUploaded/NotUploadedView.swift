import SwiftUI
import Photos
import UIKit
import CloudifiedCore

public struct NotUploadedView: View {
    @ObservedObject public var environment: AppEnvironment
    @ObservedObject private var presentation: ScreenStateStore<NotUploadedViewState>
    @State private var selectedItemForDetails: NotUploadedItem?

    public init(environment: AppEnvironment) {
        self.environment = environment; self.presentation = environment.issuesPresentation
    }

    private var state: NotUploadedViewState { environment.notUploadedState }

    public var body: some View {
        List {
            if state.isLoading && state.filteredItems.isEmpty {
                Section { WorkingBlock(title: "Loading issues", message: "Reading saved failures and waits from this library scan.") }
            }
            Section {
                if state.filteredItems.isEmpty && !state.isLoading && state.pageError == nil {
                    ContentUnavailableView("Nothing in this view", systemImage: "tray", description: Text("Failed, waiting, and pending items show up here. Change the filter if a status is hidden."))
                        .listRowBackground(Color.clear)
                } else {
                    ForEach(state.filteredItems) { item in
                        NotUploadedRow(item: item) { selectedItemForDetails = item }
                    }
                }
            } header: {
                filterHeader
            } footer: {
                Text("Select a file to see what happened and what you can do. Each destination is tracked separately.")
            }
            if state.pageError != nil || state.hasOlder || state.hasNewer || (!state.filteredItems.isEmpty && state.isLoading) {
                Section {
                    if let error = state.pageError {
                        IssueBlock(message: error)
                        Button("Try again") { environment.reloadFailures() }
                            .disabled(state.isLoading)
                    }
                    if state.isLoading && !state.filteredItems.isEmpty {
                        ProgressView("Loading more…")
                    }
                    if state.hasNewer {
                        Button("Newer items") { environment.newerFailures() }.disabled(state.isLoading)
                    }
                    if state.hasOlder {
                        Button("Load older items") { environment.olderFailures() }
                            .disabled(state.isLoading)
                    }
                }
            }
        }
        .cloudifiedList()
        .onAppear {
            environment.visibleActivityPage = .issues
            if !environment.notUploadedState.hasLoaded { environment.reloadFailures() }
        }
        .onChange(of: state.destinationFilter) { environment.reloadFailures() }
        .onChange(of: state.mediaTypeFilter) { environment.reloadFailures() }
        .onChange(of: state.statusFilter) { environment.reloadFailures() }
        .refreshable { environment.reloadFailures() }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Picker("Destination", selection: $environment.notUploadedState.destinationFilter) {
                        ForEach(DestinationFilter.allCases) { Text($0.rawValue).tag($0) }
                    }
                    Picker("Media", selection: $environment.notUploadedState.mediaTypeFilter) {
                        ForEach(MediaTypeFilter.allCases) { Text($0.rawValue).tag($0) }
                    }
                    Picker("Status", selection: $environment.notUploadedState.statusFilter) {
                        ForEach(FailureStatusFilter.allCases) { Text($0.rawValue).tag($0) }
                    }
                } label: {
                    Label("Filter", systemImage: "line.3.horizontal.decrease.circle")
                }
            }
        }
        .sheet(item: $selectedItemForDetails) { item in
            NotUploadedDetailSheet(item: item, environment: environment)
        }
    }

    private var filterHeader: some View {
        HStack(spacing: 6) {
            Text("Problem files")
            Spacer(minLength: 8)
            if state.destinationFilter != .all { FilterCapsule(title: state.destinationFilter.rawValue) }
            if state.mediaTypeFilter != .all { FilterCapsule(title: state.mediaTypeFilter.rawValue) }
            if state.statusFilter != .all { FilterCapsule(title: state.statusFilter.rawValue) }
        }
        .textCase(nil)
    }
}

public struct NotUploadedRow: View {
    public let item: NotUploadedItem
    public let onTap: () -> Void

    public var body: some View {
        Button(action: onTap) {
            HStack(alignment: .center, spacing: 12) {
                NotUploadedThumbnailView(localIdentifier: item.localIdentifier, mediaType: item.mediaType)
                    .privacySensitive()
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.filename)
                        .font(.body.weight(.medium))
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .privacySensitive()
                    Text("\(item.provider) · \(item.mediaType)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let date = item.captureDate {
                        Text(date.formatted(date: .abbreviated, time: .shortened))
                            .font(.caption2).foregroundStyle(.secondary).privacySensitive()
                    }
                    Text(item.plainLanguageReason)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                    statusBadge
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.vertical, 4)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityHint("Opens reason, remedy and attempt history")
    }

    private var statusBadge: some View {
        StatusPill(title: item.statusTitle, symbol: item.needsRecovery ? "checkmark.magnifyingglass" : "exclamationmark.circle",
            color: item.statusTitle == "Failed" ? .red : .orange)
    }
}

struct NotUploadedThumbnailView: View {
    let localIdentifier: String
    let mediaType: String
    @StateObject private var loader = RowThumbnailLoader()

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(.quaternary)
                .frame(width: 48, height: 48)

            if let img = loader.image {
                #if canImport(UIKit)
                Image(uiImage: img)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 48, height: 48)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                #elseif canImport(AppKit)
                Image(nsImage: img)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 48, height: 48)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                #endif
            } else {
                Image(systemName: mediaType.localizedCaseInsensitiveContains("Video") ? "video" : "photo")
                    .foregroundColor(.secondary)
                    .font(.caption)
            }
        }
        .onAppear { loader.load(localIdentifier: localIdentifier) }
        .onChange(of: localIdentifier) { loader.load(localIdentifier: localIdentifier) }
        .onDisappear { loader.cancel() }
    }
}

public struct NotUploadedDetailSheet: View {
    public let item: NotUploadedItem
    @ObservedObject var environment: AppEnvironment
    @ObservedObject private var presentation: ScreenStateStore<SettingsViewState>
    @State private var confirmOriginalUpload = false
    @State private var history: [AttemptHistoryRow] = []
    @State private var historyError: String?
    @State private var historyHasOlder = false
    @State private var historyTask: Task<Void, Never>?
    @State private var historyGeneration = UUID()
    @State private var historyLoading = false
    @State private var historyExpanded = false
    @Environment(\.dismiss) private var dismiss

    public init(item: NotUploadedItem, environment: AppEnvironment) {
        self.item = item
        self.environment = environment
        self.presentation = environment.settingsPresentation
    }

    public var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack(alignment: .center, spacing: 12) {
                        NotUploadedThumbnailView(localIdentifier: item.localIdentifier, mediaType: item.mediaType)
                            .privacySensitive()
                        VStack(alignment: .leading, spacing: 4) {
                            Text(item.filename)
                                .font(.headline)
                                .lineLimit(2)
                                .privacySensitive()
                            Text("\(item.provider) · \(item.mediaType)")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                Section {
                    IssueBlock(message: item.plainLanguageReason)
                    if let remedy = item.suggestedRemedy { Text(remedy).font(.subheadline).foregroundStyle(.secondary) }
                    if let date = item.nextRetryDate {
                        LabeledContent("Next retry", value: date.formatted(.relative(presentation: .named)))
                    }
                    if item.technicalCode?.hasSuffix("/possibleOriginalMatch") == true, item.canRetry {
                        Button("Upload original anyway", systemImage: "arrow.up.doc") { confirmOriginalUpload = true }
                            .disabled(!presentation.value.controlsAvailable)
                            .confirmationDialog("Upload this original?", isPresented: $confirmOriginalUpload, titleVisibility: .visible) {
                                Button("Upload original anyway") { environment.retryItem(item, allowExistingOriginal: true) }
                                Button("Cancel", role: .cancel) {}
                            } message: {
                                Text("Google may already have this original. Continuing can create another copy. Only this file's candidate warning is overridden; upload recovery checks still apply.")
                            }
                    }
                    if item.canRetry || item.needsRecovery {
                        Button {
                            if item.needsRecovery { environment.recoverItem(item) }
                            else { environment.retryItem(item) }
                        } label: { Label(item.needsRecovery ? "Verify upload" : "Retry this file", systemImage: item.needsRecovery ? "checkmark.magnifyingglass" : "arrow.clockwise") }
                        .disabled(!presentation.value.controlsAvailable)
                    }
                } header: { Text("What happened") } footer: {
                    Text(item.needsRecovery
                        ? "This file is not counted as saved. Verification can remain unresolved; Cloudified will not guess or send another copy. Other eligible files can continue."
                        : "Other ready files run before automatic retries. Retryable errors get up to three total automatic attempts. Some errors need action immediately. A manual retry starts a new cycle for this destination.")
                }

                Section {
                    labelRow("Filename", value: item.filename).privacySensitive()
                    labelRow("Type", value: "\(item.mediaType) · \(item.provider)")
                    if let date = item.captureDate {
                        labelRow("Captured", value: date.formatted(date: .abbreviated, time: .shortened))
                    }
                    labelRow("Attempts", value: item.attemptText)
                    if let duration = item.durationSeconds, duration > 0 {
                        labelRow("Duration", value: Duration.seconds(duration).formatted(.time(pattern: .minuteSecond)))
                    }
                    Button("Copy file details", systemImage: "doc.on.doc") { UIPasteboard.general.string = item.identificationText }
                } header: { Text("Find this file") } footer: {
                    Text("Find the original in Photos using the capture date and thumbnail. Open its Info panel to compare the filename. Copy details only where you intend to share them; they can identify personal media.")
                }

                if !item.confirmedComponents.isEmpty || !item.missingObligations.isEmpty {
                    Section("Resource components") {
                        if !item.confirmedComponents.isEmpty {
                            labelRow("Confirmed", value: item.confirmedComponents.joined(separator: ", "))
                        }
                        if !item.missingObligations.isEmpty {
                            labelRow("Missing", value: item.missingObligations.joined(separator: ", "))
                                .foregroundStyle(.red)
                        }
                    }
                }

                Section {
                    DisclosureGroup("Attempt history", isExpanded: $historyExpanded) {
                    if historyLoading { ProgressView("Loading attempts…") }
                    if history.isEmpty && !historyLoading && historyError == nil {
                        Text("No attempts recorded.").foregroundStyle(.secondary)
                    }
                    ForEach(history, id: \.cursor) { row in
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Attempt \(row.number) · \(row.startedAt.formatted(.relative(presentation: .named)))")
                                .font(.footnote.weight(.medium))
                            Text(row.failure.map(environment.explain) ?? (row.endedAt == nil ? "No outcome recorded" : "Completed"))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 2)
                    }
                    if let historyError {
                        Label(historyError, systemImage: "exclamationmark.circle")
                            .foregroundStyle(.red).font(.footnote)
                    }
                    if historyHasOlder {
                        Button("Older attempts") { loadHistory(before: history.last?.cursor) }
                            .disabled(historyLoading)
                    }
                    Button("Newest attempts") { loadHistory() }.disabled(historyLoading)
                    }
                }

                Section {
                    DisclosureGroup("Technical details") {
                    labelRow("Stage", value: item.stage)
                    labelRow("Category", value: item.errorCategory)
                    if let code = item.technicalCode {
                        labelRow("Code", value: code).textSelection(.enabled)
                    }
                    }
                    NavigationLink { FeedbackView(environment: environment) } label: {
                        MenuRow(title: "Get help with this issue", symbol: "bubble.left.and.text.bubble.right")
                    }
                }
            }
            .cloudifiedList()
            .onChange(of: historyExpanded) { _, expanded in if expanded && history.isEmpty { loadHistory() } }
            .onDisappear { historyGeneration = UUID(); historyTask?.cancel() }
            .navigationTitle("Upload issue")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func loadHistory(before: Int64? = nil) {
        historyTask?.cancel()
        let generation = UUID()
        historyGeneration = generation
        historyLoading = true
        historyError = nil
        historyTask = Task {
            defer {
                if historyGeneration == generation {
                    historyLoading = false
                    historyTask = nil
                }
            }
            do {
                let page = try await environment.attemptHistory(item, before: before)
                try Task.checkCancellation()
                guard historyGeneration == generation else { return }
                history = page
                historyHasOlder = page.count == 25
            } catch is CancellationError { }
            catch {
                guard !Task.isCancelled, historyGeneration == generation else { return }
                historyError = FailureExplanation.message(ProviderSupport.safe(error, domain: .sqlite))
            }
        }
    }

    private func labelRow(_ label: String, value: String) -> some View {
        LabeledContent(label) {
            Text(value)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
    }
}
