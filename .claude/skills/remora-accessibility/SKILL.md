---
name: remora-accessibility
description: Use before changing how Remora reads or writes other apps' UI through the macOS Accessibility API — capture, the focused field, the rewrite key, text insertion and paste fallback, caret placement, hotkeys and key monitors, or Remora's own practice field. Covers the AX queue, timeouts, own-process main-thread calls, refusals and manual testing.
---

# Accessibility, input and insertion

Remora is a guest in every app the user types into. It must preserve normal typing, the original
field until the result is ready, and the clipboard. The code lives in `Capture` (reading windows)
and `Input` (the focused field, hotkeys, insertion).
[Writing and dictation design](../../../docs/design.md#writing-and-dictation)

## Threads

- **Another app's elements:** every AX call runs on the one serial queue `AXQueue`
  (`Capture/System/AXQueue.swift`). Use `AXQueue.run` from async code and `AXQueue.sync` only off
  the main thread. The main thread never waits on AX IPC: a hung app would freeze the menu bar.
- **Every element gets a messaging timeout** (`axMessagingTimeout`, 0.25 s), set when it is
  obtained (`AXReadSession.bound`). A session that timed out reports `isUnresponsive`; treat that
  as `.notResponding` and stop, don't retry in a loop.
- **Remora's own elements** (the onboarding practice field) are not IPC: macOS calls straight into
  AppKit on the calling thread, and AppKit's text system traps off the main thread. Route by pid
  with `FieldAXRoute` (`Input/FieldAXRoute.swift`): own pid goes to the main thread through
  `MainThreadRunner.sync`, everything else to `AXQueue`. `SystemFieldHandle` and
  `FocusedFieldReader` already do this. Any new code touching an element whose pid may be ours
  must too.
- Insertion runs in a detached task, off the main actor, and once started runs to the end (its
  waits are non-cancellable) so the pasteboard is never restored before the paste lands.

## Reading

- Check the element's identity before reading any text. `FieldRefusal.check` refuses secure fields,
  password managers (`BuiltInSkipList`) and Remora's own UI, except the practice field identified
  by `practiceFieldIdentifier` in Remora's own process.
- Chromium and Electron apps expose no AX tree until `AXEnhancedUserInterface` /
  `AXManualAccessibility` is set on the app element (`AppAccessibility.enable`). Never set it on
  Remora itself.
- Capture is snapshot-based and must stay cheap: no Screen Recording, no polling faster than the
  existing tick, bounded tree walks. Measure CPU when you change the walk.

## Writing (`Input/TextInserter.swift`)

1. Re-read the field. If its value is no longer what the rewrite was based on, write nothing
   (`.fieldChanged`). If it lost focus or another app is frontmost, write nothing (`.notFocused`).
2. Try Accessibility: set the selected range, then the selected text (or the value), and read it
   back to verify.
3. Otherwise paste: save the pasteboard, put the text, send ⌘V resolved for the current keyboard
   layout (`KeyLayout`), wait, then restore the previous contents exactly, unless the user copied
   something new meanwhile. Web-backed fields prefer paste.
4. Never change the user's selection just to make a write easier.

## Hotkeys and key monitors

- A clean tap of right ⌥ (keycode 61, nothing else pressed in between) opens Rewrite for a selection
  or Draft at the caret. Double-tap rewrites selected text or drafts at the caret. A hold previews
  dictation in Draft when enabled. Tap inside the popover
  to switch modes. ⌘⇧G is the optional fallback chord. `TapDetector` must never fire during ⌥ combos used to type
  characters (AZERTY: @, é…). Add a test case to their tests for every new gesture rule. No
  feature may require the Input Monitoring permission.
- Event-tap callbacks hop to the main actor with `MainActor.assumeIsolated`; keep them short.

## Caret and overlay placement

The indicator sits at the insertion point: `CaretGeometry` turns `AXBoundsForRange` into a thin
rect, ignoring line-wide rects that some apps return for a newline. Fall back to the field frame,
never to the screen edge.

## Testing

- Pure logic (refusals, routing, tap detection, caret geometry, insertion decisions with a fake
  `FieldHandle` and `PasteboardAccess`) gets unit tests in `InputTests` / `CaptureTests`.
- Real AX behaviour can't be unit-tested. List relevant checks from the
  [manual verification matrix](../../../docs/design.md#verification). Include the practice field
  in onboarding when you touch own-app paths.
