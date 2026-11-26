import AppKit
import Capture
import Dictation
import Storage
import SwiftUI

struct PrivacySettingsView: View {
    let env: AppEnvironment

    @State private var exclusions: [ExclusionStore.Entry] = []
    @State private var newPattern = ""
    @State private var patternError: String?
    @State private var listError: String?
    @State private var showDelete = false
    @State private var deleteMessage: String?

    private var store: ExclusionStore { ExclusionStore(env.db) }

    var body: some View {
        Form {
            accessibilitySection
            microphoneSection
            pauseSection
            ignoreSection
            builtInSection
            deleteSection
        }
        .formStyle(.grouped)
        .onAppear { reload(); env.permissions.poll() }
        .sheet(isPresented: $showDelete) {
            DeleteAllSheet(env: env) { message in deleteMessage = message }
        }
    }

    // MARK: Sections

    private var accessibilitySection: some View {
        Section("Accessibility") {
            LabeledContent("Status") {
                Text(env.permissions.accessibilityGranted ? "Granted" : "Not granted")
                    .foregroundStyle(env.permissions.accessibilityGranted ? .green : .orange)
            }
            HStack {
                Button("Re-grant") { env.permissions.requestAccessibility() }
                Button("Open System Settings") { env.permissions.openAccessibilitySettings() }
            }
        }
    }

    private var microphoneSection: some View {
        Section {
            LabeledContent("Status") {
                switch env.permissions.microphone {
                case .granted: Text("Granted").foregroundStyle(.green)
                case .notDetermined: Text("Not asked yet").foregroundStyle(.secondary)
                case .denied, .restricted: Text("Not granted").foregroundStyle(.orange)
                }
            }
            HStack {
                Button("Re-grant") {
                    if env.permissions.microphone == .notDetermined {
                        Task { await env.permissions.requestMicrophone() }
                    } else {
                        env.permissions.openMicrophoneSettings()
                    }
                }
                Button("Open System Settings") { env.permissions.openMicrophoneSettings() }
            }
        } header: {
            Text("Microphone")
        } footer: {
            Text("Used for voice dictation and meeting recording.")
        }
    }

    private var pauseSection: some View {
        Section("Capture") {
            LabeledContent("Status", value: env.statusText)
            HStack {
                Menu("Pause") {
                    ForEach(PauseDuration.allCases, id: \.self) { d in
                        Button(d.title) { env.pause(for: d) }
                    }
                }
                .fixedSize()
                .disabled(env.isDeletingAll)
                if env.isPaused { Button("Resume") { env.resume() }.disabled(env.isDeletingAll) }
            }
            if let error = env.lastError { Text(error).font(.footnote).foregroundStyle(.red) }
        }
    }

