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
            case .declined: return "declined_by_ben"
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
