import SwiftUI
import VeilCore
import Contacts

struct ConnectView: View {
    @EnvironmentObject var model: AppModel
    @State private var copied: String?

    var config: String {
        """
        {
          "mcpServers": {
            "veil": {
              "command": "\(model.bridgePath)"
            }
          }
        }
        """
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                PaneHeader(title: "Connect \(model.assistantName)",
                           subtitle: "Veil is an MCP server. \(model.assistantName) talks to it instead of reading Messages directly.")

                HStack(spacing: 8) {
                    Circle().fill(model.clients.isEmpty ? Color.secondary.opacity(0.4) : Theme.calm).frame(width: 8, height: 8)
                    Text(model.clients.isEmpty ? "Nothing connected right now" : "Connected: \(Set(model.clients).sorted().joined(separator: ", "))")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                    if let e = model.serverError { Text(e).font(.system(size: 12)).foregroundStyle(Theme.caution) }
                }

                BypassNotice()

                step(1, "Turn off \(model.assistantName)'s own Messages access",
                     "Otherwise it can still read everything without asking Veil. The same goes if the app it runs in has Full Disk Access; Veil tells you when it notices.")

                VStack(alignment: .leading, spacing: 10) {
                    step(2, "Add Veil as an MCP server", "Paste this into \(model.assistantName)'s MCP settings. It launches a tiny relay that only talks to this app.")
                    code(config, id: "config")
                }

                step(3, "Try it", "Ask \(model.assistantName): “Who's waiting on a reply from me?” Requests show up under Activity.")

                Divider().padding(.vertical, 4)

                VStack(alignment: .leading, spacing: 12) {
                    Toggle(isOn: Binding(get: { model.httpEnabled }, set: { model.httpEnabled = $0; model.applyHTTP() })) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Local web address (optional)").font(.system(size: 13, weight: .medium))
                            Text("For assistants that connect by URL instead of a command. Only this Mac can reach it, and it needs the key below.")
                                .font(.system(size: 12)).foregroundStyle(.secondary)
                        }
                    }.toggleStyle(.switch).tint(Theme.accent)
                    if model.httpEnabled {
                        code("http://127.0.0.1:\(model.httpPort)/mcp", id: "url")
                        code("Authorization: Bearer \(model.httpToken)", id: "token")
                        HStack {
                            if let e = model.httpError { Text(e).font(.system(size: 12)).foregroundStyle(Theme.caution) }
                            Spacer()
                            Button("New key") { model.rotateToken() }.buttonStyle(QuietButtonStyle())
                        }
                    }
                }
                Spacer()
            }
            .padding(28).frame(maxWidth: 640, alignment: .leading).frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    func step(_ n: Int, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(n)").font(.system(size: 12, weight: .semibold, design: .rounded)).foregroundStyle(Theme.accent)
                .frame(width: 22, height: 22).background(Theme.accent.opacity(0.12), in: Circle())
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 13, weight: .medium))
                Text(detail).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    func code(_ text: String, id: String) -> some View {
        HStack(alignment: .top) {
            Text(text).font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(copied == id ? "Copied" : "Copy") {
                model.copy(text); copied = id
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { if copied == id { copied = nil } }
            }.buttonStyle(QuietButtonStyle()).controlSize(.small)
        }
        .padding(12)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 0.5))
        .padding(.leading, 34)
    }
}

