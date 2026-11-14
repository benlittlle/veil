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
- The MCP surface has no permission-changing tool. Permission changes exist only as methods the UI calls. The same goes for webhook settings.
- New-message pings contain ids, a timestamp and a direction only, go only to chats with *Read* or *See activity* on (your own messages only with *See activity*), are checked again before every attempt, require HTTPS, and keep the key in the Keychain.
- `permissions.json` is signed with HMAC-SHA256. The key and a generation counter live in your login Keychain. If the file is edited or swapped for an older copy, Veil treats every chat as off and shows a warning until you start fresh.
- Content filter (per chat, off by default): every content-returning path in the gate goes through it for filtered chats, after the permission check and before anything is returned. Anything without a decision is withheld. Search matches filtered text only. Its settings and your overrides (messages and photos) are part of the signed `permissions.json`; no MCP tool reads or changes them, and the review screen exists only in the app. Judgement uses Apple's on-device model only. Verdicts are cached in memory only, never text or pixels.
- Photo checks: in Check mode a photo is returned only after it passed for every filtered chat it appears in (on top of the every-chat-allows-attachments rule). Unchecked, failed, refused, unreadable, oversized and non-photo files are all withheld, with the same answer to the assistant as a missing attachment.
- The Unix socket is mode `0600` in a `0700` folder.

## Limits

- Anything with Full Disk Access can read chat.db directly. The gate only helps if the assistant doesn't have it and its own Messages integration is off.
- Once the assistant has seen something, it may keep it in its own history. Veil can't recall it.
- The gate trusts processes running as you to the same degree macOS does. Any of your processes can connect to the socket. It still only gets what your switches allow, and every request is logged.
- The access log is a plain file (`~/Library/Application Support/Veil/access-log.jsonl`). It isn't tamper-proof. Search queries are logged as the assistant typed them.
- A request already being answered when you flip a switch finishes with the settings it started with (milliseconds).
- **Auto-send trusts the assistant.** In an auto-send chat, anything the assistant decides to send goes out, including if someone manipulates it through a message it reads (prompt injection). The rate limit caps the damage but doesn't prevent it. Use auto-send only for low-stakes chats.
- The auto-send history holds message text in a plain file. It's kept when you turn a chat off, so you keep a record of what went out in your name. Clear it from *Activity → Auto-sent*.
- *See activity* is still revealing. Who you talk to, when, and how fast you reply says a lot even without the words. Turn it on only where that's fine.
- A ping tells the webhook's server that a given chat (a phone number, email or group id) just got a message. Only turn pings on for a webhook you trust.
- Group names and member names/numbers of locked groups are visible, as designed. Use *Hide this chat* for chats whose existence is private.
- **The content filter is a risk reduction, not a guarantee.** Pattern matching, text recognition and a small on-device model all miss things and all make mistakes; prompt injection inside a message or drawn into a photo can mislead the model. Photo checks look at a GIF's first frame only, and videos are never shared in Check mode. Only *Read* off (and *Photos & files* off or Withhold) is certain.
- Message text is extracted from Apple's `attributedBody` format with a small parser (no object deserialization). Unusual messages may come through with no text.
