import Foundation
@testable import VeilCore

typealias ID = DemoData.ID

/// A fresh fixture database + gate per test. Nothing here touches the real Messages data.
final class Harness {
    let dir: URL
    let gate: Gate
    let server: MCPServer
    let sender = RecordingSender()
    let secrets = MemorySecretStore()
    let permissionsURL: URL

    init(access: [String: ChatAccess] = Harness.defaultAccess, sender custom: MessageSender? = nil,
         autoSends: ((URL) -> AutoSendHistory)? = nil, classifier: ContentClassifier? = nil,
         imageClassifier: ImageClassifier? = nil, recognizer: TextRecognizer? = VisionTextRecognizer(),
         nudity: NudityDetector? = nil) throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("veil-test-\(UUID().uuidString)")
        let (db, atts) = try DemoData.build(at: dir)
        permissionsURL = dir.appendingPathComponent("permissions.json")
        let store = PermissionStore(url: permissionsURL, secrets: secrets)
        gate = Gate(permissions: store, log: AccessLog(url: dir.appendingPathComponent("access.jsonl")),
                    contacts: StaticContacts(DemoData.contacts), sender: custom ?? sender,
                    autoSends: autoSends?(dir) ?? AutoSendHistory(url: dir.appendingPathComponent("auto-sent.jsonl")),
                    classifier: classifier, imageClassifier: imageClassifier, textRecognizer: recognizer, nudityDetector: nudity,
                    openStore: { try MessagesStore(databasePath: db.path, attachmentsRoot: atts) })
        for (id, a) in access { try gate.setAccess(a, for: id) }
        server = MCPServer(gate: gate)
    }

    deinit { try? FileManager.default.removeItem(at: dir) }

    /// Mom: everything. Alex: read/waiting/draft. Climbing: read+waiting. Therapist, Family, Unknown: nothing.
    static let defaultAccess: [String: ChatAccess] = [
        ID.mom: ChatAccess(read: true, waiting: true, draft: true, send: true, attachments: true),
        ID.alex: ChatAccess(read: true, waiting: true, draft: true),
        ID.climbing: ChatAccess(read: true, waiting: true),
    ]

    struct Out {
        let result: ToolResult
        var text: String { result.content.compactMap { $0["text"]?.string }.joined(separator: "\n") }
        var raw: String { JSON.array(result.content).encoded() }
        var json: JSON { JSON.parse(Data((result.content.first?["text"]?.string ?? "null").utf8)) ?? .null }
        var isError: Bool { result.isError }
    }

    @discardableResult
    func call(_ tool: String, _ args: JSON = [:]) -> Out { Out(result: gate.call(tool: tool, arguments: args, client: "Test")) }
}

/// Marker present in every private message, chat file name and photo name in the fixture.
let secret = "SECRET"
