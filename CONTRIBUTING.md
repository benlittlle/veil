# Contributing

Thanks for helping. Veil guards people's private messages, so the bar is: **never return more than
the user allowed, and when in doubt, withhold.**

## Getting set up

You need a Mac with Xcode 27 (the photo checks build against the macOS 27 SDK).

```bash
swift test                                   # unit tests, fixture database only
swift run Veil --demo                        # the app with fake data and a fake sender
swift run Veil --snapshot /tmp/shots         # render every screen to PNG (light + dark)
scripts/build-app.sh --install               # build, sign and install ~/Applications/Veil.app
```

**Signing.** The build script signs with your first "Apple Development" certificate so macOS permissions (Full Disk Access, Contacts) survive rebuilds. Any Apple ID can make one for free: Xcode → *Settings → Accounts*, add your Apple ID, then *Manage Certificates → + → Apple Development*. To pick a specific one, run `SIGN_IDENTITY="Apple Development: Your Name (ABCDE12345)" scripts/build-app.sh --install` (`security find-identity -v -p codesigning` lists them). Without a certificate, `SIGN_IDENTITY=-` signs ad-hoc, and you'll need to re-grant Full Disk Access after each rebuild.

Opt-in evals run Apple's on-device model (needs Apple Intelligence turned on):

```bash
VEIL_EVAL=1 swift test --filter FilterEval   # text filter: precision/recall per category
VEIL_EVAL=1 swift test --filter PhotoEval    # photo checks: recall, false withholds, latency
```

## Rules for changes

- **No real data, ever.** Tests and demo mode use `DemoData.swift`, a fake chat.db where every private
  message contains `SECRET`. Never commit real messages, numbers, names or attachments, not even in
  an issue. Tests must never send a message.
- **Every content path goes through `Gate`.** A new MCP tool or field needs a policy check, the content
  filter for filtered chats, a log entry without message text, and a case in `LeakTests` proving
  `SECRET` doesn't come back.
- **No MCP tool may change permissions,** filter settings or webhook settings, with one exception: the settings tools in
  `GateSettings.swift`, which exist only while the user sets *Assistant can change settings* to Ask me or Apply directly.
  Anything new they can reach needs strict validation, a plain-language prompt line, a log entry and tests in
  `AgentSettingsTests`. The mode itself, hidden chats, the webhook, HTTP and keys stay UI-only.
- **Fail closed.** Errors, timeouts, unknown formats and "unsure" answers withhold.
- **On-device only.** No network calls with message content, no server-side models.
- Keep the README short; details go in [docs/guide.md](docs/guide.md) and
  [docs/security-model.md](docs/security-model.md).

## Pull requests

Run `swift test` before opening one, and describe what an assistant can see or do differently after
your change. Security-sensitive bugs go through [SECURITY.md](SECURITY.md), not public issues.

## How the tests work

Tests never touch your real Messages data or send anything. `DemoData.swift` builds a fake
chat.db in which every private message contains the word `SECRET`. The leak tests run every
tool against every chat and check that `SECRET` never comes back, including through search,
reply threads, shared attachments, group membership, path traversal and tapbacks.
The content-filter tests plant card numbers, codes, bank details, IDs, passwords, keys, swearing and
sensitive topics in a fixture chat and check that none of it comes back from any tool, search, log
or ping. They use a fake classifier (including one that errors, hangs, refuses or answers "unsure").
The opt-in eval runs Apple's on-device model over made-up labelled messages and prints precision and
recall per category (`VEIL_EVAL_ENGINE=contentTagging` and `VEIL_EVAL_BATCH=n` compare variants).
The photo tests draw their own pictures with CoreGraphics (test card numbers, invented names) and use a
fake image model, including ones that error, hang, refuse, answer "unsure" or skip categories; text
recognition is the real Vision engine in a few of them. The photo eval runs the real engines over those
drawings plus the desktop and user pictures that ship with macOS, and prints recall per category, false
withholds and latency. Nothing explicit is generated; the nudity path is tested with fakes.
The Full Disk Access tests build a fake TCC.db, and run the real relay against a fixture file in place of
chat.db (`VEIL_CHAT_DB`, `VEIL_SOCKET`, `VEIL_NO_LAUNCH`). The one-click connect tests use a temp folder as
the home folder and a recording stand-in for the `claude` CLI; the real configs and CLI are never touched.

