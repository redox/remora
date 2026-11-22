# Capture matrix: first real run (2026-11-20)

Build `281e440` (Task 9 before its review fixes), installed at `~/Applications/Remora.app`,
Accessibility granted by the user. The window was 10:14 → 10:24 CET of normal use.
Metadata only; no captured text was read.

| App | Snapshots | Max chars | Domain/URL | Notes |
|---|---|---|---|---|
| Claude (Electron) | 14 | 43,965 | — | captures conversations; user may want `app:Claude` |
| Messages | 9 | 2,642 | — | ✅ |
| GCal for Google Calendar (Electron) | 7 | 15,864 | — | ✅ |
| Slack (Electron) | 7 | 8,497 | — | ✅ |
| Grok Bot | 6 | 9,830 | — | ✅ |
| Google Chrome | 5 | 31,148 | ✅ a work site | web-area text and URL work |
| WhatsApp | 3 | 12,384 | — | ⚠️ app name starts with U+200E (LEFT-TO-RIGHT MARK) |
| Discord (Electron) | 1 | 12,910 | — | ✅ |
| Mail | 1 | 27,258 | — | ✅ (needs the 3 s read timeout) |
| System Settings | 1 | 5,931 | — | ✅ |

- **CPU:** 4.85 s of CPU over 9 min 33 s of wall time ≈ **0.85 % average** (budget < 3 %). RSS 96 MB.
- **Activity events:** recorded for every app above. Slack had 284 s of focus.
- **Redaction:** no `[redacted]` rows in this sample (nothing secret on screen).
- **Not exercised in this run:** Safari or Chrome private windows, 1Password (0 rows and 0 events,
  so not opened), Terminal, code editor, clipboard (0 clipboard rows, so no copies were kept
  or none were made), and pause, ignore list, delete-all and login item.

## Findings

1. **App names can carry invisible Unicode format characters.** WhatsApp's `localizedName` is
   `\u{200E}WhatsApp`, so an `app:WhatsApp` exclusion would not match and the app would keep being
   captured. Fix: strip Unicode format characters (category Cf: bidi marks, ZWJ/ZWNJ, BOM) from
   app names at capture time *and* in `ExclusionRule` matching. Also normalise case and width.
