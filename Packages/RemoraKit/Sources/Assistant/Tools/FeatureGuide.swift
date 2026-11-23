import Foundation

/// One topic of Remora's built-in guide.
public struct GuideSection: Sendable, Equatable {
    public var id: String
    public var title: String
    /// Markdown.
    public var body: String

    public init(id: String, title: String, body: String) {
        self.id = id; self.title = title; self.body = body
    }
}

/// How Remora works, in its own words, so the chat can explain it (`get_remora_guide`). Written
/// from the design and implementation. The text is static and ships with the app.
public enum FeatureGuide {
    // MARK: Lookup

    /// The sections matching `topic`, best first: section ids, title and body words, and French
    /// synonyms, all case- and diacritic-folded. No topic, or nothing matching: the list of
    /// topics (`contents`) and `overview`.
    public static func lookup(_ topic: String?) -> [GuideSection] {
        let fallback = [contents, sections[0]]
        guard let topic, !fold(topic).isEmpty else { return fallback }
        let whole = fold(topic)
        let words = Self.words(whole).filter { !stopWords.contains($0) }
        var scored: [(score: Int, index: Int)] = []
        for (i, s) in sections.enumerated() {
            var score = whole == s.id ? 100 : 0
            let idParts = Set(s.id.split(separator: "-").map { stem(String($0)) })
            let titleWords = Set(Self.words(fold(s.title)).map(stem))
            let bodyWords = Set(Self.words(fold(s.body)).map(stem))
            for w in words {
                let st = stem(w)
                if idParts.contains(st) { score += 10 }
                if synonyms[w] == s.id || synonyms[st] == s.id { score += 8 }
                if titleWords.contains(st) { score += 4 }
                if bodyWords.contains(st) { score += 1 }
            }
            if score > 0 { scored.append((score, i)) }
        }
        guard !scored.isEmpty else { return fallback }
        return scored.sorted { ($0.score, -$0.index) > ($1.score, -$1.index) }.map { sections[$0.index] }
    }

    /// The list of topics, for a lookup without a topic.
    public static let contents = GuideSection(
        id: "contents", title: "Topics",
        body: "Ask about any of these topics:\n\n" + sections.map { "- **\($0.title)** (`\($0.id)`)" }.joined(separator: "\n"))

