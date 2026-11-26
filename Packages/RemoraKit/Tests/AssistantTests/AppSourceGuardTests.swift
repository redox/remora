import Foundation
import Testing

/// Guards on App sources that have no test target of their own: they read the Swift files.
@Suite struct AppSourceGuardTests {
    @Test func transientRecordingInterruptionsDoNotStopTheRoomUntilDeparture() throws {
        let controller = try source("App/Remora/Meetings/MeetingRecordingController.swift")
        let start = try #require(controller.range(of: "    func interrupt("))
        let body = try #require(controller[start.upperBound...].components(separatedBy: "\n    }").first)
        #expect(!body.contains("starts.suppress("))
        #expect(body.contains("starts.retryAfterInterruption("))
        #expect(controller.contains("starts.mayStart(meeting.id)"))
    }

    @Test func aVerifiedRecordingSchedulesItsNextCheckBeforeTheIdleDiscoveryPoll() throws {
        let controller = try source("App/Remora/Meetings/MeetingRecordingController.swift")
        let start = try #require(controller.range(of: "private func renewDeadline("))
        let end = try #require(controller.range(of: "    func stop()", range: start.upperBound..<controller.endIndex))
        let renewal = controller[start.upperBound..<end.lowerBound]
        #expect(renewal.contains(".milliseconds(500)"))
        #expect(renewal.contains("check()"))
        #expect(renewal.contains("interrupt(reason:"))
        #expect(controller.contains("finish(interrupted: !confirmed, through: active.lastVerified,"))
    }

    @Test func meetingLanguageAndSpeechAssetsFollowTheSavedTranscriptionKey() throws {
        let view = try source("App/Remora/Settings/MeetingRecordingSettingsView.swift")
        #expect(view.contains("private var usesOpenAI: Bool { env.dictation.hasTranscriptionKey }"))
        #expect(view.contains("if !usesOpenAI { localSpeechSettings }"))
        #expect(view.contains("guard !usesOpenAI else { return }"))
        #expect(view.contains("OpenAI detects the language"))
        let keyView = try source("App/Remora/Settings/DictationSettingsView.swift")
        #expect(keyView.contains("automatic meeting recording"))
    }

    @Test func meetingLibraryHidesCachedContentUntilItChecksTheCurrentExclusions() throws {
        let view = try source("App/Remora/Settings/MeetingSourcesView.swift")
        #expect(view.contains("ForEach(loadedRevision == model.revision ? results : [])"))
        #expect(view.contains("if loadedRevision == model.revision, let detail"))
        let model = try source("App/Remora/Settings/MeetingSourcesModel.swift")
        #expect(model.contains("guard !Task.isCancelled else { return }"))
    }

    @Test func meetingUploadsRequireTheOriginalKeyAndCurrentCapturePermission() throws {
        let controller = try source("App/Remora/Meetings/MeetingRecordingController.swift")
        let start = try #require(controller.range(of: "private func mayTranscribe("))
        let gate = controller[start.upperBound...].prefix(while: { $0 != "}" })
        for check in ["active === recording", "allowed", "env.permissions.accessibilityGranted",
                      "env.permissions.microphone == .granted", "DataGeneration.current",
                      "SnapshotPolicy.current", "TranscriptionKeychain.load()"] {
            #expect(gate.contains(check))
        }
        #expect(controller.contains("active.audio.confirmVerified(through: observationStart"))
        #expect(controller.contains("recording.audio.invalidateUnverifiedAudio()"))
        let env = try source("App/Remora/AppEnvironment.swift")
        #expect(env.contains("meetingRecording.transcriptionKeyChanged()"))
    }

    @Test func meetingMenuShowsSetupOrDetectionStatusBeforeRecordingStarts() throws {
        let menu = try source("App/Remora/MenuBarContent.swift")
        #expect(menu.contains("Set up meeting recording…"))
        #expect(menu.contains("Text(env.meetingRecording.displayStatus)"))
    }

    @Test func windowSwitchesDoNotPresentCaptureStatusPopups() throws {
        let environment = try source("App/Remora/AppEnvironment.swift")
        #expect(!environment.contains("SwitchLabelPanel()"))
    }

    @Test func dictationFailuresUseTheWritingPopoverNotice() throws {
        let controller = try source("App/Remora/Dictation/DictationController.swift")
        #expect(controller.contains("rewrite.showDictationNotice(notice)"))
        #expect(!controller.contains("DictationHUDPanel"))
        let rewrite = try source("App/Remora/Rewrite/RewriteController.swift")
        #expect(rewrite.contains("bar.model.notice = notice.writingNotice"))
    }

