import AppKit
import Capture
import Storage
import SwiftUI

struct SavedNotesView: View {
    let db: AppDatabase
    @State private var notes: [SavedNote] = []
    @State private var query = ""
    @State private var draft: SavedNoteDraft?
    @State private var chatEnabled = false
    @State private var error: String?
    @State private var noteToDelete: SavedNote?
    @State private var refresh = 0

    private struct LoadKey: Equatable {
        let query: String
        let refresh: Int
    }

    private var store: SavedNoteStore { SavedNoteStore(db) }

    var body: some View {
        Toggle("Use saved notes in chat", isOn: Binding(
            get: { chatEnabled }, set: setChatAccess))
            .task(id: LoadKey(query: query, refresh: refresh)) { await reload(query: query) }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                refresh += 1
            }
            .confirmationDialog("Delete this note?", isPresented: Binding(
                get: { noteToDelete != nil }, set: { if !$0 { noteToDelete = nil } }),
                presenting: noteToDelete) { note in
                    Button("Delete note", role: .destructive) { delete(note) }
                }
        Text("When enabled, relevant saved excerpts can be sent to OpenAI when you ask Remora in chat.")
            .font(.footnote)
            .foregroundStyle(.secondary)
        if let draft {
            SavedNoteEditor(draft: draft, save: { save(draft) }, cancel: { self.draft = nil })
        } else {
            HStack {
                TextField("Search saved notes", text: $query)
                Button("New note", action: newNote)
            }
        }
        if let error { Text(error).font(.footnote).foregroundStyle(.red) }
        ForEach(notes) { note in
            DisclosureGroup {
                if !note.annotation.isEmpty {
                    Text(note.annotation).font(.subheadline).textSelection(.enabled)
                }
                Text(note.text).textSelection(.enabled)
                Button("Delete note…", role: .destructive) { noteToDelete = note }
            } label: {
                VStack(alignment: .leading) {
                    Text(note.annotation.isEmpty ? note.text : note.annotation).lineLimit(1)
                    Text(note.createdAt.formatted(date: .abbreviated, time: .shortened))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        if notes.isEmpty, error == nil {
            Text(query.isEmpty ? "No saved notes yet." : "No matching notes.").foregroundStyle(.secondary)
        }
    }

    private func newNote() {
        do {
            draft = SavedNoteDraft(generation: try DataGeneration.current(db))
        } catch {
            self.error = "Could not start a new note."
        }
    }

    private func save(_ draft: SavedNoteDraft) {
        guard !draft.saving else { return }
        draft.saving = true
        draft.error = nil
        let text = draft.text, annotation = draft.annotation, generation = draft.generation
        let memory = RememberedNotes(db)
        Task {
            do {
                _ = try await Task.detached {
                    try memory.save(text, annotation: annotation, generation: generation)
                }.value
                self.draft = nil
                query = ""
                refresh += 1
            } catch {
                draft.saving = false
                draft.showSaveError(error)
            }
        }
    }

    private func reload(query: String) async {
        let store = store
        do {
            let result = try await Task.detached {
                (try store.list(query: query), try store.chatAccessEnabled())
            }.value
            guard !Task.isCancelled else { return }
            (notes, chatEnabled) = result
            error = nil
        } catch {
            guard !Task.isCancelled else { return }
            self.error = "Could not load saved notes."
        }
    }

    private func setChatAccess(_ enabled: Bool) {
        do {
            try store.setChatAccess(enabled)
            chatEnabled = enabled
            error = nil
            refresh += 1
        } catch {
            self.error = "Could not change chat access."
        }
    }

    private func delete(_ note: SavedNote) {
        do {
            try store.delete(note.id)
            refresh += 1
        } catch {
            self.error = "Could not delete the note."
        }
    }
}