    private var ignoreSection: some View {
        Section {
            if exclusions.isEmpty {
                Text("Nothing ignored yet.").foregroundStyle(.secondary)
            }
            ForEach(exclusions, id: \.pattern) { entry in
                HStack {
                    Text(entry.pattern)
                    Spacer()
                    if ExclusionRule(pattern: entry.pattern)?.supportsManualSaves == true {
                        Picker("Permission for \(entry.pattern)", selection: Binding(
                            get: { entry.manualSaves },
                            set: { setManualSaves($0, for: entry.pattern) })) {
                            Text("Fully ignored").tag(false)
                            Text("Manual saves only").tag(true)
                        }
                        .labelsHidden()
                        .fixedSize()
                    }
                    Button("Remove", systemImage: "minus.circle") { remove(entry.pattern) }
                        .labelStyle(.iconOnly).buttonStyle(.borderless)
                }
            }
            HStack {
                TextField("Pattern", text: $newPattern,
                          prompt: Text("example.com, app:Notes, title:…, url:…, path:…"))
                    .onSubmit(add)
                    .onChange(of: newPattern) { patternError = nil }
                Button("Add", action: add)
                    .disabled(newPattern.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            if let patternError { Text(patternError).font(.footnote).foregroundStyle(.red) }
            Menu("Add app…") {
                ForEach(Self.runningAppNames(), id: \.self) { name in
                    Button(name) { addPattern("app:\(name)") }
                }
            }
            .fixedSize()
            if let listError { Text(listError).font(.footnote).foregroundStyle(.red) }
        } header: {
            Text("Ignore list")
        } footer: {
            Text("The ignore list blocks background capture and earlier captures. Manual saves only lets you explicitly save a selection from an ignored app or site. A bare domain also matches its subdomains. Existing summaries and saved notes stay until you delete them.")
        }
    }

    private var builtInSection: some View {
        Section {
            ForEach(BuiltInSkipList.bundleIDs.sorted(), id: \.self) { id in
                Text(Self.displayName(forBundleID: id))
            }
            ForEach(BuiltInSkipList.domains, id: \.self) { Text($0 == "bank" ? "Any .bank site" : $0) }
        } header: {
            Text("Always skipped (built in)")
        } footer: {
            Text("Password managers and banking sites are never captured. This list cannot be changed.")
        }
    }

    private var deleteSection: some View {
        Section {
            Button("Delete all data…", role: .destructive) { showDelete = true }
            if let deleteMessage { Text(deleteMessage).font(.footnote).foregroundStyle(.secondary) }
        } header: {
            Text("Data")
        } footer: {
            Text(Self.backupNote)
        }
    }

    /// The database is deliberately NOT excluded from Time Machine (user decision).
    static let backupNote = "Remora's memory is included in Time Machine backups. Deleting here doesn't remove copies already in your backups."

    // MARK: Actions

    private func reload() {
        do { exclusions = try store.entries(); listError = nil } catch {
            listError = "Could not read the ignore list."
        }
    }

    private func add() { addPattern(newPattern) }

    private func addPattern(_ raw: String) {
        // Validate with the capture rules so a stored pattern is always one that can match.
        guard let rule = ExclusionRule(pattern: raw) else {
            patternError = "Not a valid pattern. Use a domain (example.com) or app:, title:, url:, path: followed by a value."
            return
        }
        do {
            try store.add(rule.pattern)
            newPattern = ""
            patternError = nil
            env.applyActionChange(.exclusions)
        } catch {
            patternError = "Could not save the pattern."
        }
        reload()
    }

    private func remove(_ pattern: String) {
        do {
            try store.remove(pattern)
            env.applyActionChange(.exclusions)
        } catch { listError = "Could not remove the pattern." }
        reload()
    }

    private func setManualSaves(_ enabled: Bool, for pattern: String) {
        do {
            try store.setManualSaves(enabled, for: pattern)
            reload()
        } catch {
            listError = "Could not change the save permission."
        }
    }

    // MARK: Helpers

    private static func runningAppNames() -> [String] {
        let names = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.bundleIdentifier != Bundle.main.bundleIdentifier }
            .compactMap { $0.localizedName.map(AppName.normalize) }
            .filter { !$0.isEmpty }
        return Array(Set(names)).sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    private static func displayName(forBundleID id: String) -> String {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else { return id }
        return AppName.normalize(FileManager.default.displayName(atPath: url.path)
            .replacingOccurrences(of: ".app", with: ""))
    }
}

private struct DeleteAllSheet: View {
    let env: AppEnvironment
    let onFinished: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var confirmation = ""
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Delete all data?").font(.headline)
            Text("This permanently deletes captures, activity, memory, saved notes, chat history, recorded meetings and imported meetings. It also disconnects meeting sources. Your ignore list and other preferences are kept. This cannot be undone.")
                .fixedSize(horizontal: false, vertical: true)
            Text(PrivacySettingsView.backupNote)
                .font(.footnote).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            TextField("Type yes to confirm", text: $confirmation)
                .onSubmit(delete)
            if let error { Text(error).foregroundStyle(.red).font(.footnote) }
            HStack {
                Spacer()
                if env.isDeletingAll { ProgressView().controlSize(.small); Text("Deleting…") }
                Button("Cancel", role: .cancel) { dismiss() }
                    .disabled(env.isDeletingAll)
                Button("Delete all data", role: .destructive, action: delete)
                    .disabled(env.isDeletingAll
                              || confirmation.trimmingCharacters(in: .whitespaces).lowercased() != "yes")
            }
        }
        .padding(20)
        .frame(width: 400)
    }

    private func delete() {
        guard !env.isDeletingAll, confirmation.trimmingCharacters(in: .whitespaces).lowercased() == "yes" else { return }
        Task {
            do {
                try await env.deleteAllData()
                onFinished("All captured data was deleted.")
                dismiss()
            } catch is DataReset.CleanupPending {
                // The delete committed; only the on-disk scrub failed (retried at launch).
                onFinished("Deleted. Final cleanup will be retried.")
                dismiss()
            } catch {
                self.error = "Deletion failed; nothing was removed. Try again."
            }
        }
    }
}
