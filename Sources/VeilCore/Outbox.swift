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
    public init() {}
    public func send(_ text: String, toChatGUID guid: String) throws {
        let script = """
        on run argv
            tell application "Messages" to send (item 1 of argv) to chat id (item 2 of argv)
        end run
        """
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", script, text, guid]
        let err = Pipe(); p.standardError = err; p.standardOutput = Pipe()
        try p.run(); p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            let msg = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            throw NSError(domain: "Veil", code: Int(p.terminationStatus),
                          userInfo: [NSLocalizedDescriptionKey: msg.isEmpty ? "Messages couldn't send it." : msg])
        }
    }
}

/// Used in tests and demo mode. Records instead of sending.
public final class RecordingSender: MessageSender {
    public private(set) var sent: [(String, String)] = []
    public init() {}
    public func send(_ text: String, toChatGUID guid: String) throws { sent.append((text, guid)) }
}
