import SwiftUI

public struct RootTabView: View {
    @ObservedObject public var environment: AppEnvironment

    public init(environment: AppEnvironment) {
        self.environment = environment
    }

    @AppStorage("CloudifiedAppearance") private var appearance = AppAppearance.system
    @AppStorage("CloudifiedWalkthroughCompleted") private var walkthroughCompleted = false

    private var failureCount: Int? { environment.activityFailureCount }

    public var body: some View {
        Group {
            if walkthroughCompleted { tabs }
            else {
                WalkthroughView { openSetup in
                    walkthroughCompleted = true
                    if openSetup { environment.selectedTab = .settings }
                }
            }
        }
        .preferredColorScheme(appearance.colorScheme)
    }

    private var tabs: some View {
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
    }

    private var activityView: some View { ActivityView(environment: environment) }
}
