---
name: remora-release
description: Use before touching Remora's signing, xcconfig files, Sparkle auto-updates, the launch gate and move to Applications, the release script, CI, license and third-party notices, or anything about publishing the open-source repository. Covers what agents may run, DRY_RUN, update and install policies, and the public-data scan.
---

# Distribution, updates and open-source hygiene

This skill covers what an agent may do. See the release runbook for the procedure and the
installation design for the rationale.
[Release runbook](../../../docs/releasing.md) · [Installation and updates design](../../../docs/design.md#installation-and-updates)

## The line agents don't cross

Agents prepare; the user runs anything that uses their identity or reaches the outside world:

- signing with the Developer ID identity (`make release` without `DRY_RUN`), Keychain prompts,
  `security set-key-partition-list`;
- `make notarize`, `make staple`, `make appcast`, `make release-all`, `generate_keys`;
- tagging, pushing, `gh repo create`, `gh release create`, enabling GitHub settings;
- rewriting git history (the history scrub happens on a fresh clone, by the user).

Agents may run `scripts/release.sh selftest`, `make release-selftest`, `bash -n`, shellcheck, and
`make <target> DRY_RUN=1` for notarize, staple and appcast (they only print). A `DRY_RUN=1`
`make release` still signs with the real key, so it is the user's to run too.

## Build configuration

- `project.yml` is the source of truth (XcodeGen); never edit `Remora.xcodeproj`.
- `Config/Signing.xcconfig` holds the maintainer's team; contributors override in the gitignored
  `Config/Local.xcconfig`. TCC grants (Accessibility, Microphone) follow the signature, so don't
  change signing casually.
- `Config/Version.xcconfig`: `MARKETING_VERSION` and an always-increasing `CURRENT_PROJECT_VERSION`.
- `Config/Updates.xcconfig`: `REMORA_GITHUB_REPO` and `REMORA_SPARKLE_PUBLIC_KEY` are empty until the
  user chooses the repository. Never invent an owner. Anything that shows the repository URL
  hides itself while it is empty.
- Sparkle is pinned with `exactVersion` in `project.yml`; the release script fails if the embedded
  framework differs. Xcode embeds it (don't add `embed: true`).

## Runtime policies (Lifecycle)

- **Launch gate first** (`RemoraApp.init`, before the database opens): a second instance quits
  (the earliest-launched copy wins); a copy outside Applications offers to move itself (into
  whichever of `/Applications` and `~/Applications` already holds Remora), refuses to downgrade
  a newer installed copy, restores the old copy from the Trash if the copy fails, strips
  quarantine before relaunching, and treats a translocated copy whose original is in
  Applications as installed. Never trash the running app.
- **Updates** (`UpdaterController`, owned by `RemoraApp`): Sparkle exists only when
  `UpdateConfiguration.evaluate` is `.ready` (Release build, https feed, valid key) **and** the
  copy is installed. An update installs on quit or after idling, never while Remora is busy
  (`AppEnvironment.isBusyForUpdate`: rewrite, dictation, delete-all, memory job, onboarding,
  streaming chat turn). Add any new long-running user task to that check.
- **Only installed copies register** the login item and MCP client entries
  (`ServerLocation.refusal(isInstalled:…)`).

Pure decisions for all of these live in `Packages/RemoraKit/Sources/Lifecycle` with tests; keep
new rules there.

## The release script (`scripts/release.sh`)

bash with `set -euo pipefail`; subcommands `build`, `notarize`, `staple`, `appcast`, `selftest`.
When you change it:

- Every external call (Apple, mounts, uploads) must sit behind `is_dry`.
- Every signing `codesign` goes through `run_watched` (a watchdog, because a Keychain prompt can
  hang it). The EXIT/INT/TERM trap kills watched processes, detaches mounts and removes temp files,
  but keeps finished artifacts.
- Never print keys, passwords or tokens. The identity is shown by its last 6 hash characters.
- Add a `selftest` case with stub commands on `PATH` for every new behaviour. Never exercise the
  real key from a test.

## Open-source hygiene

- MIT license, "The Remora authors". A dependency's license text goes verbatim into
  `THIRD-PARTY-NOTICES.md` (bundled and shown under Settings › General › Acknowledgements).
- `scripts/check-public.sh` must stay clean: no client ids, JWTs, private keys, home-folder paths
  other than `/Users/me`, or email addresses other than the allowed example domains, plus each
  line of the user's local, gitignored `.public-denylist`. It prints only `file:line: <pattern>`.
  Never read or print the denylist. Only deliberate fakes go into `scripts/check-public.allow`,
  scoped to one pattern where possible.
- `docs/private/` is gitignored (private research). Public docs link `docs/research/prior-art.md`.
- CI (`.github/workflows/ci.yml`) needs no secrets: check-public selftest and scan, `make test`,
  `make ci-build`.
- `README.md`, `PRIVACY.md` and `SECURITY.md` make claims about behaviour; update them in the
  same change that alters what they describe.