struct SetupView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                PaneHeader(title: "Setup & safety", subtitle: "What Veil needs, and how it keeps private chats private.")

                BypassNotice()

                Card {
                    check(model.diskAccessProblem == nil, "Full Disk Access",
                          model.diskAccessProblem == nil ? "Veil can read your Messages history." : "Needed to read Messages. Open Chats to set it up.",
                          action: diskAction)
                    Divider().padding(.leading, 46)
                    check(model.showsContactNames, "Contacts",
                          model.showsContactNames ? "Names appear instead of phone numbers." : "Optional. Shows names instead of phone numbers.",
                          action: contactsAction)
                    Divider().padding(.leading, 46)
                    check(true, "Sending", "The first time you approve a send, macOS asks to let Veil control Messages.", action: nil, neutral: true)
                    Divider().padding(.leading, 46)
                    integrityRow
                }

                if !model.clientChecks.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        SectionLabel(text: "Assistants that connected")
                        ClientChecksList()
                    }
                }

                FullDiskAccessSection()

                VStack(alignment: .leading, spacing: 10) {
                    SectionLabel(text: "How it works")
                    Card(padding: 18) {
                        VStack(alignment: .leading, spacing: 12) {
                            bullet("lock", "Your settings live only on this Mac and can only be changed here. \(model.assistantName) has no way to change them.")
                            bullet("line.3.horizontal.decrease", "Filtering happens inside Veil before anything is handed over. Locked chats show just a name and number.")
                            bullet("hand.raised", "Nothing is ever sent without you clicking Send on that exact message.")
                            bullet("arrow.uturn.backward", "Turning a chat off takes effect on the very next request and clears drafts and unsent requests for it.")
                            bullet("signature", "Your settings file is signed with a key in your Keychain. If anything else edits it, everything switches off until you look.")
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 10) {
                    SectionLabel(text: "Good to know")
                    Card(padding: 18) {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Anything \(model.assistantName) has already seen may be kept in its own conversation history. Veil can't reach in and delete that.")
                            Text("Any app with Full Disk Access can read Messages directly, and Veil's limits don't apply to that. Veil checks each assistant when it connects and tells you here if the app it runs in has Full Disk Access. Assistants on the local web address can't be checked.")
                        }.font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                }
            }
            .padding(28).frame(maxWidth: 640, alignment: .leading).frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear { if model.mode == .live { model.refreshFullDiskAccess() } }
    }

    typealias Action = (String, () -> Void)

    var diskAction: Action? {
        guard model.diskAccessProblem != nil else { return nil }
        return ("Open Settings", { Self.openSettings("Privacy_AllFiles") })
    }

    var contactsAction: Action? {
        guard model.mode == .live else { return nil }
        switch model.contactsStatus {
        case .notDetermined: return ("Allow", { model.requestContacts() })
        case .denied, .restricted: return ("Open Settings", { Self.openSettings("Privacy_Contacts") })
        default: return nil
        }
    }

    static func openSettings(_ anchor: String) {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)")!)
    }

    @ViewBuilder var integrityRow: some View {
        switch model.integrity {
        case .tampered(let why) where model.signingKeyMissing:
            VStack(alignment: .leading, spacing: 0) {
                check(false, "Your settings are locked",
                      model.legacyKeyAvailable
                        ? "\(why) Veil was called \(Legacy.name) before, and its key couldn't be brought over without your OK. Everything is off until you import it or start fresh."
                        : "\(why) Everything is off until you start fresh.",
                      action: Action("Start fresh", { model.resetPermissions() }))
                if model.legacyKeyAvailable {
                    HStack(spacing: 10) {
                        Text("Importing keeps your chat settings. macOS will ask you to allow Veil to use the old key.")
                            .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        Spacer()
                        Button(model.importingLegacyKeys ? "Importing…" : "Import from \(Legacy.name)") { model.importLegacyKeys() }
                            .buttonStyle(PrimaryButtonStyle()).disabled(model.importingLegacyKeys)
                    }
                    .padding(.leading, 46).padding(.trailing, 14).padding(.bottom, 12)
                }
            }
        case .tampered(let why):
            check(false, "Settings were changed outside Veil", "\(why) Everything is off until you start fresh.",
                  action: Action("Start fresh", { model.resetPermissions() }))
        default:
            check(true, "Settings are intact", "Signed and verified.", action: nil)
        }
    }

    func check(_ ok: Bool, _ title: String, _ detail: String, action: Action?, neutral: Bool = false) -> some View {
        HStack(spacing: 12) {
            Image(systemName: neutral ? "info.circle" : ok ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .font(.system(size: 17))
                .foregroundStyle(neutral ? Color.secondary : ok ? Theme.calm : Theme.caution)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .medium))
                Text(detail).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if let action { Button(action.0, action: action.1).buttonStyle(QuietButtonStyle()) }
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
    }

    func bullet(_ icon: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon).font(.system(size: 12)).foregroundStyle(Theme.accent).frame(width: 18)
            Text(text).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
        }
    }
}
