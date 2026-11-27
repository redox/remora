import Foundation
import Testing

/// App-only wiring: the overlay never activates another process or bypasses the rewrite flow.
@Suite struct EditorMemorySourceGuardTests {
    private func source(_ path: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    @Test func editorNamesItsIconOnlySubmitActionAndTracksUndoAvailability() throws {
        let view = try source("App/Remora/Rewrite/EditBarPanel.swift")
        let button = try #require(view.range(of: "Button(action: onSubmit)"))
        let submit = view[button.upperBound...].prefix { $0 != "}" }
        #expect(submit.contains(#"Label(model.actionTitle, systemImage: "return")"#))
        #expect(submit.contains(".labelStyle(.iconOnly)"))
        #expect(view.contains(".accessibilityLabel(\"Close editor\")"))
        #expect(view.contains("model.canUndo"))
        let controller = try source("App/Remora/Rewrite/RewriteController.swift")
        #expect(controller.contains("bar.model.canUndo = edit?.session?.canUndo ?? false"))
    }

    @Test func dictationLeavesSubmissionToTheSelectedWritingMode() throws {
        let view = try source("App/Remora/Rewrite/EditBarPanel.swift")
        #expect(!view.contains("offersTranscriptInsertion"))
        #expect(!view.contains(#"Button("Insert transcript")"#))
    }

    @Test func editorShowsUndoInTheHeaderAndLeavesUsageManagementToNotices() throws {
        let view = try source("App/Remora/Rewrite/EditBarPanel.swift")
        let controls = try #require(view.range(of: "private var controls:"))
        let close = try #require(view.range(of: "private var closeButton:"))
        #expect(view[controls.upperBound..<close.lowerBound].contains("if model.canUndo { undoButton }"))
        #expect(!view.contains(#"Button("Manage usage")"#))
    }

    @Test func promptOnlyScopeAppearsInTheHeader() throws {
        let view = try source("App/Remora/Rewrite/EditBarPanel.swift")
        let header = try #require(view.range(of: "private var controls:"))
        let close = try #require(view.range(of: "private var closeButton:"))
        let scope = #"Text("Prompt only")"#
        #expect(view[header.upperBound..<close.lowerBound].contains(scope))
        #expect(!view[close.upperBound...].contains(scope))
    }

    @Test func writingPopoverOffersHandsFreeDictationBesideSubmit() throws {
        let view = try source("App/Remora/Rewrite/EditBarPanel.swift")
        let controls = try #require(view.range(of: "private var composerControls:"))
        let submit = try #require(view.range(of: "Button(action: onSubmit)", range: controls.upperBound..<view.endIndex))
        let recording = view[controls.upperBound..<submit.lowerBound]
        #expect(recording.contains("if model.recordEnabled"))
        #expect(recording.contains("model.listening && model.handsFree"))
        #expect(recording.contains("actions?.record()"))
        #expect(recording.contains("model.isWorking || model.finalizing || (model.listening && !model.handsFree)"))
    }

    @Test func editorLetsAnInputMethodHandleCompositionBeforePanelShortcuts() throws {
        let view = try source("App/Remora/Rewrite/EditBarPanel.swift")
        let composition = try #require(view.range(of: "editor.hasMarkedText()"))
        let escape = try #require(view.range(of: "event.keyCode == 53"))
        let submit = try #require(view.range(of: "onReturn()"))
        #expect(composition.lowerBound < escape.lowerBound)
        #expect(composition.lowerBound < submit.lowerBound)
    }

    @Test func finishingDictationLeavesAReviewableDraft() throws {
        let controller = try source("App/Remora/Rewrite/RewriteController.swift")
        let final = try #require(controller.range(of: "func showFinalTranscript"))
        let next = try #require(controller.range(of: "func restoreDraftAfterRecording"))
        let handler = controller[final.lowerBound..<next.lowerBound]
        #expect(handler.contains("bar.setInstruction(text)"))
        #expect(!handler.contains("submitDraft("))
        #expect(!handler.contains("submitRound("))

        let dictation = try source("App/Remora/Dictation/DictationController.swift")
        let finish = try #require(dictation.range(of: "private func finishDraft"))
        let transcribe = try #require(dictation.range(of: "private func transcribeWithOpenAI", range: finish.upperBound..<dictation.endIndex))
        let finishing = dictation[finish.upperBound..<transcribe.lowerBound]
        let chat = try #require(finishing.range(of: "if let appendToChat"))
        let upload = try #require(finishing.range(of: "await transcribeWithOpenAI"))
        #expect(chat.lowerBound < upload.lowerBound)
        #expect(finishing.contains("if cloud == nil, settings.cleanupEnabled"))
        #expect(finishing.contains("cloudAllowed: false"))
        #expect(!finishing.contains("submitDraft("))
        #expect(finishing.range(of: "rewrite.showFinalTranscript", range: upload.upperBound..<finishing.endIndex) != nil)
    }

    @Test func deleteAllDiscardsTheWritingPopoverDraft() throws {
        let env = try source("App/Remora/AppEnvironment.swift")
        let reset = try #require(env.range(of: "func deleteAllData()"))
        let wiring = try #require(env.range(of: "// MARK: - Wiring"))
        #expect(env[reset.lowerBound..<wiring.lowerBound].contains("rewrite.closeEditBar()"))
        let view = try source("App/Remora/Rewrite/EditBarPanel.swift")
        let close = try #require(view.range(of: "func close()"))
        let paste = try #require(view.range(of: "func hideForPaste()"))
        #expect(view[close.lowerBound..<paste.lowerBound].contains("model.instruction = \"\""))
    }

    @Test func editorGrowsForNotices() throws {
        let view = try source("App/Remora/Rewrite/EditBarPanel.swift")
        #expect(view.contains("onGeometryChange"))
        #expect(!view.contains(".lineLimit(1)"))
    }

    @Test func caretAndNotchOverlaysShareOpaqueSurfacesAndAdaptiveComposerBackgrounds() throws {
        for path in ["Rewrite/EditBarPanel.swift", "Chat/ChatView.swift"] {
            let view = try source("App/Remora/\(path)")
            #expect(view.contains(".modifier(OverlaySurface("))
            #expect(view.contains(".background(OverlayComposerBackground("))
            #expect(!view.contains(".shadow("))
        }
        let appearance = try source("App/Remora/Appearance/OverlayAppearance.swift")
        #expect(appearance.contains("shape.fill(Color(nsColor: .textBackgroundColor))"))
        #expect(appearance.contains("contrast == .increased"))
    }

    @Test func composerFocusFollowsTheRoundedOutline() throws {
        let appearance = try source("App/Remora/Appearance/OverlayAppearance.swift")
        let start = try #require(appearance.range(of: "struct OverlayComposerBackground"))
        let end = try #require(appearance.range(of: "struct QuietButtonStyle", range: start.upperBound..<appearance.endIndex))
        let composer = appearance[start.lowerBound..<end.lowerBound]
        #expect(composer.contains("shape.strokeBorder(Color.primary.opacity(borderOpacity))"))
        #expect(!composer.contains(".overlay(alignment: .bottom)"))
    }

    @Test func quietButtonsCanShowSelectionWhileDisabled() throws {
        let appearance = try source("App/Remora/Appearance/OverlayAppearance.swift")
        #expect(!appearance.contains("selected && enabled"))
        let editor = try source("App/Remora/Rewrite/EditBarPanel.swift")
        #expect(editor.contains("QuietButtonStyle(selected: model.mode == mode)"))
    }

    @Test func editInstructionWrapsAndGrowsWithinThePanel() throws {
        let view = try source("App/Remora/Rewrite/EditBarPanel.swift")
        let layout = try #require(view.range(of: "ChatComposerLayout {"))
        let field = try #require(view.range(of: "TextField(model.placeholder", range: layout.upperBound..<view.endIndex))
        let controls = try #require(view.range(of: "if model.isWorking {", range: field.upperBound..<view.endIndex))
        let instruction = view[field.lowerBound..<controls.lowerBound]
        #expect(instruction.contains("text: $model.instruction, axis: .vertical"))
        #expect(instruction.contains(".lineLimit(1...6)"))
    }

    @Test func memoryBrowsersLoadOffTheMainActorAndDiscardCancelledReads() throws {
        for name in ["WikiBrowserView", "ChronicleBrowserView"] {
            let view = try source("App/Remora/Settings/\(name).swift")
            #expect(view.contains("Task.detached"))
            #expect(view.contains("guard !Task.isCancelled else { return }"))
            #expect(view.contains("Button(\"Retry\")"))
            #expect(!view.contains(".onAppear(perform: reload)"))
        }
    }

    @Test func wikiFactsReportReadFailuresInsteadOfSilentlyShowingNoFacts() throws {
        let view = try source("App/Remora/Settings/WikiBrowserView.swift")
        #expect(!view.contains("(try? WikiStore(db).facts"))
        #expect(view.contains("The page details could not be read."))
        #expect(view.contains("if let readError"))
        #expect(view.contains("if let deleteError"))
    }

    @Test func identityRegenerationDoesNotIgnoreUnsavedEdits() throws {
        let view = try source("App/Remora/Settings/IdentitySettingsView.swift")
        #expect(view.contains("Save your changes before regenerating."))
        #expect(view.contains("env.isDeletingAll || text != saved"))
        #expect(view.contains("if save(ref.revision.body) { viewing = nil }"))
    }

    @Test func deletingAllDataRemovesTheMemoryBrowsersAndTheirCachedResults() throws {
        let view = try source("App/Remora/Settings/MemorySettingsView.swift")
        #expect(view.contains("if env.isDeletingAll"))
        #expect(view.contains("ProgressView(\"Deleting memory…\")"))
    }
}
