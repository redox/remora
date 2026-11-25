# Remora design

Remora is a native macOS menu-bar app that remembers what you work on and brings that memory into
writing, chat, and other AI apps. The starting point was Goldfish's implicit memory: a rewrite
can sound like you and a question can draw on prior work without first asking you to find and
attach the evidence. Remora is an independent Swift implementation built around one person's
machine, data, and ChatGPT account. [Prior art](research/prior-art.md)

This document records the decisions that govern Remora today. When one changes, update its
rationale and the trade-off along with the implementation. The original milestone plans and
review notes are available in Git history.

- [Scope and architecture](#scope-and-architecture)
- [Capture and privacy](#capture-and-privacy)
- [Models and usage](#models-and-usage)
- [Storage and memory](#storage-and-memory)
- [Writing and dictation](#writing-and-dictation)
- [Chat and proactive help](#chat-and-proactive-help)
- [MCP and meeting sources](#mcp-and-meeting-sources)
- [Installation and updates](#installation-and-updates)
- [Verification](#verification)

## Scope and architecture

**Keep the account, runtime, and database with the user.** Remora has no hosted backend, telemetry,
crash reporting, account system, or cross-device sync. Normal cloud inference uses Sign in with
ChatGPT, so each user draws from their own plan. The user controls capture, can inspect memory
in Settings, and can forget individual material or delete the entire store. The trade-off is
that history is machine-local and model features depend on the account and network. The optional
dictation and meeting integrations have their own explicit controls. [Privacy policy](../PRIVACY.md)

**Use one app process and a small read-only companion.** The app owns capture, storage writes,
background jobs, global shortcuts, UI, and sign-in. The bundled `remora-mcp` executable reads the
same SQLite file and can answer after the app quits. A dedicated capture daemon would survive a UI
crash but add another process, a local protocol, and lifecycle coordination. Capture pauses if the
app exits. The package boundary leaves room for a later split if that cost becomes significant.

**Build for macOS 26 and later with native frameworks.** SwiftUI handles views, AppKit owns the
panels and focus, and `RemoraKit` contains the policy and pipelines so they can be tested without
launching the app. Swift 6 strict concurrency enforces the handoffs. XcodeGen keeps the checked-in
project definition reviewable and the build runnable from the CLI. GRDB manages SQLite, the MCP
Swift SDK supplies the protocol, and Sparkle provides signed updates. Apple frameworks cover
Accessibility, speech, embeddings, and local inference. Windows, a desktop pet, and importing
Goldfish's database are outside the product scope. Remora has its own artwork and identity.
[Project definition](../project.yml) · [Package](../Packages/RemoraKit/Package.swift)

## Capture and privacy

**Read the frontmost window through Accessibility.** A bounded tree walk can extract useful
text and browser context without screenshots, OCR, or Screen Recording permission. Activation,
debounced Accessibility notifications, and a five-second poll cover both responsive and sparse
Accessibility trees. Chromium and Electron may need an app-specific opt-in to expose their
trees. Idle, locked, sleeping, and paused states stop capture. The target is below 3% average CPU.
Accessibility quality varies by app, and hidden content and screen pixels are outside this
capture path. [Capture observations](research/capture-matrix.md)

**Keep cross-app IPC off the main actor.** All calls into another app's Accessibility tree use
one serial `AXQueue` with per-element timeouts and bounded reads. An unresponsive target
ends that read. Remora's own practice field is routed to the main thread because its AppKit
text system executes in-process. These rules trade occasional missed captures for a responsive
menu and predictable text input.
[Accessibility guidance](../.claude/skills/remora-accessibility/SKILL.md)

**Attribute copied text to a recently verified window.** Clipboard capture observes change counts
and skips concealed and transient items. Missing or stale attribution drops the copy. Screen
text is redacted, stripped of learned interface clutter, and deduplicated. A rolling capture can
extend the same evidence through subsequent focus intervals, avoiding rows for unchanged text.
Focus events are retained separately because returning to a window is meaningful even if the
text is identical. Clutter is learned per app or site from repeated short lines, with digits
and longer lines protected so the heuristic is less likely to swallow dates or prose.

**Fail closed on sensitive or unverifiable contexts.** Secure fields, password managers, private
windows, and built-in sensitive pages are refused for capture. Unreadable exclusion settings
deny all capture and evidence reads. User rules match case-insensitive domains and subdomains,
or `app:`, `title:`, `url:`, and `path:` patterns. Default exclusions cover AI chat apps and sites
and common terminals. Recapturing an MCP answer can feed it back into the same memory, and
terminals often expose secrets. The seeded rules can be removed in Settings. An exclusion also
filters old raw captures from automated use, while forgetting is the operation that removes them.

**Redact on the Mac before persistence.** The shared redactor covers card numbers, IBANs, personal
identifiers including French social security and labeled tax numbers, and common credential
formats. Checksums, known prefixes, and context labels reduce false positives. Names, email
addresses, and phone numbers remain useful to personal memory and are retained. Heuristics
are a second line of defense after capture policy. Logs carry events, counts, enum cases, and
error codes, with no user content or credentials.
[Redaction code](../Packages/RemoraKit/Sources/Redaction) · [Privacy guidance](../.claude/skills/remora-privacy/SKILL.md)

**Make capture status visible where it can be changed.** The menu-bar mark shows a filled sea-glass
dot when the active window is eligible, a ring when it is excluded, and distinct pause and permission
states. On a window switch, the mark updates quietly.
Opening the menu shows the current capture status. The optional title-bar badge is off by
default and uses a small non-activating panel, hidden during moves, full screen, and detected
screen sharing. It uses the same Remora mark as the menu bar, tinted sea-glass for eligible windows
and gray for excluded windows. Both surfaces offer exclusion and pause controls. Status reflects
capture policy and tells the user where capture is allowed. Screen-sharing detection is best effort
from window metadata so it can work without Screen Recording permission.

## Models and usage

**Use the system browser for Sign in with ChatGPT.** OAuth uses PKCE, state, nonce, and an IPv4
loopback callback. The issued client identity and session are stored in the Keychain. ID tokens
are verified and refresh is coordinated across calls, honoring the server's earliest refresh
time. For inference Remora uses the streaming Responses endpoint, sends history in `input` and
instructions in `instructions`, and sets `store: false` and `stream: true`. A completed event
establishes success. Failures, including
usage limits, can arrive after the stream opens. The client keeps the preview protocol and
supported fields isolated from the rest of the app. [Sign-in documentation](https://developers.openai.com/siwc/token-sharing-open-source) · [Local experiments](research/siwc-spike.md)

**Route by job and by the privacy of its source.** Small jobs such as working memory, query
expansion, dictation cleanup, hour summaries, and evidence checks default to the small tier
(Luna). Rewriting, chat, longer summaries, and synthesis default to the large tier (Terra).
Settings allows tier and job overrides. Apple Foundation Models supplies the on-device tier.
Background work and rewrites request low reasoning effort, while chat uses the model default.
The small tier follows the newest Luna in the account's visible catalog. A missing model
preference falls back within its family when possible and surfaces the change in Settings.
[Job types](../Packages/RemoraKit/Sources/LLM/Core/JobType.swift) · [Model resolution](../Packages/RemoraKit/Sources/LLM/Models/ModelResolver.swift)

| Writing context | Input allowed | Route |
| --- | --- | --- |
| Verifiable and eligible | Field, permitted window context, and relevant memory | Configured tier |
| Capture paused, context otherwise eligible | Field only, with no writing history recorded | Cloud allowed |
| Excluded, private, or unverifiable | Field only, with no writing history recorded | On-device only for field operations |
| Draft and insert where field text must stay on-device | Only the submitted prompt, with no writing history recorded | Configured tier |
| Secure field, password manager, or vault page | Writing is refused | None |

A forced on-device request fails with a notice if the model is unavailable or cannot handle the
input. Ordinary pause suppresses passive capture and contextual recall while preserving deliberate
field-only editing. The more restrictive rule wins when conditions overlap. The separate opt-in
for audio transcription has a stricter gate. [Privacy guidance](../.claude/skills/remora-privacy/SKILL.md)

**Account for every model call and let usage-limit backoff be the only throttle on background
work.** Every call is recorded in `llm_calls` with model, token and status metadata and an
API-equivalent cost estimate from a local, overridable price table. Linked artifacts can show
their call provenance. Background cloud work has no budget of its own: its only throttle is
usage-limit backoff, where a usage-limit error postpones background jobs with exponential
backoff until a cloud call succeeds again. The user can cap Remora's share of the plan in
ChatGPT › Settings › Usage. The trade-off is that background work can use the whole allowance,
after which rewrite and chat also hit the limit until it resets; an earlier daily token budget was
removed because it throttled memory far below what the plan allowed. The stored
`memory.dailyTokenBudget` row, if any, is ignored.
[Price table](../Packages/RemoraKit/Sources/LLM/Service/PriceTable.swift)

**Show what the model calls are doing as a dashboard over a live call log.** Settings › Usage
shows, for today, 7 days or 30 days, the estimated cost, calls, tokens and problems, a chart of
cost per hour or day by category (writing, chat, memory, briefs and nudges), a breakdown by job
or model that filters the log, and a live log that updates as calls land. The pane observes
every call in the range, so totals are exact; only the log table stops at the newest 5,000
matching rows, and says so. Selecting a call shows its tokens, effort, backend, duration, error code, what kind of item
it produced and the cost calculation at the current price table's rates. `llm_calls` holds
accounting only, so the pane never shows prompt or output text. Every surface (this pane, MCP
`usage`, provenance) reads the stored `est_cost_usd`, so they agree; calls recorded while their
model had no price are backfilled with the current table at launch and whenever the pane opens,
and a stored cost is never rewritten. The trade-off is that a call's cost uses the prices in force
when it ran, or at its first backfill, so editing a price does not reprice history; the detail
block's calculation, which uses today's rates, can then differ from the stored cost. "≥" and a
footnote mark totals that still include unpriced calls.
[Usage dashboard](../Packages/RemoraKit/Sources/LLM/Presentation/UsageDashboard.swift)

## Storage and memory

**Keep the store inspectable and searchable with SQLite.** The database lives under
`~/Library/Application Support/Remora` and uses WAL so the app can write while MCP reads. At-rest
protection relies on FileVault when enabled, and the application database is plain SQLite.
Credentials use separate Keychain items. FTS5 uses accent-insensitive Unicode tokenization and
prefix indexes, so a French query can omit accents.
Search avoids English-only stemming. Migrations are append-only so existing installs upgrade
deterministically. [Storage guidance](../.claude/skills/remora-database/SKILL.md)

**Make memory progressively cheaper to consult.** Short-lived working memory captures recent
salient context. Hour chronicles summarize bounded, deduplicated evidence and extract entities
and flags. Days build on hours, weeks and months build on days, and years build on months. The
wiki keeps sourced facts with validity intervals so a changed fact can supersede an older one.
A time ledger uses observed focus intervals and user rules. Identity and per-surface style
notes consolidate more slowly, with user identity edits taking precedence. A compact digest
gives rewrite and chat a starting point. Memory can be written in English or French, with names,
titles, and evidence quotes in their original language.

**Use a persistent, idempotent job queue.** A job is keyed by kind and local period, so repeated
planning converges and wake or restart can catch up. Sparse consecutive hours can merge within
a day until the span reaches four hours or at least ten minutes of focus. This avoids spending a call on each
brief visit. Backlog is handled oldest first. Idle and power gates keep heavy
work out of the user's way. Dirty parent summaries are requeued when children change. Weeks,
months, and years trace their sources through child chronicles, which keeps provenance from
repeating every raw ID at each level.
Structured model responses are checked and capped in code. An hour can retain its summary
while entity extraction retries independently. Commits recheck evidence that could have changed
during inference. Automatic maintenance and **Run now** share the queue, so a manual run still
respects privacy and account backoff.
[Scheduler](../Packages/RemoraKit/Sources/Memory/Scheduler) · [Pipelines](../Packages/RemoraKit/Sources/Memory/Pipelines)

**Use two complementary kinds of search.** FTS5 handles exact terms and raw captures. Apple's
multilingual `NLContextualEmbedding` adds semantic search over chronicles and wiki content.
Vectors are revisioned float32 blobs and searched by cosine similarity. Reciprocal-rank fusion
combines ranked lists without comparing incompatible scores. A local scan avoids a service or
vector extension and is sized for a personal database. FTS remains available without embedding
assets. Rewrite assembles bounded context from current text, style, identity, recent memory, and
retrieved evidence. Chat and MCP expose tools so callers can drill down when needed.
[Retrieval](../Packages/RemoraKit/Sources/Retrieval) · [Embeddings](../Packages/RemoraKit/Sources/Embeddings)

**Keep provenance through retention.** Nightly compaction refreshes boilerplate statistics,
consolidates stale or duplicate memory, rolls up dirty periods, rebuilds the digest, indexes
changed summaries, and maintains SQLite. Raw capture retention defaults to 30 days and can be
set to 7–365 days or forever. An expired capture can be pruned after clean hour chronicles
cover its recorded span and no wiki fact or open item cites it. Uncovered, uncited captures
excluded by current rules can also expire. Retention keeps derived text and leaves minimal
source tombstones for filtering. Tombstones can deny
access, and only live allowed evidence can outweigh a known denial. Mixed-source summaries
can still carry older context when a live source remains allowed. Working memory applies the
stricter live-evidence rule. [Retention](../Packages/RemoraKit/Sources/Storage/RetentionStore.swift) · [Derived evidence policy](../Packages/RemoraKit/Sources/Retrieval/DerivedPolicy.swift)

**Give explicit deletion stronger semantics than retention.** Forget cascades from deleted
captures, dirties affected summaries, withholds the digest until it can be rebuilt, and advances
a watermark so old chat turns and folds stay out of model replay. That can withhold unrelated
chat context, and older turns remain visible locally until cleared. Delete all removes captured
and derived data, chat, reminders, notifications, notes, and meeting imports. It preserves
preferences such as exclusions and content-free usage metadata. The deletion transaction bumps
`DataGeneration`, so a slow job cannot repopulate the cleared store. Secure deletion, FTS cleanup,
vacuuming, and WAL truncation scrub the files, with retry on next launch if cleanup is pending.
[Data reset](../Packages/RemoraKit/Sources/Storage/DataReset.swift)

## Writing and dictation

**Use one rewrite key with distinct gestures.** A clean right Option tap opens Edit for a
selection and Insert at the caret. Double-tap rewrites the selection or writes at the original
caret. A field starting with `/q` gets an answer in place. Hold previews dictation when enabled,
and a tap inside the popover switches modes. A clean gesture rules out other key or mouse input
so ordinary Option typing, including on AZERTY, stays intact. The optional Shift-Command-G
fallback is off by default because apps assign it other meanings. No gesture requires Input
Monitoring.

In Edit, a short instruction applies to the selected passage, or to the field when there is no
selection. For example, “in French” requests a translation of the passage with its line breaks.
When Google Docs in a Chromium browser exposes only a selected range in its blank input proxy,
Edit temporarily copies the selection and checks the clipboard’s source URL against the document.
Before pasting, it checks the document, range and copied text again. The paste replaces the
active selection and the popover closes. Docs handles Undo because the proxy cannot track the
replacement for another round. If Remora cannot verify the passage, it leaves the field alone.

**Anchor the Google Docs popover to text geometry when available.** In Chrome, Docs moves its
input frame to the visible caret when **Turn on screen magnifier support** is enabled in
**Tools › Accessibility**. Use the top-left corner of that frame after verifying it belongs to the
focused document and sits inside its viewport. Also use reported selection and caret bounds when
available. Fall back to the mouse pointer when Docs exposes no usable text geometry.

**Keep the writing overlay near the active text.** Place the measured popover beside an ordinary
composer when it fits. In a full-height editor, prefer the caret. If text bounds are unavailable,
use the pointer in the field or the field centre.

Ghostty can report an empty selection at offset zero while the terminal cursor is several rows
down. Use reported cursor or selection bounds when available. Apply the same pointer or pane-centre
fallback even in a small split because its frame describes the whole terminal surface.

**Draft from typed or spoken prompts in Insert.** Submit a typed prompt or reviewed transcript
to generate text for the original caret or selection. Insert treats rough notes as a brief and
develops them into a draft for the audience and format suggested by the available context. It
preserves finished wording supplied for direct insertion and grounds facts and commitments in
the prompt and available context. Existing text outside the target stays in place. Insert uses the
Edit mode model settings and checks that the target is safe to write to. In places where field text
must stay on-device, Draft and insert sends just the submitted prompt with the drafting guidance.
It uses the field locally to verify the insertion target. A failed draft leaves the prompt in the
popover for retry. Insert transcript puts the user's words into the field using dictation settings.

**Finish the result before touching the target.** The original focused field, its text, and the
selected range or caret are checked before applying a result. In a populated field, an unreadable
or moved caret cancels a direct insertion. The working mark is cancellable and stays clear of
the text. Native fields get a verified Accessibility write where possible. Web fields favor
paste. The paste fallback snapshots all pasteboard types, sends a layout-aware paste, and restores
the prior contents once the target has had time to read them, provided the user has not copied
something else. The command bar stays open for repeated edits and respects marked text during
IME composition. When allowed, later field observations help distinguish kept and revised
writing for style learning. [Insertion guidance](../.claude/skills/remora-accessibility/SKILL.md)

**Preview dictation locally and act on an explicit choice.** Dictation is off by default.
Apple's SpeechAnalyzer and SpeechTranscriber show live words using one locale per session.
English and French are selectable, with the last-used locale per app as a convenience. Running
one locale keeps latency and resource use down at the cost of an explicit switch for bilingual
speech. The command bar offers the language switch when OpenAI transcription is off and shows
Listening once microphone audio starts arriving. This gives Bluetooth inputs time to connect before
the user starts speaking.
Recording errors appear in the command bar so the user can retry in place. Release or Stop leaves
the text in the command bar. Insert transcript can clean up an unchanged draft, and edits to the
preview are kept as typed. Draft and insert and Edit use the reviewed text as an instruction.
Cancelling discards the recording. Audio stays in memory and spoken edit instructions are
excluded from stored instructions.

**Make cloud transcription a separate opt-in.** A user-supplied project key enables
`gpt-transcribe` for an eligible unchanged recording after the user chooses Insert transcript. This
uses the project's transcription endpoint and billing because the ChatGPT sign-in route is
for text inference. OpenAI detects the language from the bounded audio. Cleanup preserves each
part of the resulting transcript in its original language. The Mac's locale still controls the
live preview and fallback. The foreground context must remain verifiable and allowed throughout.
Pause, secure input, and context switches prevent an upload. Drafting and editing use the reviewed
text. Apple's transcript is available if the request fails.
[Dictation privacy](../PRIVACY.md#dictation)

**Save selected excerpts as deliberate notes.** **Remember this** opens an editable preview before
**Save to memory**. If an otherwise eligible source exposes no verifiable selection, the preview
allows explicit paste. An app or domain exclusion can allow manual saves while continuing to
block capture. All matching exclusions must permit the save, and pause, built-in refusals, and an
unverifiable window still block the selection path. Settings supports deliberate pasting directly.
A separate redacted index keeps notes out of capture retention, background jobs, and MCP. Chat
search is interactive, off by default, and disabled during capture pause. Note-backed replies
stay out of folding, including replies that inherit notes from earlier turns. Turning access off
or deleting a note while it is enabled advances the replay watermark.
[Saved note storage](../Packages/RemoraKit/Sources/Storage/SavedNoteStore.swift)

## Chat and proactive help

**Keep chat close to the current work.** The bar sits below the notch or at the top center, with
other screen-edge positions, pinning, resizing, and 100–150% text sizing. The compact hover panel
and expanded card use matching frame and content geometry at each transition so controls stay
clear of the camera housing, including with a hidden menu bar. Mouse delivery is set explicitly
because transparent borderless windows can otherwise pass scroll gesture starts through. Native
selection colors, Reduce Transparency, Increase Contrast, and Reduce Motion guide the overlay
surfaces. Composer focus uses a neutral outline that follows the field's rounded shape, with
stronger contrast when Increase Contrast is enabled. The visual identity uses the app's own
fish mark and sea-glass accents.

**Stream answers over bounded local history.** Chat tools read memory, inspect sources, and report
activity. Long conversations are folded into a shorter summary, and local chat history is kept
for 90 days. Editing the latest question replaces its exchange atomically and preserves action
receipts and later inbox deliveries. This
lets a question be corrected without falsely implying that completed work was undone.

**Follow the reply while the reader is at the end.** Chat opens at the latest message, or at
the welcome heading in a new conversation. Sending brings the question into view immediately
and keeps the reply in view as it grows. Scrolling up preserves the reading position during
streaming. Scroll back down or choose **Latest** to resume following the reply. Notification
clicks open the corresponding message.

**Treat observations as untrusted input and keep ownership of actions with the user.** Captures,
clipboard text, imported text, memory, and tool results are escaped into tagged data sections.
A turn that has read untrusted content is tainted, including through replay. It requires a visible
confirmation for any action. Higher-risk actions always require confirmation. The Allow button
has no keyboard shortcut. Reversible operations can offer undo, and removing exclusions stays in
Settings. Scheduled prompt reminders execute with read-only chat tools. Financial, credential,
code, and link instructions found in screen evidence are barred from proactive messages.
[Tool trust and prompt guidance](../.claude/skills/remora-llm/SKILL.md)

**Make proactive messages infrequent and evidence-backed.** The morning brief is scheduled at
08:00 with catch-up until noon. The 16:00 wrap can catch up until midnight. Nudges are capped
at three per day, at least 90 minutes apart. Briefs and nudges are generated, checked against
observations and the clock, and rewritten once or withheld. Screen sharing can suppress a
system banner. Reminders are user-owned
and can still notify when proactive messages are off. One-off, wall-clock recurring, and interval
reminders catch up a missed occurrence once. Prompt reminders wait out a usage-limit backoff.
Notification permission is requested in context, and the content-free nudge rate limit survives
delete-all.

**Infer routines from focus visits and make suggestions tentative.** The detector looks for an
ordered pair of distinct named windows visited within 45 minutes on at least three days of the
last 28. A visit needs ten seconds of observed focus. It uses focus history, so deduplication
does not erase repeat visits. Location rules and pre-forget events require supporting live
capture evidence. Chat can report the observations
on request. With background memory and proactive messages enabled, an idle weekly scan can
post up to three new findings after seven days of history. It runs locally with no model call
or system banner, and its cards stay out of chat replay and folding. Feedback and dismissal are
explicit. Users can ask for a draft or set a separate prompt and schedule. Changing window titles
or staying in a single window limits what the detector can find.

## MCP and meeting sources

**Expose a bounded, read-only MCP interface over stdio.** Client tools use the same evidence
policy as the app and can search captures, activity, chronicles, and the wiki. The connection
opens an existing database in read-only mode with `query_only`. The immutable fallback is safe
only when there are no WAL frames to omit. Registration is explicit in Settings for Claude Code,
Claude Desktop, Cursor, and Codex. Changes back up and edit only Remora's entry, and unfamiliar
config formats or ambiguous CLI scopes are refused. A copyable command supports other clients.
Once a client reads the results, its own data-handling rules apply.
[MCP server](../Packages/RemoraKit/Sources/MCPServer) · [Client registration](../Packages/RemoraKit/Sources/ClientConfig)

**Import meetings as their own library.** Meeting dates, updates, and deletion semantics differ
from screen captures, so transcripts and generated notes have their own redacted index.
Quill and compatible servers use loopback Streamable HTTP. Granola uses fixed HTTPS origins,
PKCE, and a separate Keychain item. The adapter uses explicit read operations and supported input
shapes. Provider-supplied descriptions do not select operations. Sync checks pause and current
exclusions, upserts by provider ID, and runs every 15 minutes with a two-day overlap to catch
late edits. Manual sync can revisit older meetings, within provider coverage. Forget marks prevent re-import.
Chat needs separate opt-in to send bounded excerpts. Revocation, forget, and disconnect withhold
earlier chat replay, and delete-all removes the imports and source connections. Provider-side
edits outside the sync window or provider deletions can require manual cleanup.
[Meeting import](../Packages/RemoraKit/Sources/MeetingImport) · [Privacy policy](../PRIVACY.md#where-it-is-stored-and-for-how-long)

## Installation and updates

**Give the installed copy a stable identity.** Accessibility and Microphone grants follow the
code signature, so Debug builds can use a stable Apple Development identity. AX and event taps
run in an unsandboxed app with hardened runtime. A launch gate avoids two copies contending for
the database, global keys, login item, and MCP registrations. An out-of-place copy offers to move
to Applications, refuses to downgrade a newer copy, and tries to restore the prior copy if the
move fails. Only installed copies can register the login item and MCP clients. Onboarding explains
capture and permissions, offers sign-in, and provides a practice field before optional dictation
and notification setup. [Contributing](../CONTRIBUTING.md)

**Show the install action in Finder.** The DMG opens in a compact icon view with Remora on the
left, Applications on the right, and a Retina background that shows the direction of the drag.
The release packages a Finder layout and background so the build runner can create the same
installer without a desktop session. [Releasing](releasing.md)

**Ship signed releases with verified updates.** Remora is MIT-licensed. Releases use a Developer
ID signature, notarized DMG, and a Sparkle feed on GitHub Releases. The feed and EdDSA public key
are configuration, and the updater lives outside database initialization so updates work if the
database fails to open. A ready installed copy can update on quit or after idle, with busy checks
covering writing, dictation, deletion, memory jobs, onboarding, and streaming chat. The trade-off
is that an active session can delay an update. A successful CI run on `main` starts signing when
the configured version is unpublished. GitHub publishes the verified installer and Sparkle feed
from that exact commit, then refreshes the website. A release uses a build number greater than all
previously published builds so installed copies can recognize it as an update. [Releasing](releasing.md)

## Verification

**Test decisions with fakes and verify platform behavior on macOS.** Swift Testing exercises
policy, migrations, scheduling, retrieval, prompt escaping and validated results using in-memory
databases, fake model clients, and injected clocks. The app target wires these pieces together.
Source guards cover critical wiring, and native previews use synthetic data. Run `make test`,
`make build`, and `scripts/check-public.sh` before submitting changes. Pull-request CI uses an
unsigned Debug build. [Verification guidance](../.claude/skills/remora-verify/SKILL.md)

| Area | Manual checks |
| --- | --- |
| Capture and insertion | Safari, Chrome, Arc if installed, Mail, Messages, Notes, Slack, VS Code/Cursor, Terminal, and web composers such as Gmail and LinkedIn. Submit a typed Insert prompt at a caret and over a selection. In an excluded app, verify that Insert shows Prompt only and can draft with Apple Intelligence unavailable. Exercise private windows, secure fields, pause, pasteboard restoration, undo, and the onboarding practice field. |
| Ghostty popover | Tap right Option with the prompt low in a tall terminal, then repeat in a split pane on a secondary display. Move the pointer inside and outside the focused pane. Check placement at the cursor when available, and the pointer or pane centre otherwise. Repeat with highlighted text. |
| Google Docs popover | In Chrome, enable **Turn on screen magnifier support** in **Tools › Accessibility**. In a blank document, move the mouse away from the page and tap right Option. Repeat after moving the caret with the keyboard in a populated document or highlighting text. Verify placement follows the text. Disable the setting and verify pointer fallback when no text bounds are available. |
| Dictation and notes | English and French, AZERTY Option typing, a Bluetooth microphone, hold and hands-free recording, Draft and insert, Insert transcript, Edit, cancel, and a mode switch followed immediately by Return. Verify that OpenAI transcription hides the EN/FR button and detects the language on Insert transcript. The button returns when OpenAI transcription is off. In an excluded app, speak a prompt and verify that Return drafts the result. Check that Listening appears when the microphone is ready and a silent recording shows an inline notice. Verify a selected or pasted note, manual-only exclusions, and replay after deletion. |
| Chat and indicators | Real notch and secondary displays, hide and show the menu bar, hover and pin, IME, trackpad scroll, min size with 150% text, quiet switches between captured and excluded windows, badge placement, light and dark appearance, and accessibility display options. Send from older history and check that the question is visible before the reply. Scroll up mid-reply, then choose **Latest** and check that the view follows the rest of the reply. Open chat from a notification and check the selected message. Return must never approve a card. |
| Notifications and MCP | In the installed app, use Settings › Notifications › Send a test notification and check for the Remora app icon in the banner and Notification Center. Verify the permission prompt, wake catch-up, reminders with proactive messages off, sharing suppression, and delete-all cleanup. Test Connect and Update in real clients. For meeting sources, use test accounts and synthetic meetings to exercise authorization, resync, pause, forget, and disconnect. |
| Settings › Usage | With the pane open, rewrite or chat and check the new call appears without a refresh. Switch Today, 7 days and 30 days, click breakdown rows and legend entries to filter the log and click again to clear, sort by time and cost, and select a call to read the detail. During a usage-limit backoff, check the orange paused notice. Check light and dark appearance at the Settings window width. |
| Distribution | Fresh macOS account, install and move, permissions, signed DMG and Gatekeeper, and an update from a real appcast. |

The biggest open variables are Accessibility coverage across apps, multilingual speech accuracy,
semantic recall on personal memory, and how much background work a particular ChatGPT plan can
sustain. Local fallbacks and user controls keep these variables from becoming dependencies for
unrelated features.
