import AppKit
import LLM
import SwiftUI

struct AccountSettingsView: View {
    let account: AccountModel
    @State private var confirmForget = false
    @State private var isJobRoutingExpanded = false

    var body: some View {
        Form {
            Section("ChatGPT") { accountSection }
            Section("Models") { modelsSection }
            Section { routingSection }
            Section("Advanced") {
                Button("Forget this Mac's registration…", role: .destructive) { confirmForget = true }
                    .disabled(account.isSigningIn)
                Text("Signs out and clears the registration Remora created for this Mac. The next sign-in registers it again.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear { Task { await account.refreshState() } }
        .confirmationDialog("Forget this Mac's registration?", isPresented: $confirmForget) {
            Button("Sign out and forget", role: .destructive) { account.forgetRegistration() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("You will be signed out. Continue with ChatGPT again to register this Mac.")
        }
    }

    // MARK: Account

    @ViewBuilder private var accountSection: some View {
        let p = account.presentation
        switch p.section {
        case .signedIn(let email):
            signedInRows(email: email)
        case .planUsageMissing(let email):
            if let email { LabeledContent("Account", value: email) }
            ChatGPTSignInSection(account: account)
            signOutRow
        case .needsSignIn:
            ChatGPTSignInSection(account: account)
            signOutRow
        case .unavailable, .signedOut:
            ChatGPTSignInSection(account: account)
        }
        if p.isSignedInWithPlanUsage, let error = account.lastError {
            Text(error).foregroundStyle(.orange).font(.callout)
        }
    }

    @ViewBuilder private func signedInRows(email: String?) -> some View {
        if let email { LabeledContent("Account", value: email) }
        Text("Using ChatGPT plan")
        HStack {
            Button("Manage usage") { NSWorkspace.shared.open(SIWC.usageSettingsURL) }
            signOutRow
        }
    }

    private var signOutRow: some View {
        Button("Sign out") { account.signOut() }.disabled(account.isSigningIn)
    }

    // MARK: Models

    @ViewBuilder private var modelsSection: some View {
        @Bindable var account = account
        LabeledContent("On-device") {
            Text(onDeviceText).foregroundStyle(.secondary)
        }
        Toggle("Use on-device model when available", isOn: $account.routing.onDeviceEnabled)
        modelPicker("Small", tier: .small)
        modelPicker("Large", tier: .large)
        ForEach([Tier.small, .large], id: \.self) { tier in
            if let note = account.resolved(tier)?.note {
                Text(note).font(.footnote).foregroundStyle(.orange)
            }
        }
    }

    private var onDeviceText: String {
        switch account.onDevice {
        case .available: "Available"
        case .unavailable(let reason): reason
        }
    }

    private func modelPicker(_ title: String, tier: Tier) -> some View {
        let selection = Binding<String?>(
            get: { account.routing.tierModels[tier] },
            set: { account.setModel($0, for: tier) })
        let automatic = account.automaticSlug(tier).map { "Automatic (\($0))" } ?? "Automatic"
        let stored = account.routing.tierModels[tier]
        return Picker(title, selection: selection) {
            Text(automatic).tag(String?.none)
            ForEach(account.catalog, id: \.slug) { Text($0.displayName).tag(String?.some($0.slug)) }
            if let stored, !account.catalog.contains(where: { $0.slug == stored }) {
                Text("\(stored) (unavailable)").tag(String?.some(stored))
            }
        }
    }

    // MARK: Job routing

    private var routingSection: some View {
        DisclosureGroup(isExpanded: $isJobRoutingExpanded) {
            ForEach(JobType.allCases.filter { $0 != .meetingNotes }, id: \.self) { job in
                Picker(job.title, selection: Binding(
                    get: { account.routing.tier(for: job) },
                    set: { account.setTier($0, for: job) })) {
                    ForEach(Tier.allCases, id: \.self) { Text($0.title).tag($0) }
                }
            }
            Button("Reset to defaults") { account.resetJobRouting() }
                .disabled(account.routing.jobTiers.isEmpty)
        } label: {
            Text("Job routing")
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture { withAnimation { isJobRoutingExpanded.toggle() } }
        }
    }
}
