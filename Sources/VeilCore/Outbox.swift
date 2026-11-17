import Foundation

public struct Draft: Identifiable, Equatable, Sendable {
    public let id: String
    public let chatID: String
    public let chatName: String
    public let text: String
    public let created: Date
    public let client: String
}

public struct SendRequest: Identifiable, Equatable, Sendable {
    public enum Status: Equatable, Sendable {
        case waiting, sending, sent, declined, failed(String), cancelled(String)
        public var label: String {
            switch self {
            case .waiting: return "waiting_for_approval"
            case .sending: return "sending"
            case .sent: return "sent"
            case .declined: return "declined"
            case .failed(let m): return "failed: \(m)"
            case .cancelled(let m): return "cancelled: \(m)"
            }
        }
    }
    public let id: String
    public let chatID: String
    public let chatName: String
    public let text: String
    public let created: Date
    public let client: String
    public var status: Status
    /// Who it goes to, for the prompt: the handle of a one-to-one chat, or "Group: " and the members.
    /// A group's name is whatever any member typed, so the prompt doesn't rely on it alone.
    public var recipients: String = ""
}

/// Text from outside Veil (group names typed by any member, an assistant's name for itself) as Veil shows
/// it in prompts, notifications and Activity: no control, formatting or direction characters, nothing that
/// draws nothing, line breaks and runs of spaces folded to one space, no stacks of accents, and short.
public enum DisplayLabel {
    public static func clean(_ raw: String, max: Int) -> String {
        var out = "", pendingSpace = false
        for ch in raw {
            if ch.isWhitespace || ch.isNewline { pendingSpace = !out.isEmpty; continue }
            // A character that only carries hidden parts keeps its visible ones (an emoji keeps its joiners).
            var keep = String(ch)
            if Gate.hasHiddenText(keep) {
                keep = String(String.UnicodeScalarView(ch.unicodeScalars.filter { u in
                    let p = u.properties
                    return p.generalCategory != .control && p.generalCategory != .format && !p.isDefaultIgnorableCodePoint
                }.prefix(Gate.maxScalarsPerCharacter)))
            }
            guard !keep.isEmpty else { continue }
            if pendingSpace { out += " "; pendingSpace = false }
            out += keep
        }
        return out.count > max ? String(out.prefix(max - 1)) + "…" : out
    }

    /// "Group: Alex Chen, Sam Patel & 3 others", or the handle of a one-to-one chat.
    public static func recipients(_ c: Conversation) -> String {
        guard c.isGroup else { return clean(c.participants.first?.handle ?? c.id, max: 60) }
        let names = c.participants.map { clean($0.label, max: 40) }
        let shown = names.count <= 4 ? names : Array(names.prefix(3)) + ["\(names.count - 3) others"]
        return "Group: " + (shown.count > 1 ? shown.dropLast().joined(separator: ", ") + " & " + shown.last! : shown.joined())
    }
}

/// Something that can actually deliver a message. Only called after the user approves.
public protocol MessageSender: AnyObject {
    func send(_ text: String, toChatGUID guid: String) throws
}

/// Sends through Messages.app with AppleScript. Text and chat id are passed as
/// arguments (never spliced into the script), so message text can't inject code.
public final class AppleScriptSender: MessageSender {
    private let osascript: URL
    /// `osascript` is only replaced in tests, with a stand-in that never reaches Messages.
    public init(osascript: URL = URL(fileURLWithPath: "/usr/bin/osascript")) { self.osascript = osascript }

    public func send(_ text: String, toChatGUID guid: String) throws {
        let script = """
        on run argv
            tell application "Messages" to send (item 1 of argv) to chat id (item 2 of argv)
        end run
        """
        let p = Process()
        p.executableURL = osascript
        p.arguments = ["-e", script, text, guid]
        let err = Pipe(); p.standardError = err; p.standardOutput = FileHandle.nullDevice
        try p.run()
        // Read before waiting, so a long error can't fill the pipe and stall both sides.
        let output = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            throw NSError(domain: "Veil", code: Int(p.terminationStatus),
                          userInfo: [NSLocalizedDescriptionKey: Self.failureReason(String(decoding: output, as: UTF8.self))])
        }
    }

    /// Shown when macOS hasn't let Veil control Messages (the user said no, or never answered).
    public static let notAllowed = "Veil isn't allowed to control Messages. Turn on Messages under Veil in System Settings → Privacy & Security → Automation, then try again."

    /// What went wrong, in plain words, from osascript's error output. That output can quote the chat id or
    /// the message itself, and this goes to Activity and to the assistant, so only the error number is kept.
    public static func failureReason(_ stderr: String) -> String {
        let code = stderr.range(of: #"\((-?[0-9]+)\)\s*$"#, options: .regularExpression)
            .map { String(stderr[$0].filter { $0 == "-" || $0.isNumber }) }
        if code == "-1743" || stderr.contains("Not authorized to send Apple events") { return notAllowed }
        switch code {
        case "-1728": return "Messages couldn't find this chat. Open it in Messages once, then try again."
        case "-1712": return "Messages didn't answer in time, so Veil can't tell whether it went out. Check the chat in Messages before trying again."
        case let c?: return "Messages couldn't send it (error \(c))."
        case nil: return "Messages couldn't send it."
        }
    }
}

/// Used in tests and demo mode. Records instead of sending.
public final class RecordingSender: MessageSender {
    public private(set) var sent: [(String, String)] = []
    public init() {}
    public func send(_ text: String, toChatGUID guid: String) throws { sent.append((text, guid)) }
}
