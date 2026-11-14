# Security

Veil sits between your private messages and an AI assistant, so a bug that lets an assistant see
or send more than you allowed is a security bug.

## Reporting a problem

Please report it privately through GitHub: **Security → Report a vulnerability** on this
repository. Don't open a public issue for it.

Useful to include: what the assistant could see or do that it shouldn't, the MCP calls (or steps)
that cause it, and your macOS version. Please use made-up data, never real messages.

## What counts

- An MCP call that returns content from a chat whose switch is off, or a hidden chat's existence.
- Getting a message sent without your click (outside a chat with Auto-send on).
- Changing permissions, filter settings or webhook settings from outside the app.
- Content that a filtered chat should have masked or withheld reaching the assistant because of a
  bug in Veil's logic (not because the on-device model misjudged something, which the security
  model describes as a known limit).
- The webhook key or message text ending up in a log or ping.

See [docs/security-model.md](docs/security-model.md) for what Veil does and doesn't promise.
