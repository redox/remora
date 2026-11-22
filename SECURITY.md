# Security policy

## Reporting a vulnerability

Report it privately through GitHub: open the repository's **Security** tab and choose
**Report a vulnerability**. Please don't open a public issue for a security problem.

Include what you found, how to reproduce it, the Remora version (Settings › General) and your
macOS version.

## In scope

- Capture of content that should be excluded: secure fields, private windows, password managers,
  the built-in skip lists, your exclusions, or anything while capture is paused.
- Redaction bypass: a secret that reaches the database or a model request unredacted.
- Data leaving the Mac other than as described in [PRIVACY.md](PRIVACY.md).
- The MCP server (`remora-mcp`): access beyond read-only memory, or prompt injection that leads to
  an action.
- The update channel: appcast, signature checks, the installed update.
- Token handling: the Sign in with ChatGPT flow, token storage and refresh.

## Response

This is a personal project, so responses are best effort. A report is acknowledged within 7 days.
Only the latest release is supported; fixes ship as a new release.
