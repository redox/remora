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

    @Test func editorOffersVisibleActionsAndTracksUndoAvailability() throws {
        let view = try source("App/Remora/Rewrite/EditBarPanel.swift")
        #expect(view.contains("Button(action: onSubmit)"))
        #expect(view.contains("Text(model.actionTitle)"))
        #expect(view.contains(".accessibilityLabel(\"Close editor\")"))
        #expect(view.contains("model.canUndo"))
        let controller = try source("App/Remora/Rewrite/RewriteController.swift")
        #expect(controller.contains("bar.model.canUndo = edit?.session?.canUndo ?? false"))
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
        let prepare = try #require(dictation.range(of: "func prepareInsertion"))
        #expect(!dictation[finish.lowerBound..<prepare.lowerBound].contains("await finalTranscript("))
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

    @Test func composerFocusRemainsVisibleAtStandardContrast() throws {
        let appearance = try source("App/Remora/Appearance/OverlayAppearance.swift")
        #expect(appearance.contains(".overlay(alignment: .bottom)"))
        #expect(appearance.contains("else if focused"))
        #expect(appearance.contains("Capsule()"))
    }

    @Test func quietButtonsCanShowSelectionWhileDisabled() throws {
        let appearance = try source("App/Remora/Appearance/OverlayAppearance.swift")
        #expect(!appearance.contains("selected && enabled"))
        let editor = try source("App/Remora/Rewrite/EditBarPanel.swift")
        #expect(editor.contains("QuietButtonStyle(selected: model.mode == mode)"))
        #expect(editor.contains("QuietButtonStyle(selected: model.canSubmit)"))
    }

    @Test func editInstructionWrapsAndGrowsWithinThePanel() throws {
        let view = try source("App/Remora/Rewrite/EditBarPanel.swift")
        let field = try #require(view.range(of: "TextField(model.placeholder"))
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
