import Foundation
import Testing

/// Guards on App sources that have no test target of their own: they read the Swift files.
@Suite struct AppSourceGuardTests {
    @Test func rememberingASelectionUsesAnExplicitSaveButton() throws {
        let panel = try source("App/Remora/Rewrite/EditBarPanel.swift")
        let editor = try source("App/Remora/Memory/SavedNoteEditor.swift")
        #expect(panel.contains("if let draft = model.noteDraft"))
        #expect(panel.contains("guard model.noteDraft == nil, model.savedNoteID == nil, model.canSubmit"))
        #expect(editor.contains("Button(\"Save to memory\", action: save)"))
        #expect(!editor.contains(".keyboardShortcut(.defaultAction)"))
    }

    @Test func chatPanelExplicitlyReceivesMouseEventsAcrossItsTransparentSurface() throws {
        let panel = try source("App/Remora/Chat/ChatPanel.swift")
        #expect(panel.contains("ignoresMouseEvents = false"))
        // Reading false is not sufficient: the setter opts out of alpha-based event routing.
        #expect(!panel.contains("if ignoresMouseEvents"))
    }

    @Test func emptyChatOpensAtTheWelcomeHeadingInsteadOfTheLastSuggestion() throws {
        let view = try source("App/Remora/Chat/ChatView.swift")
        #expect(view.contains("if !model.turns.isEmpty || model.sendingText != nil"))
        #expect(!view.contains(".onAppear { proxy.scrollTo(Self.bottom, anchor: .bottom) }"))
        #expect(view.contains("proxy.scrollTo(Self.top, anchor: .top)"))
        #expect(view.contains(".onChange(of: model.turns.last?.id) { scrollToLatest(proxy) }"))
    }

    @Test func reopeningAStreamingChatDoesNotReloadItsProvisionalRows() throws {
        let view = try source("App/Remora/Chat/ChatView.swift")
        #expect(view.contains("if !model.isStreaming { model.reload() }"))
    }

    @Test func textSelectionDoesNotInheritBrandTintFromItsContainer() throws {
        let chat = try source("App/Remora/Chat/ChatView.swift")
        let editBar = try source("App/Remora/Rewrite/EditBarPanel.swift")
        let settings = try source("App/Remora/Settings/SettingsView.swift")
        #expect(!chat.contains(".tint(RemoraBrand.accent"))
        #expect(!editBar.contains(".tint(accent)"))
        #expect(!settings.contains(".tint("))
    }

    @Test func confirmationWarningSharesTheBoundedScrollAreaWithTheSummary() throws {
        let card = try source("App/Remora/Chat/ConfirmationCard.swift")
        let warning = try #require(card.range(of: "if proposal.afterUntrustedRead"))
        let cap = try #require(card.range(of: ".frame(maxHeight: summaryMaxHeight)"))
        let allow = try #require(card.range(of: "Button(\"Allow\")"))
        #expect(warning.lowerBound < cap.lowerBound)
        #expect(allow.lowerBound > cap.lowerBound)
    }
    private static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // AssistantTests
        .deletingLastPathComponent()  // Tests
        .deletingLastPathComponent()  // RemoraKit
        .deletingLastPathComponent()  // Packages
        .deletingLastPathComponent()

    private func source(_ path: String) throws -> String {
        try String(contentsOf: Self.repoRoot.appendingPathComponent(path), encoding: .utf8)
    }

    /// Editing from a hover-opened panel must acquire keyboard focus and use replacement mode.
    @Test func editingTheLatestMessageFocusesTheComposerAndResendsAsAReplacement() throws {
        let message = try source("App/Remora/Chat/MessageView.swift")
        #expect(message.contains("if let id = turn.id, id == model.latestUserTurnID"))
        #expect(message.contains("model.editLastMessage()\n                        bar.open(focusInput: true)"))
        let model = try source("App/Remora/Chat/ChatModel.swift")
        #expect(model.contains("send(text, replacing: editingTurnID)"))
        #expect(model.contains("editingTurnID == nil && !isStreaming && !clearing"))
        let view = try source("App/Remora/Chat/ChatView.swift")
        #expect(view.contains("model.cancelEditing()"))
        #expect(view.contains(".disabled(model.editingTurnID != nil && model.isStreaming)"))
    }

    @Test func notificationSettingsRefreshWhenReturningFromSystemSettings() throws {
        let view = try source("App/Remora/Settings/NotificationsSettingsView.swift")
        #expect(view.contains("NSApplication.didBecomeActiveNotification"))
        #expect(view.components(separatedBy: "await proactive.refreshNotificationAuth()").count == 3)
    }

    @Test func dictationSettingsShowWhereToPasteTheMaskedOpenAIKey() throws {
        let view = try source("App/Remora/Settings/DictationSettingsView.swift")
        let field = try #require(view.range(of: "SecureField(\"OpenAI API key\""))
        let actions = try #require(view.range(of: "Button(dictation.hasTranscriptionKey ? \"Replace key\"", range: field.upperBound..<view.endIndex))
        let input = view[field.lowerBound..<actions.lowerBound]
        #expect(input.contains("prompt: Text("))
        #expect(input.contains(".textFieldStyle(.roundedBorder)"))
    }

    @Test func disconnectDoesNotAskTheUserToLoadRemoraAgain() throws {
        let view = try source("App/Remora/Settings/MCPSettingsView.swift")
        #expect(view.contains("state.changed = connect"))
        #expect(!view.contains("state.changed = true"))
    }

