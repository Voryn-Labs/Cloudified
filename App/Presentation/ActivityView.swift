import SwiftUI

public struct ActivityOverviewState: Equatable {
    public struct Destination: Identifiable, Equatable {
        public let id: String
        public let name: String
        public let saved: Int?
        public let total: Int?
        public let waiting: Int?
        public let failed: Int?
        public let enabled: Bool
    }
    public var destinations: [Destination] = []
}

struct ActivityView: View {
    @ObservedObject var environment: AppEnvironment
    @ObservedObject private var presentation: ScreenStateStore<ActivityOverviewState>
    @State private var path: [ActivityPage] = []
    init(environment: AppEnvironment) { self.environment = environment; presentation = environment.activityPresentation }
    private var waiting: Int { presentation.value.destinations.compactMap(\.waiting).reduce(0, +) }
    private var failed: Int { presentation.value.destinations.compactMap(\.failed).reduce(0, +) }

    var body: some View {
        NavigationStack(path: $path) {
            List {
                Section {
                    NavigationLink(value: ActivityPage.issues) {
                        MenuRow(title: "Issues", symbol: "exclamationmark.bubble", subtitle: issueSummary,
                            color: failed > 0 || waiting > 0 ? .orange : .accentColor)
                    }
                    NavigationLink(value: ActivityPage.logs) {
                        MenuRow(title: "Diagnostic logs", symbol: "doc.text.magnifyingglass", subtitle: "Read what happened, by destination")
                    }
                }
                if !presentation.value.destinations.isEmpty { destinationSection }
                Section {
                    NavigationLink { FeedbackView(environment: environment) } label: {
                        MenuRow(title: "Report a problem", symbol: "bubble.left.and.text.bubble.right", subtitle: "Upload diagnostics and open a GitHub issue")
                    }
                    NavigationLink { HelpView(environment: environment) } label: {
                        MenuRow(title: "Help & guides", symbol: "questionmark", subtitle: "Linking, waiting files and backup basics")
                    }
                } header: { Text("Support") } footer: { BrandSignature().padding(.top, 12) }
            }
            .cloudifiedList().navigationTitle("Activity").navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: ActivityPage.self) { page in
                switch page {
                case .issues: NotUploadedView(environment: environment).navigationTitle("Issues").navigationBarTitleDisplayMode(.inline)
                case .logs: LogsView(environment: environment).navigationTitle("Diagnostic logs").navigationBarTitleDisplayMode(.inline)
                case .overview: EmptyView()
                }
            }
        }
        .onAppear { route(environment.visibleActivityPage) }
        .onChange(of: environment.visibleActivityPage) { _, page in route(page) }
        .onChange(of: path) { _, path in
            let page = path.last ?? .overview
            if environment.visibleActivityPage != page { environment.visibleActivityPage = page }
        }
    }
    private var destinationSection: some View {
        Section("Destination status") {
            ForEach(presentation.value.destinations) { destination in destinationRow(destination) }
        }
    }
    private func destinationRow(_ destination: ActivityOverviewState.Destination) -> some View {
        HStack(spacing: 12) {
            SymbolTile(systemName: destination.id == "google" ? "photo.stack.fill" : "paperplane.fill")
            VStack(alignment: .leading, spacing: 4) {
                Text(destination.name).font(.subheadline.weight(.semibold))
                Text(counts(destination)).font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }.frame(maxWidth: .infinity, alignment: .leading)
            status(destination)
        }.padding(.vertical, 6)
    }
    private var issueSummary: String {
        if failed > 0 || waiting > 0 { return "\(failed.formatted()) failed · \(waiting.formatted()) waiting — tap to identify files" }
        return "Find a file, understand the reason, take action"
    }
    private func counts(_ destination: ActivityOverviewState.Destination) -> String {
        guard let saved = destination.saved, let total = destination.total else { return "Counts available after scanning" }
        return "\(saved.formatted()) of \(total.formatted()) saved"
    }
    @ViewBuilder private func status(_ destination: ActivityOverviewState.Destination) -> some View {
        if !destination.enabled { StatusPill(title: "Off", symbol: "pause") }
        else if let failed = destination.failed, failed > 0 { StatusPill(title: "\(failed) failed", symbol: "exclamationmark", color: .red) }
        else if let waiting = destination.waiting, waiting > 0 { StatusPill(title: "\(waiting) waiting", symbol: "clock", color: .orange) }
        else if let total = destination.total, let saved = destination.saved, saved == total {
            StatusPill(title: "Saved", symbol: "checkmark", color: .accentColor)
        } else { StatusPill(title: "Pending", symbol: "ellipsis", color: .secondary) }
    }
    private func route(_ page: ActivityPage) {
        let target: [ActivityPage] = page == .overview ? [] : [page]
        if path != target { path = target }
    }
}
