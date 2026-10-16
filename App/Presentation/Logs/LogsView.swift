import SwiftUI
#if os(iOS)
import UIKit
#endif

struct DiagnosticUploadSection: View {
    @ObservedObject var environment: AppEnvironment
    @State private var reportURL: URL?
    @State private var uploadingReport = false
    @State private var errorMessage: String?

    var body: some View {
        Section {
            FlowIntro(systemName: "doc.text", title: "Share a diagnostic report", message: "Create a public report link, then attach it to a GitHub issue. Credentials, media, account names and private paths are excluded.")
            Button {
                uploadingReport = true; errorMessage = nil
                Task {
                    defer { uploadingReport = false }
                    do {
                        let url = try await environment.uploadDiagnosticReport()
                        reportURL = url
                        #if os(iOS)
                        UIPasteboard.general.url = url
                        #endif
                    } catch is CancellationError { }
                    catch {
                        errorMessage = FailureExplanation.message(
                            ProviderSupport.safe(error, domain: .urlSession)
                        )
                    }
                }
            } label: {
                if uploadingReport {
                    ProgressView("Preparing report…")
                } else {
                    Label("Upload public diagnostics", systemImage: "arrow.up.doc")
                }
            }
            .disabled(uploadingReport)

            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.circle")
                    .foregroundStyle(.red).font(.footnote)
            }
            if let reportURL {
                Link("Open uploaded report", destination: reportURL)
                Button("Copy report link") {
                    #if os(iOS)
                    UIPasteboard.general.url = reportURL
                    #endif
                }
                ShareLink("Share report link", item: reportURL)
                Link("Create GitHub issue", destination: CloudifiedSupport.issueDraft(report: reportURL))
                NavigationLink("How to submit your report") { ReportingGuideView(reportURL: reportURL) }
                Text("The GitHub draft includes this link. Add what happened, review it, then submit on GitHub.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        } footer: {
            Text(reportURL == nil
                ? "Uploading creates a public report link. It does not submit a GitHub issue."
                : "The report is public. Its link is copied; review any details you add to GitHub before submitting.")
        }
    }
}

public struct LogsView: View {
    @ObservedObject public var environment: AppEnvironment
    @ObservedObject private var presentation: ScreenStateStore<LogsViewState>
    @State private var exportedFileURL: URL? = nil
    @State private var isExporting = false
    @State private var exportTask: Task<Void, Never>?
    @State private var exportErrorMessage: String? = nil

    public init(environment: AppEnvironment) {
        self.environment = environment; self.presentation = environment.logsPresentation
    }