    @Test func chatDetailsReadTheDatabaseOffTheMainActor() throws {
        let model = try source("App/Remora/Chat/ChatModel.swift")
        let details = try #require(model.range(of: "func details(for"))
        let end = try #require(model.range(of: "func requestFocus", range: details.upperBound..<model.endIndex))
        #expect(model[details.lowerBound..<end.lowerBound].contains("Task.detached"))
        let view = try source("App/Remora/Chat/MessageDetailsView.swift")
        #expect(view.contains("await model.details(for: turn)"))
    }

    @Test func closingDictationSettingsStopsPollingBeforeAnotherRefresh() throws {
        let view = try source("App/Remora/Settings/DictationSettingsView.swift")
        #expect(view.contains("do { try await Task.sleep(for: .seconds(1)) } catch { return }"))
    }

    @Test func appearanceControlsStartWithTheSavedBarSettings() throws {
        let view = try source("App/Remora/Settings/AppearanceSettingsView.swift")
        #expect(view.contains("State(initialValue: env.bar.current)"))
        #expect(!view.contains("var bar = BarSettings()"))
    }

    @Test func jobRoutingHeaderUsesTheFullRowToToggleItsDisclosure() throws {
        let view = try source("App/Remora/Settings/AccountSettingsView.swift")
        #expect(view.contains("DisclosureGroup(isExpanded: $isJobRoutingExpanded)"))
        let label = try #require(view.range(of: "Text(\"Job routing\")"))
        let modifiers = view[label.upperBound...].prefix(while: { $0 != "}" })
        #expect(modifiers.contains(".frame(maxWidth: .infinity, alignment: .leading)"))
        #expect(modifiers.contains(".contentShape(Rectangle())"))
        #expect(modifiers.contains(".onTapGesture { withAnimation { isJobRoutingExpanded.toggle()"))
    }

    @Test func usagePageCanScrollWhenRecentCallsExpand() throws {
        let view = try source("App/Remora/Settings/UsageSettingsView.swift")
        let body = try #require(view.range(of: "var body: some View {"))
        let table = try #require(view.range(of: "Table(rows)"))
        let caption = try #require(view.range(of: "Text(UsagePresentation.caption)"))
        let scrolls = view[body.upperBound..<table.lowerBound].contains("ScrollView {")
        let tableHasFixedHeight = view[table.upperBound..<caption.lowerBound].contains(".frame(height:")
        #expect(scrolls)
        #expect(tableHasFixedHeight)
    }

    /// Peek includes the notch in its window; open does not. Interpolating the window frame
    /// after immediately swapping card offsets briefly puts the header inside the notch.
    @Test func chatOpeningDoesNotAnimateBetweenDifferentWindowCoordinateSpaces() throws {
        let controller = try source("App/Remora/Chat/ChatBarController.swift")
        #expect(!controller.contains("panel.animator().setFrame"))
        #expect(controller.contains(".overlay(alignment: .topLeading)"))
    }

    /// A decorative rewrite animation must respect Reduce Motion and stay an explicit cancel
    /// button; it must not acquire keyboard focus or become a default action.
    @Test func rewriteBadgeRespectsReducedMotionAndKeepsCancellationExplicit() throws {
        let view = try source("App/Remora/Rewrite/CaretIndicatorPanel.swift")
        #expect(view.contains("accessibilityReduceMotion"))
        #expect(view.contains("Button(action: onCancel)"))
        #expect(view.contains("canBecomeKey: Bool { false }"))
        #expect(!view.contains(".keyboardShortcut"))
    }

    @Test func rewriteBadgeShowsAVisibleWritingLabel() throws {
        let view = try source("App/Remora/Rewrite/CaretIndicatorPanel.swift")
        #expect(view.contains("Text(\"Writing…\")"))
        #expect(view.contains("c == .working ? Self.workingSize"))
    }

    /// Return must never approve an action: the card's buttons carry no keyboard shortcut.
    @Test func confirmationCardAllowHasNoKeyboardShortcut() throws {
        let card = try source("App/Remora/Chat/ConfirmationCard.swift")
        #expect(card.contains("Button(\"Allow\")"))
        #expect(!card.contains(".keyboardShortcut"))
        #expect(!card.contains(".defaultAction"))
    }

    /// Settings › Notifications says reminders still notify with proactive messages off.
    @Test func notificationsCaptionSaysRemindersStillNotify() throws {
        let view = try source("App/Remora/Settings/NotificationsSettingsView.swift")
        #expect(view.contains("reminders still notify"))
        #expect(!view.contains("Remora sends nothing on its own"))
    }

    /// Remora logs at `.info`: without `--info` the export is nearly empty. No blocking wait.
    @Test func logExportIncludesInfoAndNeverBlocksAThread() throws {
        let view = try source("App/Remora/Settings/LogsSettingsView.swift")
        #expect(view.contains("\"show\", \"--info\""))
        #expect(!view.contains("DispatchSemaphore"))
    }

    /// Delete-all clears notifications and the chat panel after the wipe.
    @Test func deleteAllClearsWhatIsOnScreen() throws {
        let env = try source("App/Remora/AppEnvironment.swift")
        #expect(env.contains("await proactive.dataDeleted()"))
        let poster = try source("App/Remora/Proactive/SystemNotificationPoster.swift")
        #expect(poster.contains("removeAllDeliveredNotifications()") && poster.contains("removeAllPendingNotificationRequests()"))
    }
}
