# Security model

What Veil enforces, and what it can't. To report a way past the gate, see [SECURITY.md](../SECURITY.md).

## Enforced in code

- Veil opens `chat.db` read-only (`SQLITE_OPEN_READONLY` + `PRAGMA query_only`).
- Every query that returns content is scoped to an explicit list of chat row ids that passed the policy check. Filtering happens before anything leaves the app.
- Locked chats appear with name and participants only. Hidden chats don't appear at all, and asking for them gives the same answer as a chat that doesn't exist.
- *See activity* returns ids, times, direction and (in groups) the sender only, from queries that never select text or attachment columns. Every content tool still requires its own switch.
- Search covers only chats with *Read* on. Reply quotes resolve only inside the same chat. Tapbacks (which quote other messages) and system events are dropped.
- An attachment is returned only if **every** chat it appears in allows attachments, and its file path must resolve (after symlinks) inside `~/Library/Messages/Attachments`.
- Turning a switch off takes effect on the next request and purges drafts and waiting send requests for that chat. Veil caches no message content; drafts and send requests are kept in memory only.
- Auto-send is per chat, off by default, needs *Send* on, is re-checked against the live settings for each request, and is rate-limited per chat. It covers plain text only, and every message is recorded with its text. A kill switch and *Pause everything* both stop it. Without it, every send needs your click.
- Sending re-checks the *Send* switch at the moment you click Send, then runs `osascript` with the text and chat id as **arguments**, never spliced into the script.
- The send prompt never takes keyboard focus and its Send button only becomes clickable after a moment, so a stray Return or click meant for another app can't approve anything. A request can only be sent once, even with a double click.
- Messages to approve are capped at 2000 characters and 20 line breaks, and may not contain invisible or direction-changing characters, so what you see in the prompt is the whole message. At most 3 can wait for approval at once.
- The assistant names itself, so that name is treated as untrusted (it can't call itself "You"). The prompt uses the assistant name you set.
- `list_chats` sorts locked chats by name, so their order doesn't hint at new activity.
- "Assistant can change settings" is **Off** by default, and then the MCP surface has no settings tool: none is listed, and calling one gets the same answer as an unknown tool. The mode lives in the signed `permissions.json` (left out of the file while Off, so files signed before it existed still verify), and only the app changes it.
- With *Ask me* or *Apply directly*, five settings tools appear. They can change per-chat switches, per-chat filter settings, auto-send (per chat, the switch for every chat, the rate limit), pause, the assistant name and the ping switches. They can't reach the mode itself, hidden chats (same answer as a made-up id; no way to unhide), the webhook address/header/key, the local web address or its key, the signing key, the default filter profile, your review choices, or the app's look. Arguments are checked strictly: unknown keys and invalid combinations (such as auto-send without *Send*) are refused and nothing changes.
- Settings changes go through the same code as the app's switches, so turning something off purges drafts and waiting sends the same way. Each request is applied in one signed write.
- In *Ask me*, the prompt has the send prompt's protections: no keyboard focus, a delay before **Allow** works, one approval per request, at most 3 waiting, expiry after 10 minutes, and the assistant's self-chosen name shown only as a cleaned-up label. On **Allow**, Veil re-checks the live state (mode not Off, not paused, not locked, chat present and not hidden) before applying.
- Allowing PINs & verification codes (including turning the filter off where it masks them) always needs the user's approval, even in *Apply directly*. While Veil is paused or locked, every settings tool is refused, so the assistant can pause but never unpause. Every request and outcome is logged, without message content.
- Webhook settings are never reachable from MCP.
- New-message pings contain ids, a timestamp and a direction only, go only to chats with *Read* or *See activity* on (your own messages only with *See activity*), are checked again before every attempt, require HTTPS, and keep the key in the Keychain.
- `permissions.json` is signed with HMAC-SHA256. The key and a generation counter live in your login Keychain. If the file is edited or swapped for an older copy, Veil treats every chat as off and shows a warning until you start fresh.
- Content filter (per chat, off by default): every content-returning path in the gate goes through it for filtered chats, after the permission check and before anything is returned. Anything without a decision is withheld. Search matches filtered text only. Its settings and your overrides (messages and photos) are part of the signed `permissions.json`. No MCP tool reads or changes them unless you allow settings changes, and even then only a chat's own filter settings are reachable; your overrides and the review screen exist only in the app. Judgement uses Apple's on-device model only. Verdicts are cached in memory only, never text or pixels.
- Photo checks: in Check mode a photo is returned only after it passed for every filtered chat it appears in (on top of the every-chat-allows-attachments rule). Unchecked, failed, refused, unreadable, oversized and non-photo files are all withheld, with the same answer to the assistant as a missing attachment.
- The Unix socket is mode `0600` in a `0700` folder.
- The relay never reads chat.db. At startup it calls `open()` on it read-only and closes it immediately, only to learn whether the assistant's app could read it, and sends that yes/no as its first line (`veil/relayHello`, a JSON-RPC notification). Veil only accepts it as the very first line of a socket session, so an assistant can't send its own later. Older Veil versions ignore it; the assistant never sees it.
- Veil reads `TCC.db` read-only (`SQLITE_OPEN_READONLY` + `PRAGMA query_only`) to list apps with Full Disk Access. It never writes to it.
- One-click connect writes a client config only after you confirm the exact change, backs the file up first, leaves other keys alone, and refuses invalid JSON or a file that changed since you reviewed it. Claude Code is changed only through its own CLI.

## Limits

- Anything with Full Disk Access can read chat.db directly, and Veil's limits only apply to what an assistant asks Veil for. Veil can tell you when an assistant's app has it; it can't stop that access.
- The Full Disk Access check is informational. It reflects the moment the assistant connected, is keyed by the name the assistant gives itself, and any process of yours that connects to the socket can claim either answer. Assistants on the local web address, and relays from before the check, can't be checked. "Don't warn me again" is stored in your app preferences, not signed.
- The list of other apps with Full Disk Access depends on the `TCC.db` layout and is hidden when Veil can't read it. It may not show everything macOS allows (for example, access granted by a device-management profile).
- Once the assistant has seen something, it may keep it in its own history. Veil can't recall it.
- The gate trusts processes running as you to the same degree macOS does. Any of your processes can connect to the socket. It still only gets what your switches allow, and every request is logged.
- The access log is a plain file (`~/Library/Application Support/Veil/access-log.jsonl`). It isn't tamper-proof. Search queries are logged as the assistant typed them.
- A request already being answered when you flip a switch finishes with the settings it started with (milliseconds).
- **Auto-send trusts the assistant.** In an auto-send chat, anything the assistant decides to send goes out, including if someone manipulates it through a message it reads (prompt injection). The rate limit caps the damage but doesn't prevent it. Use auto-send only for low-stakes chats.
- The auto-send history holds message text in a plain file. It's kept when you turn a chat off, so you keep a record of what went out in your name. Clear it from *Activity → Auto-sent*.
- **Apply directly trusts the assistant with your settings.** A message it reads can try to talk it into opening up a chat, turning off a filter or turning on auto-send (prompt injection). The change happens before you see it; the notification and Activity tell you afterwards, when the assistant may already have read what you meant to keep private. Allowing codes still asks, and hidden chats stay out of reach, but everything else in the list above is one tool call away. *Ask me* keeps every change behind your click, though a convincing request can still talk you into allowing it.
- *See activity* is still revealing. Who you talk to, when, and how fast you reply says a lot even without the words. Turn it on only where that's fine.
- A ping tells the webhook's server that a given chat (a phone number, email or group id) just got a message. Only turn pings on for a webhook you trust.
- Group names and member names/numbers of locked groups are visible, as designed. Use *Hide this chat* for chats whose existence is private.
- **The content filter is a risk reduction, not a guarantee.** Pattern matching, text recognition and a small on-device model all miss things and all make mistakes; prompt injection inside a message or drawn into a photo can mislead the model. Photo checks look at a GIF's first frame only, and videos are never shared in Check mode. Only *Read* off (and *Photos & files* off or Withhold) is certain.
- Message text is extracted from Apple's `attributedBody` format with a small parser (no object deserialization). Unusual messages may come through with no text.
