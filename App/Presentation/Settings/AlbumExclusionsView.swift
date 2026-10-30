import SwiftUI
import CloudifiedCore

struct AlbumExclusionsView: View {
    @ObservedObject var environment: AppEnvironment
    @ObservedObject private var presentation: ScreenStateStore<SettingsViewState>
    @State private var albums: [BackupAlbum] = []
    @State private var google: Set<String> = []
    @State private var telegram: Set<String> = []
    @State private var search = ""
    @State private var loading = true
    @State private var saving = false
    @State private var message: String?
    @State private var originalGoogle: Set<String> = []
    @State private var originalTelegram: Set<String> = []

    init(environment: AppEnvironment) {
        self.environment = environment; presentation = environment.settingsPresentation
    }
    private var canEdit: Bool { presentation.value.controlsAvailable && !environment.backupRequested && !saving && !loading }
    private var changed: Bool { google != originalGoogle || telegram != originalTelegram }
    private var visibleAlbums: [BackupAlbum] {
        albums.filter { search.isEmpty || $0.title.localizedStandardContains(search) }
    }
    var body: some View {
        List {
            Section {
                Text("Choose albums to leave out of each destination. A photo or video in any excluded album is skipped, even if it also belongs to an included album.")
                    .font(.subheadline).foregroundStyle(.secondary)
                if environment.backupRequested {
                    Button("Pause backup to edit", systemImage: "pause.circle", action: environment.requestPause)
                        .disabled(saving || !presentation.value.controlsAvailable)
                }
            } footer: {
                Text("Already uploaded files stay in the cloud. Submitted transfers may finish. Removing an exclusion makes files eligible again without resetting their saved receipts.")
            }
            if loading { Section { ProgressView("Loading albums…") } }
            if let message { Section { Text(message).foregroundStyle(.secondary) } }
            Section {
                ForEach(visibleAlbums) { album in
                    DisclosureGroup {
                        Toggle("Exclude from Google Photos", isOn: binding(album.id, provider: .google))
                        Toggle("Exclude from Telegram", isOn: binding(album.id, provider: .telegram))
                    } label: {
                        Label {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(album.title)
                                Text(summary(album.id)).font(.caption).foregroundStyle(.secondary)
                            }
                        } icon: { Image(systemName: "rectangle.stack") }
                    }.disabled(!canEdit)
                }
                if !loading && visibleAlbums.isEmpty { Text(search.isEmpty ? "No regular albums available" : "No matching albums").foregroundStyle(.secondary) }
            } header: { Text("Albums") } footer: {
                Text("Regular albums only. With limited Photos access, only visible media can be checked. An unavailable excluded album pauses new uploads to that destination until it is accessible or you remove the rule. Excluded totals refresh when backup scans; album membership is checked again before new uploads.")
            }
        }
        .cloudifiedList().navigationTitle("Excluded albums")
        .searchable(text: $search, prompt: "Find an album")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(saving ? "Saving…" : "Save") { Task { await save() } }
                    .disabled(!canEdit || !changed)
            }
        }
        .task { await load() }
    }
    private func binding(_ id: String, provider: Provider) -> Binding<Bool> {
        Binding(get: { (provider == .google ? google : telegram).contains(id) }, set: { value in
            if provider == .google { if value { google.insert(id) } else { google.remove(id) } }
            else { if value { telegram.insert(id) } else { telegram.remove(id) } }
        })
    }
    private func summary(_ id: String) -> String {
        switch (google.contains(id), telegram.contains(id)) {
        case (true, true): return "Excluded from both"
        case (true, false): return "Excluded from Google Photos"
        case (false, true): return "Excluded from Telegram"
        default: return "Included"
        }
    }
    private func load() async {
        guard let ledger = environment.ledger else { loading = false; message = "Backup storage is unavailable."; return }
        do {
            google = Set(try await ledger.albumExclusionRules(.google).albumIDs)
            telegram = Set(try await ledger.albumExclusionRules(.telegram).albumIDs)
            originalGoogle = google; originalTelegram = telegram
            let loaded = await Task.detached(priority: .utility) { AlbumExclusionPolicy.albums() }.value
            try Task.checkCancellation()
            let known = Set(loaded.map(\.id))
            albums = loaded + google.union(telegram).subtracting(known).sorted().map { BackupAlbum(id: $0, title: "Unavailable album") }
        } catch { message = environment.explain(ProviderSupport.safe(error, domain: .photos)) }
        loading = false
    }
    private func save() async {
        saving = true; defer { saving = false }
        do {
            try await environment.saveAlbumExclusions(google: google, telegram: telegram)
            originalGoogle = google; originalTelegram = telegram
            message = "Exclusions saved. If an album is unavailable, restore access or remove its exclusion before continuing that destination."
        } catch { message = environment.explain(ProviderSupport.safe(error, domain: .photos)) }
    }
}
