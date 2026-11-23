# AGENTS.md

Guidance for coding agents (Claude Code, Codex, Cursor and others) working in this repository.
Humans should read [CONTRIBUTING.md](CONTRIBUTING.md); everything there applies to agents too.

## What Remora is

A native Swift macOS menu-bar app: a private "second brain" that reads on-screen text through the
Accessibility API, builds a local memory from it, rewrites text in place with a hotkey (right ⌥),
dictates on-device (hold right ⌥), answers questions in a chat bar under the notch, and exposes its memory to
AI clients over a read-only MCP server (`remora-mcp`). It is an independent reimplementation of the
ideas in Goldfish (see [docs/research/prior-art.md](docs/research/prior-art.md)). Model calls go
through **Sign in with ChatGPT**, on the user's own ChatGPT plan; there is no Remora backend.

[Remora design](docs/design.md) records the decisions that govern the app. Read
[Capture and privacy](docs/design.md#capture-and-privacy) and the relevant design sections
before changing capture, prompts, the network or storage. Where the design is silent, use the
prior-art notes as a reference and record the decision (see "Plans and rulings").

## Repository map

| Path | What lives there |
|---|---|
| `App/Remora/` | The app target: SwiftUI/AppKit glue, wiring (`AppEnvironment.swift`), windows, menus, Settings, onboarding. No unit-test target: keep logic out of here. |
| `App/remora-mcp/` | The MCP server executable (read-only, stdio) bundled inside the app. |
| `Packages/RemoraKit/` | All logic, as a local Swift package with one library per area and a test target each. |
| `Config/*.xcconfig` | Signing, version and update settings. `Config/Local.xcconfig` (gitignored) overrides signing. |
| `project.yml` | XcodeGen source of truth. `Remora.xcodeproj` is generated and gitignored: never edit it. |
| `scripts/` | `release.sh` (release pipeline), `check-public.sh` (personal-data scan) and its allow list. |
| `docs/design.md` | Current design decisions, their rationale and trade-offs, and the manual verification matrix. |
| `docs/superpowers/` | Local planning notes, ignored by Git. |
| `docs/research/` | Public research notes. `docs/private/` is gitignored; never commit its contents. |
| `spikes/` | Throwaway experiments; not built, not shipped. |

RemoraKit modules (dependencies point downwards):

- `Storage` (GRDB, migrations, every store, `DataGeneration`, `DataReset`, `SettingsStore`), `Redaction`
- `Capture` (AX snapshotting, exclusions, `CapturePolicy`, `SnapshotPolicy`, the `AXQueue`), `Indicator`
- `Input` (focused field, insertion, hotkeys, `FieldRefusal`), `LLM` (SIWC auth, Responses client, routing, costs), `LLMTestSupport` (`FakeLLMClient`)
- `Embeddings`, `Retrieval` (FTS5 + embeddings, `DerivedPolicy`, `PromptEscaping`)
- `Rewrite`, `Dictation`, `Memory` (pipelines, scheduler, budget), `MCPServer`
- `Assistant` (chat agent, tools and actions, proactive briefs and nudges, reminders), `ChatBar`, `ClientConfig` (MCP client config edits), `Lifecycle` (install location, updates policy, onboarding flow)

## Commands

```sh
brew install xcodegen          # once
make test                      # swift test on Packages/RemoraKit (the whole unit suite)
make build                     # xcodegen generate + Debug build into build/
swift test --package-path Packages/RemoraKit --filter <SuiteOrTest>   # one suite while iterating
scripts/check-public.sh        # personal-data scan of the tree (prints file:line and pattern name only)
scripts/release.sh selftest    # release script self-test (no signing, no network)
```

`make install` and `make run` replace the developer's installed copy in `~/Applications` and
relaunch it. **Agents never run them, never `pkill` Remora, and never touch
`~/Library/Application Support/Remora`, the Keychain or the login item**, unless the user asks in
so many words. Only one copy of Remora may run at a time (they share the database, Keychain item,
global keys and MCP registrations).

## Non-negotiable rules

1. **Nothing captured leaves the Mac** except inside a model request to OpenAI on the user's
   account. No telemetry, analytics, crash reporters or third-party services. New network hosts
   need a spec change.
2. **Never log personal content.** `os.Logger`, subsystem `dev.remora`, one category per area.
   Log events, counts, enum cases and error *codes* (`CodedError.code`, `LLMError.errorCode`), never
   captured text, window titles, URLs, file paths with user names, prompts, model output,
   transcripts, tokens or client ids. Interpolations of anything else stay `.private`.
3. **Fail closed.** Unreadable exclusions deny all capture and use of captured data
   (`SnapshotPolicy.current` returns `.denyAll`). In excluded, private or unverifiable contexts,
   field text stays on-device. Insert can use the cloud with only the submitted prompt, including
   a reviewed transcript the user submits for drafting.
   Password managers, secure fields and vault pages are refused.
4. **Captured and derived text is untrusted data,** never instructions. Escape it with
   `PromptEscaping` inside tagged sections, and never let it trigger an action without a user click
   (turn taint plus `ActionPolicy`).
5. **Deletion reaches everything.** A new table or derived artifact must be covered by
   `DataReset.deleteAllCapturedData`, by forget (`ForgetMarks`) where it can quote captures, and
   by the `DataGeneration` check when a slow job writes it.
6. **Tests never use the network or a live model.** Use `FakeLLMClient`, `AppDatabase.inMemory()`
   and injected clocks. No real Keychain, no real `~/Library` paths, no real user files.
7. **No new dependencies** beyond GRDB, the MCP Swift SDK and Sparkle without the user's approval
   (see CONTRIBUTING). Their licenses go into `THIRD-PARTY-NOTICES.md`.
8. **Outward actions belong to the user:** pushing, publishing, creating repos or releases,
   notarizing, signing with the Developer ID key, rewriting git history, granting macOS
   permissions, signing in to ChatGPT. Prepare them; don't run them.
9. **No personal data in the tree.** Fixtures use `/Users/me`, `@example.com` and obviously fake
   secrets. Run `scripts/check-public.sh` before you finish; never print or commit
   `.public-denylist`.

## Code conventions

- Swift 6 language mode with complete strict concurrency; keep the build warning-free. Prefer
  value types and `Sendable` structs; `@unchecked Sendable` needs a comment saying why it is safe.
- UI and AppKit on the main actor. Accessibility IPC on `AXQueue`, except Remora's own windows
  (see the accessibility skill). Slow work (database scrubs, model calls) off the main actor.
- Pure decisions live in RemoraKit as small types with static functions and are unit-tested; the
  App target only wires them up. When App code must be guarded, add a source-reading test like
  `Tests/AssistantTests/AppSourceGuardTests.swift`.
- Comments explain *why* and the invariant being kept, in full sentences. Reference the relevant
  design decision when it provides context. No commented-out code.
- User-facing copy is plain, short and sentence-case, preserves wording pinned by the design,
  and never claims more than the code does. `FeatureGuide` (what the chat tells users about the
  app) must stay true: tests tie its figures to the real constants.
- Tests use Swift Testing (`import Testing`, `@Test`, `#expect`), named as behaviour sentences
  (`forgottenCaptureIsNotReplayed`). Write the failing test first.
- Commits: conventional prefixes (`feat(memory):`, `fix(input):`, `docs:`, `build:`), one concern
  per commit, body explaining why.

## Plans and rulings

Keep working plans and review notes in the ignored `docs/superpowers/` directory. When a change
establishes or revises a design decision, update [Remora design](docs/design.md) with what the
app does, why, and the trade-off. Read the relevant decisions before changing an existing
behavior.

## Manual verification

Unit tests can't drive Accessibility, the notch panel, notifications, dictation or signing. When a
change touches those, say what you could not verify and list the relevant
[manual checks](docs/design.md#verification) for the user.

## Skills

Task-specific guides live in `.claude/skills/` (Claude Code loads them automatically; other agents
should open the matching `SKILL.md` before starting):

| Skill | Read it before |
|---|---|
| [remora-privacy](.claude/skills/remora-privacy/SKILL.md) | anything that captures, stores, sends, logs, notifies or deletes user data |
| [remora-database](.claude/skills/remora-database/SKILL.md) | adding a table, column, migration, setting or store; writing from a background job |
| [remora-accessibility](.claude/skills/remora-accessibility/SKILL.md) | reading or writing other apps' text, the rewrite key, insertion, capture, hotkeys |
| [remora-llm](.claude/skills/remora-llm/SKILL.md) | prompts, a new model job, chat tools and actions, cost and budget |
| [remora-verify](.claude/skills/remora-verify/SKILL.md) | finishing any change: what to run, what to report, what stays manual |
| [remora-release](.claude/skills/remora-release/SKILL.md) | signing, updates (Sparkle), the release script, open-source hygiene |