    public var body: some View {
        List {

            if !environment.logsState.fallbackEntries.isEmpty {
                Section("Not saved to disk") {
                    Text("Held in memory and included in public reports.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    ForEach(environment.logsState.fallbackEntries) { entry in
                        NavigationLink { LogDetail(entry: entry) } label: { LogRow(entry: entry) }
                    }
                }
            }

            Section("Events") {
                if environment.logsState.filteredEntries.isEmpty {
                    if environment.logsState.isLoading {
                        ProgressView("Loading events…")
                    } else {
                        emptyStateView
                    }
                }
                ForEach(environment.logsState.filteredEntries) { entry in
                    NavigationLink { LogDetail(entry: entry) } label: { LogRow(entry: entry) }
                }
            }

            Section {
                if let error = environment.logsState.pageError {
                    Label(error, systemImage: "exclamationmark.circle")
                        .foregroundStyle(.red).font(.footnote)
                    Button("Retry") { environment.reloadLogs() }
                        .disabled(environment.logsState.isLoading)
                }
                if environment.logsState.isLoading && !environment.logsState.filteredEntries.isEmpty {
                    ProgressView("Loading more…")
                }
                if environment.logsState.hasNewer {
                    Button("Newer events") { environment.newerLogs() }.disabled(environment.logsState.isLoading)
                }
                if environment.logsState.hasOlder {
                    Button("Older events") { environment.olderLogs() }
                        .disabled(environment.logsState.isLoading)
                }
            } footer: {
                if environment.logsState.prunedEventCount > 0 {
                    Text("\(environment.logsState.prunedEventCount.formatted()) older diagnostic events pruned. Receipts and current failures remain in the backup ledger.")
                }
            }
        }
        .cloudifiedList()
        .onAppear {
            environment.visibleActivityPage = .logs
            if !environment.logsState.hasLoaded { environment.reloadLogs() }
            if environment.logsState.runs.isEmpty { environment.loadRuns() }
        }
        .onDisappear {
            if exportedFileURL == nil { exportTask?.cancel() }
        }
        .onChange(of: environment.logsState.originFilter) { environment.reloadLogs() }
        .onChange(of: environment.logsState.severityFilter) { environment.reloadLogs() }
        .onChange(of: environment.logsState.selectedRunID) { environment.reloadLogs() }
        .refreshable { environment.reloadLogs() }
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                Button {
                    environment.reloadLogs()
                    environment.loadRuns()
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                HStack(spacing: 0) {
                    Menu {
                        Picker("Run", selection: $environment.logsState.selectedRunID) {
                            Text("All runs").tag(nil as UUID?)
                            if let selected = environment.logsState.selectedRunID,
                               !environment.logsState.runs.contains(where: { $0.id == selected }) {
                                Text("Run \(selected.uuidString.prefix(8))").tag(Optional(selected))
                            }
                            ForEach(environment.logsState.runs) { run in
                                Text(run.title).tag(Optional(run.id))
                            }
                        }
                        if environment.logsState.hasOlderRuns {
                            Button("Load older runs") { environment.loadRuns(older: true) }
                        }
                        Divider()
                        Picker("Source", selection: $environment.logsState.originFilter) {
                            ForEach(LogOriginFilter.allCases) { f in
                                Text(f.rawValue).tag(f)
                            }
                        }
                        Divider()
                        Picker("Severity", selection: $environment.logsState.severityFilter) {
                            ForEach(LogSeverityFilter.allCases) { f in
                                Text(f.rawValue).tag(f)
                            }
                        }
                    } label: {
                        Label("Filter", systemImage: "line.3.horizontal.decrease.circle")
                    }

                    Button {
                        isExporting = true
                        exportTask = Task {
                            defer { isExporting = false }
                            do {
                                let url = try await environment.exportRedactedLogs()
                                exportedFileURL = url
                            } catch is CancellationError { }
                            catch {
                                exportErrorMessage = FailureExplanation.message(
                                    ProviderSupport.safe(error, domain: .fileSystem)
                                )
                            }
                        }
                    } label: {
                        if isExporting {
                            ProgressView()
                        } else {
                            Label("Export", systemImage: "square.and.arrow.up")
                        }
                    }
                    .disabled(isExporting)
                }
            }
        }
        #if os(iOS)
        .sheet(isPresented: Binding(
            get: { exportedFileURL != nil },
            set: { if !$0 { cleanupExportFile() } }
        ), onDismiss: { cleanupExportFile() }) {
            if let url = exportedFileURL {
                ShareSheet(activityItems: [url]) { cleanupExportFile() }
            }
        }
        #endif
        .alert("Diagnostics issue", isPresented: Binding(
            get: { exportErrorMessage != nil },
            set: { if !$0 { exportErrorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(exportErrorMessage ?? "Could not export diagnostic logs.")
        }
    }

    private func cleanupExportFile() {
        if let url = exportedFileURL {
            environment.releaseExport(url)
            exportedFileURL = nil
        }
    }

    private var emptyStateView: some View {
        ContentUnavailableView(
            "No matching events",
            systemImage: "doc.text.magnifyingglass",
            description: Text("Backup and connection events appear here. Adjust filters or export diagnostics.")
        )
        .listRowBackground(Color.clear)
    }
}

public struct LogRow: View {
    public let entry: DiagnosticLogEntry

    public var body: some View {
        HStack(alignment: .top, spacing: 12) {
            SymbolTile(systemName: entry.severity == "error" ? "exclamationmark.circle" : (entry.severity == "warning" ? "clock" : "text.alignleft"), color: severityColor)
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(entry.origin).font(.caption.weight(.semibold))
                    Spacer(minLength: 8)
                    Text(entry.timestamp.formatted(date: .omitted, time: .shortened)).font(.caption).monospacedDigit().foregroundStyle(.secondary)
                }
                Text(entry.message).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                Text(entry.severity.capitalized).font(.caption2).foregroundStyle(severityColor)
            }
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(entry.severity), \(entry.origin), \(entry.message), \(entry.timestamp.formatted())")
    }

    private var severityColor: Color {
        switch entry.severity.lowercased() {
        case "error": return .red
        case "warning": return .orange
        default: return .secondary
        }
    }
}

private struct LogDetail: View {
    let entry: DiagnosticLogEntry
    var body: some View {
        List {
            Section {
                Text(entry.message)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Section("Details") {
                LabeledContent("Time", value: entry.timestamp.formatted(date: .complete, time: .standard))
                LabeledContent("Source", value: entry.origin)
                LabeledContent("Severity", value: entry.severity)
                LabeledContent("Stage", value: entry.stage)
                if let attempt = entry.attemptNumber {
                    LabeledContent("Attempt", value: String(attempt))
                }
                if let code = entry.safeErrorCode {
                    LabeledContent("Safe code", value: code).textSelection(.enabled)
                }
            }
        }
        .cloudifiedList().navigationTitle("Event details")
        .navigationBarTitleDisplayMode(.inline)
    }
}

#if os(iOS)
struct ShareSheet: UIViewControllerRepresentable {
    let activityItems: [Any]
    let onDismiss: @MainActor @Sendable () -> Void

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
        controller.completionWithItemsHandler = { _, _, _, _ in
            Task { @MainActor in onDismiss() }
        }
        return controller
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
#endif
