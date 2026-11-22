---
name: remora-verify
description: Use when finishing any change in Remora, before saying it works — which commands to run, how to test App-target code that has no test target, what never to run, how to report what was not verified, and which manual checks to hand to the user.
---

# Verifying a change

## Always

```sh
make test                  # the whole RemoraKit suite (Swift Testing); must end with 0 failures
make build                 # regenerates the Xcode project and builds the app; must succeed, no new warnings
scripts/check-public.sh    # no personal data in the tree; prints file:line and a pattern name only
```

Read the actual results before claiming success: `make test` prints one "Test run with N tests …
passed" line per test bundle, and failures are marked `✘`. A green run proves only the tree it ran
on. After a merge, run the suite again on the merged result.

Also run, when you touched them:

- `scripts/release.sh selftest` for `scripts/release.sh` or the Makefile release targets;
- `scripts/check-public.sh --selftest` for `scripts/check-public.sh` or its allow list;
- `swift test --package-path Packages/RemoraKit --filter <Suite>` while iterating (not instead of the full run).

## Tests

- Swift Testing only (`@Test`, `#expect`, `#require`), named as behaviour sentences. Write the
  failing test first and see it fail for the right reason.
- Databases: `AppDatabase.inMemory()`. Models: `FakeLLMClient`. Time: inject `now` and the
  calendar (`MemoryCalendar`, `PeriodKey.localCalendar`). Files: a temporary directory.
- Never touch the network, the real Keychain, the user's database, real `~/Library` paths or real
  MCP client config files. ClientConfig tests use temp files.
- The App target has no test target. Keep logic in RemoraKit. For App wiring that must not regress,
  add a source-reading guard (`Tests/AssistantTests/AppSourceGuardTests.swift`). It reads the
  `.swift` file by path and asserts on its text, for example that the confirmation card's Allow
  button has no keyboard shortcut.

## Never, unless the user asks in so many words

- `make install`, `make run`, `open` on the app, `pkill Remora`: they replace or restart the
  user's own copy, which holds their Accessibility grant and live data.
- Anything in `~/Library/Application Support/Remora`, the Keychain item, the login item, or
  `~/.claude.json` / Claude Desktop / Cursor / Codex config files.
- Signing with the Developer ID identity, notarizing, uploading, tagging, pushing.

## Reporting

Say what you ran and what it printed (counts, not "should pass"). Then say plainly what you could
not verify. Typical items:

- real Accessibility reads and writes in other apps. [Manual verification matrix](../../../docs/design.md#verification)
- the notch chat panel's layout, IME, multiple displays, larger text sizes;
- notifications (permission prompt, banners, Notification Center cleanup);
- dictation with real microphones, including Bluetooth;
- onboarding and Settings windows visually;
- signing, notarization, Gatekeeper and translocation, Sparkle updates against a real feed.

Turn those into a short manual checklist for the user, in the plan's "manual verification" task
or in your final message.

## Crashes

When the user reports a crash, read the newest `~/Library/Logs/DiagnosticReports/Remora-*.ips`
(JSON after the first line): the exception type, the faulting thread's queue name, and its frames
point at the cause. Logs: `log show --last 10m --predicate 'subsystem == "dev.remora"' --info`.
Find the root cause before changing code, add a test that pins it, and say what the user should
re-try.