    static func fold(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func words(_ folded: String) -> [String] {
        folded.split { !$0.isLetter && !$0.isNumber }.map(String.init).filter { $0.count >= 2 }
    }

    /// A crude plural fold: "reminders" and "reminder", "rappels" and "rappel" meet.
    static func stem(_ w: String) -> String { w.count > 3 && w.hasSuffix("s") ? String(w.dropLast()) : w }

    static let stopWords: Set<String> = [
        "the", "an", "of", "to", "how", "do", "does", "in", "on", "my", "is", "it", "what", "and", "or", "for", "with",
        "can", "you", "me", "about", "le", "la", "les", "un", "une", "des", "du", "de", "et", "ou", "comment", "je",
        "mon", "ma", "mes", "est", "quoi", "pour", "avec", "dans", "sur", "en", "que", "qui", "ce", "ca", "remora",
    ]

    /// French (and a few English) words for each topic, folded.
    static let synonyms: [String: String] = [
        "rappel": "reminders", "rappeler": "reminders", "rappelle": "reminders", "alarme": "reminders",
        "minuteur": "reminders", "recurrent": "reminders", "remind": "reminders",
        "resume": "briefs-and-nudges", "brief": "briefs-and-nudges", "matin": "briefs-and-nudges",
        "soir": "briefs-and-nudges", "bilan": "briefs-and-nudges", "nudge": "briefs-and-nudges",
        "relance": "briefs-and-nudges", "proactif": "briefs-and-nudges", "proactive": "briefs-and-nudges",
        "notification": "briefs-and-nudges", "morning": "briefs-and-nudges", "evening": "briefs-and-nudges",
        "wrap": "briefs-and-nudges",
        "exclure": "privacy", "exclusion": "privacy", "exclude": "privacy", "ignorer": "privacy", "ignore": "privacy",
        "confidentialite": "privacy", "prive": "privacy", "privee": "privacy", "private": "privacy",
        "pause": "pause-and-delete", "suspendre": "pause-and-delete", "oublier": "pause-and-delete",
        "forget": "pause-and-delete", "supprimer": "pause-and-delete", "effacer": "pause-and-delete",
        "delete": "pause-and-delete", "reprendre": "pause-and-delete",
        "dictee": "dictation", "dicter": "dictation", "voix": "dictation", "micro": "dictation", "voice": "dictation",
        "microphone": "dictation", "fn": "dictation",
        "reecrire": "rewrite-key", "reecriture": "rewrite-key", "corriger": "rewrite-key", "rewrite": "rewrite-key",
        "option": "rewrite-key",
        "edition": "edit-mode", "modifier": "edit-mode",
        "question": "ask-in-field", "demander": "ask-in-field", "ask": "ask-in-field",
        "chat": "chat-bar", "barre": "chat-bar", "encoche": "chat-bar", "notch": "chat-bar", "epingler": "chat-bar",
        "pin": "chat-bar",
        "memoire": "memory", "souvenir": "memory", "wiki": "memory", "chronique": "memory", "chronicle": "memory",
        "retention": "memory",
        "identite": "identity", "profil": "identity",
        "mcp": "mcp", "claude": "mcp", "cursor": "mcp", "codex": "mcp", "client": "mcp",
        "usage": "usage", "cout": "usage", "cost": "usage", "jeton": "usage", "token": "usage", "quota": "usage",
        "limite": "usage", "budget": "usage", "prix": "usage",
        "reglage": "settings", "parametre": "settings", "preference": "settings", "setting": "settings",
        "raccourci": "shortcuts", "touche": "shortcuts", "shortcut": "shortcuts", "clavier": "shortcuts",
        "probleme": "troubleshooting", "panne": "troubleshooting", "erreur": "troubleshooting",
        "bug": "troubleshooting", "marche": "troubleshooting", "fonctionne": "troubleshooting",
        "error": "troubleshooting", "broken": "troubleshooting", "beep": "troubleshooting", "bip": "troubleshooting",
    ]

    // MARK: Sections

    public static let sections: [GuideSection] = [
        GuideSection(id: "overview", title: "Overview", body: """
            Remora is a Mac assistant that remembers what you see on screen and helps you write. \
            Everything it captures stays on your Mac, in a local database; only what a task needs is \
            sent to the language model you signed in to (your ChatGPT account).

            - **Rewrite key:** double-tap right ⌥ to rewrite selected text or draft at the caret.
            - **Writing popover:** tap the key. With a selection it opens in Edit; otherwise it opens in Insert.
            - **Ask in a field:** type `/q` and a question, then double-tap the key; the answer replaces it.
            - **Dictation:** hold the rewrite key to talk. The live transcript appears in the writing popover.
            - **Chat bar:** a slim bar under the notch; chat with your memory, set reminders, change settings.
            - **Proactive messages:** a morning brief, an evening wrap and a few nudges a day.
            - **Memory:** background summaries (chronicles), a wiki of people and projects, time per project.
            - **MCP:** other AI apps (Claude, Cursor, Codex) can read your memory, read-only.
            """),
        GuideSection(id: "rewrite-key", title: "Rewrite key", body: """
            Double-tap **right ⌥** by itself while a text \
            field has focus.

            - Field starts with `/q`: Remora answers the question in place (see Ask in a field).
            - Text selected: Remora rewrites the selection.
            - No selection: Remora uses the text before and after the caret to continue a sentence \
              or fill a gap. In an empty field, it drafts from available context.

            A small animated indicator shows at the caret while it works; Esc or a click on it cancels. \
            The field is not touched until the full result is ready, and ⌘Z undoes it in apps that \
            support undo. Double-tap without a focused text field to open chat in supported contexts. Password \
            fields and password managers are refused with a beep. An optional fallback shortcut \
            (⇧⌘G, off by default) and the sounds are in Settings › Shortcuts.
            """),
        GuideSection(id: "edit-mode", title: "Edit mode", body: """
            Select text and tap the rewrite key to open the writing popover in Edit. Type an instruction \
            such as "shorter" or "translate to French", then press Return or choose Rewrite selection. \
            With no selection, the popover opens in Insert. Type what you want written and press Return \
            to draft and insert it at the caret. Where field text must stay on-device, Insert \
            can use ChatGPT with only the prompt you submit. In Edit, the popover stays open for more rounds. \
            Tap the rewrite key to switch modes. Esc or a click outside closes the popover. \
            Configure gestures in Settings › Shortcuts.
            """),
        GuideSection(id: "ask-in-field", title: "Ask in a field", body: """
            In any text field, type `/q` followed by a question, then double-tap the rewrite key. Remora \
            answers using your memory and writes the answer in place of the question. Example: \
            `/q when is the Oslo offsite?`. For a longer conversation, use the chat bar.
            """),
        GuideSection(id: "dictation", title: "Dictation", body: """
            Off by default: turn it on in Settings › Dictation. Hold the rewrite key to speak. The \
            writing popover shows the live transcript using your Mac. Release to review the final \
            text in Insert mode. Press Return to draft from the spoken prompt, or choose Insert transcript \
            to put the words into the field. Switch to Edit to apply a spoken instruction to existing text. \
            Esc discards the draft. For hands-free dictation, choose Record and Stop.

            For Mac speech recognition, pick English or French in the menu bar or let Remora use \
            the last language in that app or your default. The popover also offers a language button \
            when OpenAI transcription is off. With a saved key, OpenAI detects the language in eligible \
            unchanged recordings after you choose Insert transcript. Cleanup can also run after that \
            choice. Drafting and editing use the reviewed text.
            """),
        GuideSection(id: "chat-bar", title: "Chat bar", body: """
            A slim bar docked at a screen edge, under the notch by default. Hovering expands it (can be \
            turned off), a click toggles it, and it can be pinned open and resized. Positions: top, \
            left, right, bottom, bottom-left and bottom-right; it can auto-hide or dim when not in \
            use; text size 100–150 % (Settings › Appearance). With hover off, click the bar, use Open \
            chat in the menu bar, or double-tap the rewrite key outside a text field.

            In the chat you can ask about anything you have seen ("what did Ana say about pricing \
            yesterday?"), how you spent your time, or how Remora works. The chat can also act when you \
            ask: create, list and cancel reminders, add an exclusion, pause capture, update your \
            identity, change a setting, or correct a wiki fact. It asks before acting when the request \
            is risky or when it has just read captured text (which anyone may have written). It never \
            removes an exclusion: do that in Settings › Privacy. Most actions can be undone from the \
            message. Use Edit below your latest message to revise it and send again; Cancel keeps \
            the original exchange. Editing does not undo completed actions. Chat history stays on \
            your Mac (90 days); long conversations are summarized.

            Ask “What routines have you noticed?” to see possible recurring work with dates and window titles. \
            You can ask to rename or dismiss a suggestion. If it fits, ask for a draft in chat or give Remora a \
            recurring prompt and a schedule. With Background memory and Proactive messages on, Remora checks \
            for new routines weekly after \(RoutineScanRunner.historyDays) days of history and posts findings in chat.
            """),
        GuideSection(id: "reminders", title: "Reminders", body: """
            Ask the chat: "remind me to call Ana tomorrow at 9", "every Monday at 10 remind me to send \
            the report", or "every 30 minutes remind me to stretch".

            - **One-off:** a date and time, up to two years ahead.
            - **Recurring:** daily, weekly, monthly…; it keeps its local wall-clock time across time \
              zone and daylight-saving changes.
            - **Interval:** every N minutes (at least 5 minutes).

            A reminder arrives as a chat message and as a macOS notification (when macOS allows \
            Remora's notifications), even while proactive messages are off: reminders are yours, so \
            they always notify. A "prompt" reminder runs a question through \
            the chat, read-only, e.g. "summarize what I did this morning"; on an interval, its firings are at \
            least 60 minutes apart. If your Mac was asleep, a missed reminder fires once, late, then keeps \
            its schedule. Up to 50 active reminders. List or cancel them by asking the chat.
            """),
        GuideSection(id: "briefs-and-nudges", title: "Briefs and nudges", body: """
            Proactive messages are on by default (Settings › Notifications).

            - **Morning brief** at 08:00: yesterday and today's focus. Missed (Mac asleep), it comes \
              when you wake the Mac, until noon; after that it is skipped.
            - **Evening wrap** at 16:00: what moved, what is still open, time per project. Delivered \
              until midnight.
            - **Nudges:** short reminders about something that looks open, such as an unanswered \
              commitment. At most 3 a day, at least 90 minutes apart, only between 09:00 and 19:00, \
              never while you are away or sharing your screen, and never twice for the same thing.

            Each message is written, then checked against your captured evidence and the clock, and \
            rewritten once or not sent. They arrive in the chat and as a macOS notification (a brief \
            that lands while you are sharing your screen stays in the chat, without a notification). \
            They need background memory (Settings › Memory) and pause with the usage limit. \
            Turning proactive messages off stops briefs and nudges only; reminders still arrive in the \
            chat and still notify.
            """),
        GuideSection(id: "memory", title: "Memory", body: """
            Remora captures the text of the window you are looking at (and copied text), then builds \
            memory in the background (Settings › Memory):

            - **Chronicles:** summaries per hour, day, week and month.
            - **Wiki:** pages about the people, projects and topics you deal with, with facts that cite \
              their source captures.
            - **Working memory and open items:** what you are in the middle of, commitments, deadlines.
            - **Time ledger:** focus time per project, from your time rules.

            Background memory can be turned off; its language (English or French) and how long raw \
            captures are kept (30 days by default; older captures are deleted once summarized unless a \
            wiki fact or open item cites them) are set there too, with a wiki browser and chronicles by \
            day. Background memory pauses when your plan's usage limit is reached and tries again \
            later.
            """),
        GuideSection(id: "identity", title: "Identity", body: """
            A short profile of you (role, projects, people you work with, how you write) that Remora \
            uses for rewrites and the chat. It is learned from your memory and you can edit it any time \
            in Settings › Identity, or ask the chat to update it (it asks first). Your edits are kept: \
            Remora does not rewrite them on its own. After you forget captures, check whether the \
            identity still mentions them.
            """),
        GuideSection(id: "privacy", title: "Privacy and exclusions", body: """
            Captured text stays on your Mac. Card numbers, IBANs, social security and tax numbers, API \
            keys, tokens, private keys and passwords are replaced by `[redacted]` before anything is \
            saved. Names, emails and phone numbers are kept.

            **Never captured (built in):** Password managers, password fields, banking sites, and \
            private or incognito browser windows. This list cannot be changed.

            **Exclusions** (Settings › Privacy, or the capture dot in the menu bar): one per line, \
            case-insensitive.

            - `example.com`: a site and its subdomains.
            - `app:Name`: an app, e.g. `app:Slack`.
            - `title:text`: windows whose title contains the text.
            - `url:text`: pages whose address contains the text.
            - `path:text`: documents whose file path contains the text.

            Default exclusions, added once and removable: `app:Claude`, `app:ChatGPT`, `app:Cursor`, \
            `claude.ai`, `chatgpt.com`, `chat.openai.com`, `app:Alacritty`, `app:Ghostty`, \
            `app:iTerm2`, `app:Terminal` (AI chats would capture Remora's own answers, and terminals \
            can show secrets). Excluding stops capture and hides past captures; summaries written \
            earlier stay until you forget them. Automatic context from excluded and private windows \
            stays out of model requests. The chat can add an exclusion but never removes one.
            """),
        GuideSection(id: "pause-and-delete", title: "Pause, forget and delete", body: """
            **Pause** capture for 15 minutes, 1 hour, until tomorrow (08:00) or indefinitely, from the \
            menu bar, Settings › Privacy or the chat. While paused nothing is captured, and the \
            rewrite key sends only the field's text.

            **Forget** specific captures by asking the chat ("forget what you saw in …"): they are \
            deleted, and what memory derived only from them goes too. Forgetting a capture also stops \
            Remora from reusing earlier chat messages in new answers; Clear chat removes them from view.

            **Delete all data** (Settings › Privacy, type "yes" to confirm) permanently deletes every \
            capture, the activity history, chronicles, wiki, identity, chat history and reminders, and \
            clears Remora's notifications from Notification Center. It also deletes saved notes and imported \
            meetings and disconnects meeting sources. Exclusions and most preferences are kept. This cannot be undone.
            """),
        GuideSection(id: "mcp", title: "MCP (other AI apps)", body: """
            `remora-mcp` lets AI apps read your Remora memory: search captures, read snapshots and \
            sessions, recent activity, chronicles, working memory, attention context and the wiki. It \
            is read-only and works whether or not Remora is running. Results are captured text and \
            are marked as untrusted data for the client.

            Settings › MCP lists Claude Code, Claude Desktop, Cursor and Codex with their status and a \
            **Connect** button (**Update** when another copy of Remora is registered, **Disconnect** \
            when connected). It uses the client's own command line tool when there is one; otherwise \
            Remora edits only its own `remora` entry in the client's config and keeps a backup next to \
            the file. A config it cannot edit safely is left untouched with an explanation. Restart \
            the client after a change. The copy snippets under "Other apps" work for any other client.
            """),
        GuideSection(id: "usage", title: "Usage and cost", body: """
            Remora uses your ChatGPT plan through Sign in with ChatGPT (Settings › Account). Settings › \
            Usage covers Today, 7 days or 30 days: estimated cost, calls, tokens and problems, a chart of \
            estimated cost by category, a breakdown by job or by model, and a live log of model calls \
            where selecting a call shows its tokens, model, duration and cost. Costs are API-equivalent \
            list prices, not a bill. Your real allowance is at chatgpt.com/settings/usage. Background \
            memory pauses when the plan's usage limit is reached and tries again later. Each answer's \
            details show the model, tokens and estimated cost.
            """),
        GuideSection(id: "settings", title: "Settings", body: """
            Settings pages:

            - **General:** open at login, Show onboarding again (includes a box to try the rewrite key).
            - **Account:** sign in or out of ChatGPT, models.
            - **Usage:** estimated cost, calls and tokens, with a live log of model calls.
            - **Privacy:** Accessibility and Microphone permissions, exclusions, pause, Delete all data.
            - **Appearance:** chat bar position, open on hover, auto-hide, dim, text size, the per-window capture badge.
            - **Identity:** edit your profile.
            - **Memory:** background memory, language, retention, wiki and chronicles, time rules, saved notes.
              Select text, tap right ⌥, choose **Remember this** and review it before saving. Ignored apps
              and sites need **Manual saves only** in Privacy. You can also paste, search or delete
              notes in Memory. Optional chat access can send relevant excerpts to OpenAI.
            - **Notifications:** proactive messages on or off, macOS notification permission, a test notification.
            - **Shortcuts:** rewrite key, Edit mode, fallback shortcut, sounds.
            - **Dictation:** on or off, language, optional OpenAI transcription, cleanup.
            - **Meeting sources:** connect Quill, Granola or a compatible local server, and search or \
              forget imported meetings. Optional chat access lets Remora send relevant excerpts to OpenAI.
            - **MCP:** connect, update or disconnect AI apps.
            - **Logs:** open the logs folder, export the last 24 hours, open Console. Logs never contain captured text, prompts or answers.

            The chat can change some settings when you ask (it tells you what changed and offers undo).
            """),
        GuideSection(id: "shortcuts", title: "Shortcuts", body: """
            - **Right ⌥ tap:** open the writing popover in Edit for a selection, or Insert at the caret.
            - **Right ⌥ double-tap:** rewrite the selection, draft at the caret, or answer `/q`. Opens chat outside a text field.
            - **Right ⌥ hold:** dictate into the popover in Insert when dictation is on.
            - **Right ⌥ tap in the popover:** switch between Insert and Edit.
            - **⇧⌘G:** fallback shortcut, off by default (it is also Find Previous in many apps).
            - **Esc:** cancel a rewrite or close Edit mode.

            Change them in Settings › Shortcuts. Quit Goldfish while using Remora: both use right ⌥.
            """),
        GuideSection(id: "troubleshooting", title: "Troubleshooting", body: """
            - **The key beeps:** the field is a password field or a password manager, or the app is not \
              responding. Remora also needs Accessibility (Settings › Privacy › Re-grant).
            - **Nothing happens on the key:** check Settings › Shortcuts, and that another app (e.g. \
              Goldfish) is not using right ⌥.
            - **Not capturing an app:** the capture dot in the menu bar says why (excluded, private \
              window, password manager, paused).
            - **"Usage limit reached" or plan unavailable:** your ChatGPT plan's limit; Remora retries \
              later. See Settings › Usage and Account.
            - **No morning brief:** proactive messages or background memory are off, there was no \
              capture in the last 3 days, or it was past noon when the Mac woke.
            - **No notifications:** check Settings › Notifications: macOS notifications must be allowed \
              (and proactive messages on, for briefs and nudges); "Send a test notification" checks the \
              path.
            - **MCP client sees nothing:** open Remora once so the database exists, then reconnect from \
              Settings › MCP and restart the client.
            - **Dictation does not start:** turn it on in Settings › Dictation, grant the microphone, and \
              let the speech model download.
            - Logs (Settings › Logs) record codes and timings only, never content.
            """),
    ]
}
