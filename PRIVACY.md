# Privacy

Remora has no servers and no account system of its own. This page describes what the app reads,
where it keeps it, and what leaves your Mac.

## What Remora reads

- **The frontmost window's text**, through the macOS Accessibility API, while you work in it.
- **Text you copy** to the clipboard.
- **Meeting transcripts and generated notes** from sources you connect in Settings › Meeting
  sources. Remora reads meeting identifiers, titles and dates for sync and search.

## What Remora never reads

- Password fields, private or incognito browser windows, and password managers.
- Banking and payment sites, and sign-in pages, from a built-in list.
- Clipboard items that apps mark as concealed or transient (as password managers do).
- Background capture skips ignored apps, sites and windows, and stops while capture is paused.
- Some apps and sites are excluded by default (AI chat apps and sites, terminals); you can remove
  them in Settings › Privacy.

Choose **Manual saves only** on an ignored app or site in Settings › Privacy to review and
explicitly save a selection from that source with **Remember this**.

Card numbers, API keys, passwords and other secrets that do appear in captured text are replaced
with `[redacted]` before anything is saved. Remora takes no screenshots, does not record the
screen, and does not log keystrokes.

## Where it is stored, and for how long

Everything is stored on your Mac, in `~/Library/Application Support/Remora/remora.sqlite`.

- Raw captures are kept for 30 days by default (Settings › Memory), then deleted once summarized,
  unless a wiki fact or open item cites them.
- Derived memory (summaries, wiki, open items, your profile) is kept until you delete it. Memory
  derived before you added an exclusion stays until you forget it; forgetting a capture also
  removes what was derived only from it.
- Routine discovery scans recent focus history on your Mac when you ask in chat. The chat request
  can include matching window titles, app or site names, dates, and focus times. Confirmed names and
  dismissals are saved locally and cleared when you forget a capture or delete all data. New scans
  follow your current exclusions. Earlier replies follow the chat history rules for replay.
- When Background memory and Proactive messages are on, Remora also scans for routines weekly on
  your Mac. Automatic findings stay in the inbox and are excluded from model replay and chat
  summaries. Adding an exclusion, forgetting a capture, or deleting all data removes these entries.
- Imported meetings have a separate local search index. Forgetting a meeting removes its local
  copy and records a fingerprint to skip it on future syncs. Disconnecting removes the source's
  imported meetings. Forgetting or disconnecting also prevents earlier chat from being reused.
- Saved notes are redacted and indexed locally when you save them. Search or delete them in
  Settings › Memory › Notes. Disabling chat access or deleting a note while chat access is on
  prevents earlier chat from being sent again. Earlier replies stay visible until you clear chat.
- **Delete all data** (Settings › Privacy) removes captures, derived memory, chat history,
  reminders, imported meetings and saved notes. It disconnects meeting sources, switches off
  chat access to imported meetings and saved notes, and keeps exclusions and other preferences.

## What leaves your Mac

- **Model requests to `api.openai.com`, and sign-in at `auth.openai.com`**, under your own ChatGPT
  account. A request holds the input and excerpts that task needs, such as a writing prompt, the
  text around the caret, and relevant memory. OpenAI's terms for your plan apply to it. In excluded,
  private or unverifiable contexts, any text Remora reads stays on-device. If you submit an Insert
  prompt in a supported field there, a cloud request contains only your typed or reviewed spoken prompt.
  Field text, app and site information, and memory stay on your Mac. While capture is paused in an
  otherwise allowed context, writing requests use only the field text and any prompt you enter.
  If you enable meeting access in Settings › Meeting sources, interactive chat can send relevant
  meeting excerpts to OpenAI.
  Imported meetings stay local by default. The separate **Use saved notes in chat** option
  allows relevant excerpts from saved notes in interactive chat. It is off by default.
- **Update checks and downloads from GitHub (`github.com` and its release-asset hosts)**, which
  see your IP address and the app version.
- **Dictation language models**, which macOS downloads from Apple the first time you dictate in a
  language (see Dictation below).
- **Granola**, only if you choose to connect it. Remora signs in through
  `mcp-auth.granola.ai` and sends read requests to `mcp.granola.ai` with the session credential,
  sync filters and identifiers from Granola. Quill and compatible local sources use a loopback
  connection on your Mac.

## Dictation

Dictation is off by default. When on, Apple's speech recognition provides the live preview and the
default final transcript. macOS downloads speech models from Apple as needed. The microphone audio
is kept in memory for the session and is never written to disk by Remora.

**Draft and insert** and **Edit** can send the reviewed transcript as text using the writing
privacy rules above. Those actions keep the audio on your Mac.

If you save a project API key in **Settings › Dictation › OpenAI transcription**, Remora can send
the completed recording to `api.openai.com/v1/audio/transcriptions` with `gpt-transcribe` after you
choose **Insert transcript** with the unchanged transcript. The request uses that API project, and
OpenAI detects the language from the audio.
Cloud transcription requires a verifiable, allowed window throughout the dictation. Dictation
audio stays local while capture is paused or if privacy checks fail. Dismissing the draft discards
its audio.
If the request fails, Remora uses Apple's transcript. Remove the key in Settings to disable uploads.

## MCP clients

AI apps you connect in Settings › MCP can read your Remora memory through `remora-mcp`. What they
do with it (including sending it to their own model provider) is governed by those apps, not by
Remora.

## Credentials, logs and telemetry

- Your ChatGPT and Granola sign-in tokens and optional OpenAI transcription key are stored in
  separate macOS Keychain items.
- Logs (`~/Library/Logs/Remora/` and the system log) hold events and counts only, never captured
  text, prompts or answers.
- No telemetry, analytics or crash reporting.