    @Test func docsPasteRequiresTheSamePassageAndTargetsOnlyTheActiveSelection() throws {
        let controller = try source("App/Remora/Rewrite/RewriteController.swift")
        let start = try #require(controller.range(of: "private func replaceDocsSelection("))
        let body = try #require(controller[start.upperBound...].components(separatedBy: "\n    }").first)
        let check = try #require(body.range(of: "guard (try? await readDocsSelection(source, field: field)) == original"))
        let paste = try #require(body.range(of: "inserter.insert(replacement, target: .caret"))
        #expect(check.upperBound < paste.lowerBound)
        #expect(body.contains("expectedSelection: field.selection"))
    }

    @Test func writingPopoverOffersLanguageSwitchingOnlyWithMacTranscription() throws {
        let panel = try source("App/Remora/Rewrite/EditBarPanel.swift")
        #expect(panel.contains("if actions?.showsDictationLanguage() == true, let locale = model.recordingLocale"))
        let controller = try source("App/Remora/Rewrite/RewriteController.swift")
        #expect(controller.contains("showsDictationLanguage: { [weak dictation] in dictation?.hasTranscriptionKey == false }"))
    }

    @Test func insertSubmitsTheReviewedPromptForDrafting() throws {
        let panel = try source("App/Remora/Rewrite/EditBarPanel.swift")
        #expect(panel.contains("actions?.submit(model.instruction, model.submission)"))
        #expect(panel.contains("mode.submission(hasFallback: fallbackActionTitle != nil)"))
        #expect(panel.contains("Button(\"Insert transcript\") { actions?.submit(model.instruction, .insertText) }"))
        let controller = try source("App/Remora/Rewrite/RewriteController.swift")
        let compose = try #require(controller.range(of: "case .compose:"))
        let literal = try #require(controller.range(of: "case .insertText:", range: compose.upperBound..<controller.endIndex))
        #expect(controller[compose.upperBound..<literal.lowerBound].contains("composeDraft(text, context: ctx)"))
    }

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

    @Test func chatOpensAtTheWelcomeHeadingOrLatestMessage() throws {
        let view = try source("App/Remora/Chat/ChatView.swift")
        #expect(view.contains(".defaultScrollAnchor(hasMessages ? .bottom : .top, for: .initialOffset)"))
        #expect(view.contains(".defaultScrollAnchor(.top, for: .alignment)"))
    }

    @Test func storedAndStreamingMessagesOfferAWholeMessageCopyButton() throws {
        let chat = try source("App/Remora/Chat/ChatView.swift")
        let message = try source("App/Remora/Chat/MessageView.swift")
        #expect(chat.contains("CopyMessageButton(text: text)"))
        #expect(chat.contains("CopyMessageButton(text: model.streamingText"))
        #expect(message.contains("CopyMessageButton(text:"))
        #expect(message.contains(".labelStyle(.iconOnly)"))
    }

    @Test func chatMessageBodiesUseNativeSelectableText() throws {
        let chat = try source("App/Remora/Chat/ChatView.swift")
        let markdown = try source("App/Remora/Chat/MarkdownView.swift")
        #expect(chat.contains("SelectableChatText("))
        #expect(markdown.contains("SelectableChatText("))
    }

    @Test func sendingJumpsToLatestBeforeAnyResponseArrives() throws {
        let view = try source("App/Remora/Chat/ChatView.swift")
        let send = try #require(view.range(of: ".onChange(of: model.isStreaming, initial: true)"))
        let handler = view[send.upperBound...].prefix(while: { $0 != "}" })
        #expect(handler.contains("if isStreaming { scrollToLatest()"))
        #expect(!view.contains(".onChange(of: model.streamingText)"))
    }

    @Test func chatFollowsLayoutChangesOnlyNearTheLatestMessage() throws {
        let view = try source("App/Remora/Chat/ChatView.swift")
        #expect(view.contains(".defaultScrollAnchor(hasMessages && atLatest ? .bottom : nil, for: .sizeChanges)"))
        #expect(view.contains(".onScrollGeometryChange(for: ScrollGeometry.self"))
        #expect(view.contains("if !atLatest && messagePosition.edge == .bottom"))
        #expect(view.contains("if hasMessages && !atLatest && messagePosition.edge != .bottom"))
    }

