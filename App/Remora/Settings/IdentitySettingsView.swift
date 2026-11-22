import Storage
import SwiftUI

/// Settings › Identity: the current identity profile, editable; edits are stored as user
/// revisions (`IdentityStore.saveUserEdit`), which the weekly refresh keeps.
struct IdentitySettingsView: View {
    let env: AppEnvironment

    @State private var text = ""
    @State private var saved = ""
    @State private var history: [IdentityRevision] = []
    @State private var viewing: IdentityRevision?
    @State private var error: String?

    private var store: IdentityStore { IdentityStore(env.db) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ZStack(alignment: .topLeading) {
                TextEditor(text: $text)
                    .font(.body)
                    .frame(minHeight: 260)
                if text.isEmpty {
                    Text("Remora writes this after a few days of activity. You can also write it yourself.")
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .allowsHitTesting(false)
                }
            }
            HStack {
                Button("Save") { save(text) }
                    .disabled(text == saved)
                    .keyboardShortcut("s")
                Button("Revert") { text = saved }
                    .disabled(text == saved)
                if text != saved { Text("Unsaved changes").font(.caption).foregroundStyle(.secondary) }
                Spacer()
                if env.memory.runningNow.contains(.identity) { ProgressView().controlSize(.small) }
                Button("Regenerate now") { env.memory.regenerateIdentity() }
                    .disabled(env.memory.runningNow.contains(.identity) || env.isDeletingAll || text != saved)
            }
            if text != saved {
                Text("Save your changes before regenerating.").font(.footnote).foregroundStyle(.secondary)
            }
            Text("Remora refreshes this weekly. Lines you add are kept, and lines you delete stay deleted.")
                .font(.footnote).foregroundStyle(.secondary)
            if let error { Text(error).font(.footnote).foregroundStyle(.red) }
            if let message = env.memory.message { Text(message).font(.footnote).foregroundStyle(.orange) }
            Text("History").font(.headline)
            List(history, id: \.id) { revision in
                Button { viewing = revision } label: {
                    HStack {
                        Text(revision.source == .user ? "You" : "Remora")
                        Spacer()
                        Text(revision.createdAt.formatted(date: .abbreviated, time: .shortened)).foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .frame(minHeight: 120)
        }
        .padding()
        .onAppear(perform: reload)
        .onChange(of: env.memory.runningNow) { reloadIfUnedited() }
        .sheet(item: Binding(get: { viewing.map(RevisionRef.init) }, set: { viewing = $0?.revision })) { ref in
            RevisionSheet(revision: ref.revision, discardsEdits: text != saved, error: error) {
                if save(ref.revision.body) { viewing = nil }
            }
        }
    }

    private struct RevisionRef: Identifiable {
        let revision: IdentityRevision
        var id: Int64 { revision.id ?? -1 }
    }

    private func reload() {
        do {
            let body = try store.current()?.body ?? ""
            saved = body
            text = body
            history = try store.history(limit: 10)
            error = nil
        } catch {
            self.error = "The identity could not be read."
        }
    }

    /// After a regeneration, show the new text unless the user is editing.
    private func reloadIfUnedited() {
        if text == saved { reload() } else { history = (try? store.history(limit: 10)) ?? history }
    }

    @discardableResult
    private func save(_ body: String) -> Bool {
        do {
            try store.saveUserEdit(body, at: .now)
            reload()
            return true
        } catch {
            self.error = "Could not save the identity."
            return false
        }
    }
}

private struct RevisionSheet: View {
    let revision: IdentityRevision
    /// True when the editor holds unsaved edits that restoring would replace: Restore asks first.
    let discardsEdits: Bool
    let error: String?
    let onRestore: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var confirmDiscard = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("\(revision.source == .user ? "You" : "Remora") · \(revision.createdAt.formatted(date: .abbreviated, time: .shortened))")
                .font(.headline)
            ScrollView {
                Text(revision.body.isEmpty ? "(empty)" : revision.body)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            if let error { Text(error).font(.footnote).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("Close") { dismiss() }
                Button("Restore") { if discardsEdits { confirmDiscard = true } else { onRestore() } }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 480, height: 420)
        .confirmationDialog("Discard your unsaved changes?", isPresented: $confirmDiscard) {
            Button("Discard and Restore", role: .destructive, action: onRestore)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Restoring this version replaces the text you have not saved.")
        }
    }
}
