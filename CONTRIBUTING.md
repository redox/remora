# Contributing

Remora is a personal project, shared as is. Issues and small, focused pull requests are welcome;
large changes are best discussed in an issue first.

## Setup

```sh
brew install xcodegen
make test     # swift test on Packages/RemoraKit
make build    # xcodegen generate, then a Debug build in build/
```

`project.yml` is the source of truth; `Remora.xcodeproj` is generated and gitignored.

### Signing

The committed `Config/*.xcconfig` files sign with the maintainer's team. Override them locally:
copy `Config/Local.xcconfig.example` to `Config/Local.xcconfig` (gitignored) and uncomment one
option, either your own Apple developer team or ad-hoc signing.

A stable signing identity matters because macOS ties the Accessibility and Microphone grants (TCC)
to the app's code signature. With your own team the grant survives rebuilds. An ad-hoc build gets
a new identity on every rebuild, so macOS silently drops the Accessibility grant and you have to
remove and re-add Remora in System Settings › Privacy & Security › Accessibility each time.

### Never run two copies at once

The database, the Keychain item, the login item, the global keys and the MCP registrations are all
shared. A second copy with the same bundle id says "Remora is already running" and quits, but quit
any installed copy before you launch a development build anyway, and don't run Goldfish alongside
it (both claim right ⌥).

## Before a pull request

- Run `make test` and `make build`. Both must pass.
- The code is Swift 6 with strict concurrency (`complete`); keep it warning-free.
- Run `scripts/check-public.sh` (see below).
- Keep changes small and say what you verified by hand (Accessibility behaviour differs a lot
  between apps).

## Never log or commit personal data

- Logs use `os.Logger` (subsystem `dev.remora`) and hold events and counts only: never captured
  text, prompts, model answers or credentials.
- Test fixtures use fake data: `/Users/me`, `@example.com` addresses, obviously fake secrets.
- Never commit a database, a log export, a screenshot of real content, a token or a client id.
- `scripts/check-public.sh` scans the tree for client ids, JWTs, private keys, home-folder paths
  and email addresses. Put your own name, emails and work domains in a gitignored
  `.public-denylist` (one fixed string per line) and it checks those too. Deliberate fakes are
  listed in `scripts/check-public.allow`.
- The denylist is local-only: CI never sees it, so CI can't catch those strings. Before publishing
  (or pushing to a public remote), run `scripts/check-public.sh --history` locally; it scans every
  commit, not just the tree.

## Dependencies

Remora depends on GRDB, the MCP Swift SDK and Sparkle only (plus what they pull in). A new
dependency needs a written reason in the pull request: what it does that a few hundred lines of
our own code can't, its license, and its maintenance record. Its license text goes into
`THIRD-PARTY-NOTICES.md`.

## Prompts

Captured text, clipboard text, memory, and tool results are untrusted data. Prompts must present
them as data to work on, never as instructions, and a model's output must not be able to trigger
an action the user didn't ask for.

## CI

`.github/workflows/ci.yml` runs on pushes to `main` and on pull requests, on a macOS runner with
the newest Xcode: `scripts/check-public.sh --selftest`, `scripts/check-public.sh`, `make test`, then `make ci-build` (an unsigned Debug
build). It needs no secrets and never signs anything.
