import SwiftUI

public struct RootTabView: View {
    @ObservedObject public var environment: AppEnvironment

    public init(environment: AppEnvironment) {
        self.environment = environment
    }

    @AppStorage("CloudifiedAppearance") private var appearance = AppAppearance.system

    private var failureCount: Int? { environment.activityFailureCount }

    public var body: some View {
        TabView(selection: $environment.selectedTab) {
            DashboardView(environment: environment)
                .tabItem {
                    Label("Backup", systemImage: "cloud")
                }
                .tag(AppTab.dashboard)

            activityView
                .tabItem {
                    Label("Activity", systemImage: "waveform.path")
                }
                .countedBadge(failureCount)
                .tag(AppTab.activity)

            SettingsView(environment: environment)
                .tabItem {
                    Label("Settings", systemImage: "slider.horizontal.3")
                }
                .tag(AppTab.settings)
        }
        .preferredColorScheme(appearance.colorScheme)
    }

    private var activityView: some View { ActivityView(environment: environment) }
}
