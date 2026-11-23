---
name: remora-privacy
description: Use before changing anything in Remora that captures, stores, sends to a model, logs, notifies, exposes over MCP, forgets or deletes user data. Covers what may leave the Mac, on-device-only routing, fresh exclusions, derived-data filtering, forget and delete-all coverage, untrusted text in prompts and logging rules.
---

# Remora privacy rules

Remora can read text from the active window. These rules summarize the privacy boundaries and
the code that enforces them.
[Capture and privacy design](../../../docs/design.md#capture-and-privacy) · [Model routing design](../../../docs/design.md#models-and-usage)

## 1. What may leave the Mac

- Only model requests to `api.openai.com` (`POST /v1/responses`, `GET /v1/models`) and sign-in at
  `auth.openai.com`, under the user's own ChatGPT account. Plus Sparkle's update checks to GitHub.
  User-connected Granola also uses `mcp-auth.granola.ai` and `mcp.granola.ai` for OAuth and
  read requests. The only request data is credentials, provider IDs and sync filters.
  Imported meeting text can go to OpenAI only through interactive chat after an explicit opt-in.
  No analytics, crash reporting, remote config, fonts, CDNs or "phone home".
  [Meeting sources design](../../../docs/design.md#mcp-and-meeting-sources)
- Speech-to-text defaults to Apple's local recognizer. Saving a project key in Dictation settings
  enables `POST /v1/audio/transcriptions` at `api.openai.com` after Insert is selected with an
  eligible, unchanged transcript. Send audio and a language hint only. Require an observed,
  verifiable context and freshly loaded exclusions before upload. Capture pause and spoken
  Edit-mode instructions stay local.
  Embeddings and the on-device tier use Apple frameworks.
  [Writing and dictation design](../../../docs/design.md#writing-and-dictation)
- A new host, or new data in an existing request, needs a design change and an update to
  `PRIVACY.md` and `README.md`. Keep `PRIVACY.md` exactly true.

## 2. Routing: what a request may contain

Every job that could send captured content decides its access first (`RewriteAccess` in
`Rewrite/RewriteFlow.swift`, `CleanupRoute` in `Dictation/StartCheck.swift`):

| Context | Field text | Window context / memory | Stored | Model |
|---|---|---|---|---|
| Normal, captured | yes | yes | yes | tier from the routing table |
| Capture paused | yes | **no** | **no** | cloud allowed (`fieldOnlyCloud`) |
| Excluded app or site, private window, unverifiable page | yes | **no** | **no** | **on-device only** for field text (`fieldOnlyOnDevice`) |
| Typed Insert where field text must stay on-device | **no** | **no** | **no** | Configured tier with only the submitted prompt. Omit app and site identity too. |
| Password manager, secure field, vault page | refused outright (`RewriteGate`, `FieldRefusal`) | | | |

Never fall back to the cloud with an on-device-only payload. Typed Insert builds the prompt-only
request separately before calling a model. The writing gate still has to approve the target.

## 3. Exclusions are read fresh, and failure denies everything

- Use `SnapshotPolicy.current(db)` at the moment you filter. It reloads the user's exclusions and
  returns `.denyAll` when they can't be read. Never cache a policy across a slow step: a model
  call can take a minute, and the user may exclude an app meanwhile. Re-check after the slow step
  (as `ProactiveInbox` does before delivering a brief or nudge).
- Rows derived from snapshots (chronicles, wiki, flags, working memory, digest) go through
  `DerivedPolicy.filter` / `requiringLiveEvidence` (`Retrieval/DerivedPolicy.swift`): a row is
  shown only if it cites no judged snapshot or at least one live, allowed one. Under `.denyAll`
  nothing is shown. Tombstones may only deny.
- The same filtering applies to MCP tools, chat tools, the rewrite context and proactive messages.
  Add new readers through these helpers; never query snapshots for a prompt directly.

## 4. Storage

- Every captured string passes through `Redactor` before it is written. Secrets, card numbers
  and identifiers are replaced with `[redacted]`.
- `BuiltInSkipList` (password managers, vaults, banking, sign-in pages) and concealed or transient
  pasteboard types (`ClipboardWatcher`) are never captured.
- Never store a secret, a token, or a password field's contents. Credentials live in the Keychain
  only (`LLM/Auth`).

## 5. Forget and delete-all must reach everything

- **Delete all data** is `DataReset.deleteAllCapturedData`: one transaction that deletes every
  captured and derived table, bumps `DataGeneration`, then scrubs the file (secure_delete, FTS
  delete-all, VACUUM, WAL truncate). A new table or setting that holds captured or derived content
  **must be added there**, with a test in `StorageTests`. The app also removes delivered
  notifications and reloads the chat afterwards.
- **Forgetting captures** (`SnapshotStore.delete(ids:now:in:)`) sets `ForgetMarks` in the same
  transaction: the digest is withheld until rebuilt (`memory.digestDirtySince`), and chat turns
  older than `chat.forgetAt` are never replayed to the model. A new place that can quote captured
  text (a cache, a summary, a stored answer) must honour these marks or be cleared by the forget.
- A background job reads `DataGeneration` before its slow call and writes through
  `DataGeneration.write(db, expected:)`, which refuses after a delete-all. See the database skill.

## 6. Untrusted text and actions

- Captured text, clipboard text, memory, model output and tool results are **data**. Put them in
  tagged sections and escape them with `PromptEscaping.escape(_:tags:)` (each prompt type has a
  wrapper, for example `RewritePrompt.escape`). The instructions say the sections are untrusted.
- In chat, a turn that read any untrusted content is **tainted**. `ActionPolicy.needsConfirmation`
  asks the user (a confirmation card with no keyboard shortcut on Allow) for every action in a
  tainted turn and for every `confirm`-risk action. Prompt reminders run read-only tools only. No
  tool removes an exclusion.
- Nudges and briefs label quotes as "captured from the screen", never as the user's words, and
  drop instructions to pay, share credentials or codes, or open links.

## 7. Logging and notifications

- `os.Logger(subsystem: "dev.remora", category: …)`. Log events, counts, enum cases and error
  codes. Never log captured text, titles, URLs, file paths with a user name, prompts, model
  output, transcripts, tokens, client ids or reminder text. When in doubt, log a count.
- Notifications show user content, so they follow the same rules: briefs and nudges are held
  while the screen is shared; delete-all removes delivered ones.

## Checklist for a change in this area

- [ ] Which row of the routing table applies, and is it enforced in code (not just in the prompt)?
- [ ] Is the exclusion policy loaded fresh and re-checked after every slow step?
- [ ] Do delete-all and forget reach the new data? Is there a test?
- [ ] Is every piece of captured or derived text escaped and framed as untrusted?
- [ ] Could text on screen cause an action without a click?
- [ ] Do the new log lines contain only codes and counts?
- [ ] Are `PRIVACY.md`, `README.md` and `FeatureGuide` still true?