    @Test func chatHonorsNotificationTargetsOnFirstLayout() throws {
        let view = try source("App/Remora/Chat/ChatView.swift")
        #expect(view.contains(".onChange(of: model.scrollTarget, initial: true)"))
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

    @Test func captureIndicatorsUseRemoraArtworkWithoutAGenericFishFallback() throws {
        let badge = try source("App/Remora/Indicator/WindowBadgePanel.swift")
        let brand = try source("App/Remora/Appearance/RemoraBrand.swift")
        let menuBar = try source("App/Remora/Indicator/MenuBarIcon.swift")
        #expect(badge.contains("RemoraBrand.glyphImage("))
        #expect(menuBar.contains("symbol == RemoraBrand.glyphName"))
        #expect(!badge.contains("\"fish"))
        #expect(!brand.contains("\"fish"))
        #expect(!menuBar.contains("\"fish"))
    }

    @Test func menuBarWaveformTracksRecordingAndHonorsReduceMotion() throws {
        let label = try source("App/Remora/RemoraApp.swift")
        #expect(label.contains("accessibilityReduceMotion"))
        #expect(label.contains("env.meetingRecording.recordingClientName"))
        #expect(label.contains("env.dictation.phase == .listening"))
        let icon = try source("App/Remora/Indicator/MenuBarIcon.swift")
        #expect(icon.contains("NSColor.systemRed"))
        #expect(icon.contains("systemSymbolName: \"waveform\""))
        let controller = try source("App/Remora/Meetings/MeetingRecordingController.swift")
        let ready = try #require(controller.range(of: "active.audio.setMicAllowed(active.observingCall && meeting.micAllowed)"))
        let indicator = try #require(controller.range(of: "recordingClientName = meeting.client.displayName"))
        let update = controller[ready.upperBound..<indicator.lowerBound]
        #expect(update.contains("guard !active.finishing") && update.contains("if active.observingCall"))
        for method in ["func discard()", "private func finish(interrupted:"] {
            let body = try #require(controller.range(of: method))
            #expect(controller[body.upperBound...].components(separatedBy: "\n    }")[0].contains("recordingClientName = nil"))
        }
    }

    @Test func captureIndicatorsUseTheBrandAccent() throws {
        let badge = try source("App/Remora/Indicator/WindowBadgePanel.swift")
        let menuBar = try source("App/Remora/Indicator/MenuBarIcon.swift")
        #expect(badge.contains("RemoraBrand.accentColor"))
        #expect(menuBar.contains("RemoraBrand.accentColor"))
        #expect(!badge.contains(".systemOrange"))
        #expect(!menuBar.contains(".systemOrange"))
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

    @Test func usagePageScrollsAsAWholeWithAFixedHeightCallTable() throws {
        let view = try source("App/Remora/Settings/UsageSettingsView.swift")
        let body = try #require(view.range(of: "var body: some View {"))
        #expect(view[body.upperBound...].contains("ScrollView {"))
        let table = try source("App/Remora/Settings/Usage/UsageCallTable.swift")
        #expect(table.contains("Table(") && table.contains(".frame(height:"))
    }

    /// The pane reads `llm_calls` through `LLMCallStore` only; GRDB stays in RemoraKit.
    @Test func usagePaneDoesNotImportGRDB() throws {
        let files = try usagePaneSources()
        #expect(files.count >= 6)
        for (name, text) in files { #expect(!text.contains("import GRDB"), "\(name)") }
    }

    /// The daily background budget is gone; the pane must not bring its wording back.
    @Test func usagePaneNeverShowsDailyBudget() throws {
        for (name, text) in try usagePaneSources() {
            #expect(!text.contains("Daily budget") && !text.contains("daily budget"), "\(name)")
            #expect(!text.contains("price table ships empty"), "\(name)")
        }
    }

    /// Unpriced history is repriced off the main actor at launch and when the pane appears.
    @Test func unpricedCallsAreBackfilledOffTheMainActor() throws {
        let env = try source("App/Remora/AppEnvironment.swift")
        #expect(env.contains("UsageRepricer.backfill(store: LLMCallStore(db), prices: prices.table())"))
        let view = try source("App/Remora/Settings/UsageSettingsView.swift")
        let detached = try #require(view.range(of: "Task.detached"))
        #expect(view[detached.upperBound...].contains("UsageRepricer.backfill("))
    }

    private func usagePaneSources() throws -> [(String, String)] {
        let dir = Self.repoRoot.appendingPathComponent("App/Remora/Settings/Usage")
        let names = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasSuffix(".swift") }
        return try [("UsageSettingsView.swift", source("App/Remora/Settings/UsageSettingsView.swift"))]
            + names.sorted().map { ($0, try source("App/Remora/Settings/Usage/\($0)")) }
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
