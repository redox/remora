# Prior art: Goldfish

Remora's design follows [Goldfish](https://goldfish.sh), a commercial macOS app. This page
summarizes, in our own words, Goldfish's behaviour as its public website and documentation describe
it. It uses nothing from Goldfish's binary, and Remora shares none of its code, name or assets.
Remora is not affiliated with Goldfish.

Sources: the [goldfish.sh](https://goldfish.sh) home page, FAQ and privacy pages, and the
documentation at [docs.goldfish.sh](https://docs.goldfish.sh), in particular
[Chat](https://docs.goldfish.sh/guides/chat),
[Voice dictation](https://docs.goldfish.sh/guides/voice-dictation),
[AI clients](https://docs.goldfish.sh/guides/ai-clients),
[Settings](https://docs.goldfish.sh/reference/settings) and
[Shortcuts](https://docs.goldfish.sh/reference/shortcuts).

## What it is

A "second brain" for the Mac. It reads the text of the window you're working in through the
Accessibility API, keeps it locally, and has a language model organize it in the background. That
memory is then used to:

- write or rewrite text in any text field, in your voice, with a single key;
- answer questions about what you have seen and done, in a chat;
- serve the memory to other AI apps over MCP.

## Behaviour Remora mirrors

- **Capture:** text from the frontmost window and the clipboard, never secure fields, with
  user-defined exclusions by app, site, window title, URL or path. Names, emails and phone numbers
  are kept; secrets are not.
- **Rewrite key:** a single modifier key (right ⌥) rewrites, fixes or drafts text in place.
- **Dictation:** off by default; hold the fn (🌐) key to talk and release to insert; a double-tap,
  or holding the key with left Control, latches it until pressed again; a short sound when it
  starts and stops. The microphone is only needed when dictation is on, and macOS's own
  "Press 🌐 key to" setting should be set to Do Nothing.
- **Chat:** a slim bar near the top of the screen for questions about your memory, which can also
  change settings and exclusions when asked.
- **Proactive messages:** occasional briefs and nudges built from memory.
- **AI clients:** a local MCP server that lets assistants such as Claude or Cursor search and read
  your memory.
- **Memory:** summaries over time (hours, days and longer periods) and pages about the people,
  projects and topics you deal with.

## Where Remora differs

- Cloud inference runs on the user's own ChatGPT plan through Sign in with ChatGPT; there is no
  vendor account or server in between.
- One app process plus a small MCP helper, open source under the MIT License.
- A visible capture indicator, and explicit Connect buttons for MCP clients rather than silent
  registration.
- No import of Goldfish data, and Goldfish should not run at the same time (both use right ⌥ and
  fn).
