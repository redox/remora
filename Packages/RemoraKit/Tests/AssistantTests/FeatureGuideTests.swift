import Foundation
import LLM
import Testing
@testable import Assistant

@Suite struct FeatureGuideTests {
    @Test func sectionIdsAreExactlyTheSpecified() {
        #expect(FeatureGuide.sections.map(\.id) == [
            "overview", "rewrite-key", "edit-mode", "ask-in-field", "dictation", "chat-bar", "reminders",
            "briefs-and-nudges", "memory", "identity", "privacy", "pause-and-delete", "mcp", "usage", "settings",
            "shortcuts", "troubleshooting",
        ])
        #expect(FeatureGuide.sections.allSatisfy { !$0.title.isEmpty && $0.body.count > 80 })
    }

    @Test func guideCoversEverySettingsPageAndExclusionSyntax() {
        let all = FeatureGuide.sections.map(\.body).joined()
        for p in ["Account", "Usage", "Privacy", "Appearance", "Identity", "Memory", "Notifications", "Shortcuts",
                  "Dictation", "MCP", "Logs"] { #expect(all.contains(p), "\(p)") }
        for s in ["app:", "title:", "url:", "path:"] { #expect(all.contains(s), "\(s)") }
    }

    /// Settings › Usage is a dashboard over a live call log; the guide must describe that screen.
    @Test func usageSectionDescribesTheDashboardAndCallLog() throws {
        let usage = try #require(FeatureGuide.sections.first { $0.id == "usage" }).body
        for p in ["Today, 7 days or 30 days", "by category", "by job or by model", "live log", "API-equivalent"] {
            #expect(usage.contains(p), "\(p)")
        }
        #expect(!usage.contains("per day, job and model"))
    }

    @Test func privacyListsDefaultExclusionsAndTheSkipList() throws {
        let privacy = try #require(FeatureGuide.sections.first { $0.id == "privacy" }).body
        for p in ["app:Claude", "app:ChatGPT", "app:Cursor", "claude.ai", "chatgpt.com", "chat.openai.com",
                  "app:Alacritty", "app:Ghostty", "app:iTerm2", "app:Terminal"] { #expect(privacy.contains(p), "\(p)") }
        #expect(privacy.contains("Password managers"))
        #expect(privacy.contains("Excluding stops capture and hides past captures; summaries written earlier stay until you forget them."))
    }

    @Test func guideLookupFindsReminders() {
        #expect(FeatureGuide.lookup("rappel reminder").first?.id == "reminders")
        #expect(FeatureGuide.lookup("reminders").first?.id == "reminders")
    }

    @Test func lookupFoldsDiacriticsAndFrenchSynonyms() {
        #expect(FeatureGuide.lookup("résumé du matin").first?.id == "briefs-and-nudges")
        #expect(FeatureGuide.lookup("RESUME").first?.id == "briefs-and-nudges")
        #expect(FeatureGuide.lookup("exclure un site").first?.id == "privacy")
        #expect(FeatureGuide.lookup("oublier").first?.id == "pause-and-delete")
        #expect(FeatureGuide.lookup("dictée").first?.id == "dictation")
    }

    @Test func lookupMatchesIdsExactly() {
        for s in FeatureGuide.sections { #expect(FeatureGuide.lookup(s.id).first?.id == s.id, "\(s.id)") }
    }

    @Test func noTopicGivesContentsAndOverview() {
        for topic in [nil, "", "   "] as [String?] {
            let r = FeatureGuide.lookup(topic)
            #expect(r.map(\.id) == ["contents", "overview"])
            for s in FeatureGuide.sections { #expect(r.first?.body.contains(s.title) == true, "\(s.title)") }
        }
    }

    @Test func unknownTopicFallsBackToContents() {
        #expect(FeatureGuide.lookup("xylophone quasar").map(\.id) == ["contents", "overview"])
    }

    @Test func guideToolReturnsMarkdownWithinCap() async throws {
        let tool = GuideTool()
        #expect(tool.definition.name == "get_remora_guide" && tool.kind == .trustedRead)
        let ctx = ToolContext(now: Date(), calendar: Calendar.current, turnTainted: false, confirm: { _ in false })
        let r = await tool.run(arguments: #"{"topic":"rappel"}"#, context: ctx)
        #expect(!r.isError && r.output.contains("## Reminders"))
        #expect(r.output.count <= GuideTool.outputLimit)
        let all = await tool.run(arguments: "{}", context: ctx)
        #expect(!all.isError && all.output.contains("Overview"))
        let bad = await tool.run(arguments: #"{"topic":5}"#, context: ctx)
        #expect(bad.isError)
    }
}