## Layout

```
Sources/VeilCore/          everything that touches data or enforces policy (no UI)
  Gate.swift               the policy: every MCP tool, filtering, logging, purge-on-revoke
  MessagesStore.swift      read-only chat.db queries, attributedBody text extraction
  Permissions.swift        per-chat settings, HMAC signing, Keychain key
  AgentSettings.swift      what the assistant may change (Ask me / Apply directly): parsing, validation, prompt lines
  GateSettings.swift       the settings tools and the approval flow
  MCPServer.swift          JSON-RPC / MCP protocol and tool schemas
  Transports.swift         Unix socket server, optional loopback HTTP
  Outbox.swift             drafts, send requests, AppleScript sender
  AccessLog.swift          activity log
  AutoSend.swift           auto-send history and per-chat rate limiter
  Activity.swift           metadata-only queries for "See activity" (no content columns)
  ContentFilter.swift      content filter: layers, fail-closed decisions, verdict cache, ContentClassifier protocol
  Detectors.swift          pattern detectors (cards/Luhn, codes, IBAN/sort code/routing, IDs, secrets, swearing)
  FilterPolicy.swift       filter categories, actions, strictness, profiles (signed with the permissions)
  AppleClassifier.swift    Apple on-device model engine (SystemLanguageModel, @Generable output)
  PhotoCheck.swift         photo checks: verdicts, content-hash cache, background queue, fail-closed decisions
  AppleImageClassifier.swift  on-device photo engines (model with image input, Vision OCR, SensitiveContentAnalysis)
  Webhook.swift            new-message watcher, ping coalescing, delivery and retries, ping log
  DatabaseWatcher.swift    kernel file events on chat.db and its WAL, so new messages wake Veil instead of polling
  Contacts.swift           name lookup
  DemoData.swift           fixture database for tests and demo mode
  ClientChecks.swift       relay hello, per-assistant Full Disk Access check, acknowledgements
  FullDiskAccess.swift     read-only TCC.db reader for apps with Full Disk Access (and a fixture builder)
  ConnectClients.swift     one-click connect: config merge/backup for Claude Desktop and Cursor, Claude Code CLI
  Migration.swift          one-time move from the app's earlier name (folder, settings, Keychain; fails closed)
Sources/Veil/              SwiftUI menu bar app (VeilGlyph.swift: the menu bar glyph)
Sources/veil-mcp/          stdio relay launched by the assistant (~100 lines)
Tests/VeilCoreTests/       leak, behavior, integrity, protocol and migration tests
```

Data files live in `~/Library/Application Support/Veil/`: `permissions.json`, `access-log.jsonl`, `webhook-log.jsonl`, `auto-sent.jsonl`, `client-checks.json` (per-assistant Full Disk Access check, no message data), `mcp.sock`.

## Icon

The build script makes `AppIcon.icns` from `Branding/icon/app/veil-icon-graphite.png` on every build (nothing generated is committed), and copies one PNG per other accent into `Contents/Resources/DockIcons` (graphite uses the app icon). The Dock icon follows *Settings → Accent* (Sage uses the forest colourway); the icon in Finder stays graphite. The menu bar glyph is drawn in code from the same vector paths (`Sources/Veil/VeilGlyph.swift`): dimmed when paused, with a dot while a send is waiting.

## Releasing (maintainers)

`VERSION=1.2.0 scripts/release.sh` builds `build/Veil-1.2.0.dmg`, signed with the first
"Developer ID Application" certificate in the login Keychain (hardened runtime, entitlements in
`scripts/Veil.entitlements`), notarizes it with the `veil-notary` notarytool profile, staples the
ticket and checks it with Gatekeeper. One-time setup for the profile:

```bash
xcrun notarytool store-credentials veil-notary --key AuthKey_XXXX.p8 --key-id XXXX --issuer <issuer id>
```

It also writes `build/appcast.xml`, the Sparkle update feed, signed with the EdDSA key stored in the
login Keychain under account `veil` (create it once with
`.build/artifacts/sparkle/Sparkle/bin/generate_keys --account veil`; the public half goes in
`SPARKLE_PUBLIC_KEY` in `scripts/build-app.sh`). Publish both files on a GitHub release tagged
`v<version>`; installed copies read `releases/latest/download/appcast.xml`.
