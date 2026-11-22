import Capture
import Observation
import SwiftUI

@MainActor @Observable
final class SavedNoteDraft {
    var text: String
    var annotation = ""
    var error: String?
    var saving = false
    let generation: Int

    init(text: String = "", generation: Int) {
        self.text = text
        self.generation = generation
    }

    var sizeOK: Bool {
        text.utf8.count <= RememberedNotes.maximumTextBytes
            && annotation.utf8.count <= RememberedNotes.maximumAnnotationBytes
    }

    func showSaveError(_ error: any Error) {
        switch error {
        case RememberedNotes.Refusal.sourceUnavailable:
            self.error = "This selection can no longer be saved."
        case RememberedNotes.Refusal.empty:
            self.error = "Enter some text to save."
        case RememberedNotes.Refusal.tooLong:
            self.error = "Shorten the excerpt or note before saving."
        default:
            self.error = "Could not save the note."
        }
    }
}

struct SavedNoteEditor: View {
    @Bindable var draft: SavedNoteDraft
    let save: () -> Void
    let cancel: () -> Void
    @FocusState private var excerptFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Remember this").font(.headline)
            TextEditor(text: $draft.text)
                .font(.body)
                .frame(height: 112)
                .accessibilityLabel("Text to remember")
                .focused($excerptFocused)
                .overlay(alignment: .topLeading) {
                    if draft.text.isEmpty {
                        Text("Paste or type the text to remember")
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 5)
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                    }
                }
            TextField("Add a note (optional)", text: $draft.annotation)
            if !draft.sizeOK || draft.error != nil {
                Text(draft.sizeOK ? (draft.error ?? "") : "Shorten the excerpt or note before saving.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            HStack {
                Button("Cancel", action: cancel)
                Spacer()
                if draft.saving { ProgressView().controlSize(.small) }
                Button("Save to memory", action: save)
                    .buttonStyle(.borderedProminent)
                    .disabled(!draft.sizeOK || draft.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .disabled(draft.saving)
        .onAppear { excerptFocused = true }
    }
}
