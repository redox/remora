import SwiftUI

extension SettingsTab: CaseIterable {
    /// The sidebar order (pinned in Plan 5 Task 12; `FeatureGuide`'s "settings" list follows it).
    static let allCases: [SettingsTab] = [
        .general, .account, .usage, .privacy, .appearance, .identity, .memory, .notifications, .shortcuts,
        .dictation, .meetingSources, .mcp, .logs,
    ]

    var title: String {
        switch self {
        case .general: "General"
        case .account: "Account"
        case .usage: "Usage"
        case .privacy: "Privacy"
        case .appearance: "Appearance"
        case .identity: "Identity"
        case .memory: "Memory"
        case .notifications: "Notifications"
        case .shortcuts: "Shortcuts"
        case .dictation: "Dictation"
        case .mcp: "MCP"
        case .meetingSources: "Meeting sources"
        case .logs: "Logs"
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .account: "person.crop.circle"
        case .usage: "chart.bar"
        case .privacy: "hand.raised"
        case .appearance: "paintbrush"
        case .identity: "person.text.rectangle"
        case .memory: "brain"
        case .notifications: "bell"
        case .shortcuts: "keyboard"
        case .dictation: "mic"
        case .mcp: "point.3.connected.trianglepath.dotted"
        case .meetingSources: "person.2.wave.2"
        case .logs: "doc.text.magnifyingglass"
        }
    }
}

struct SettingsView: View {
    @Bindable var env: AppEnvironment

    var body: some View {
        NavigationSplitView {
            List(SettingsTab.allCases, id: \.self, selection: Binding(
                get: { env.settingsTab }, set: { if let tab = $0 { env.settingsTab = tab } })) { tab in
                Label(tab.title, systemImage: tab.symbol).tag(tab)
            }
            .navigationSplitViewColumnWidth(180)
            .toolbar(removing: .sidebarToggle)
        } detail: {
            page(env.settingsTab)
                .navigationTitle(env.settingsTab.title)
        }
        .frame(width: 760, height: 600)
        .sheet(isPresented: Binding(get: { env.account.showWelcome }, set: { env.account.showWelcome = $0 })) {
            PlanWelcomeSheet { env.account.showWelcome = false }
        }
    }

    @ViewBuilder private func page(_ tab: SettingsTab) -> some View {
        switch tab {
        case .general: GeneralSettingsView(env: env)
        case .account: AccountSettingsView(account: env.account)
        case .usage: UsageSettingsView(env: env)
        case .privacy: PrivacySettingsView(env: env)
        case .appearance: AppearanceSettingsView(env: env)
        case .identity: IdentitySettingsView(env: env)
        case .memory: MemorySettingsView(env: env)
        case .notifications: NotificationsSettingsView(env: env)
        case .shortcuts:
            ShortcutsSettingsView(rewrite: env.rewrite, openDictationSettings: { env.settingsTab = .dictation })
        case .dictation: DictationSettingsView(env: env)
        case .mcp: MCPSettingsView()
        case .meetingSources: MeetingSourcesView(env: env)
        case .logs: LogsSettingsView()
        }
    }
}
