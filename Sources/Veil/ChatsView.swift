import SwiftUI
import VeilCore

struct ChatsView: View {
    @EnvironmentObject var model: AppModel
    @Binding var selection: String?
    @State private var query = ""
    @State private var showAllNew = false
    /// New chats beyond this many collapse behind "Show all", so shared chats stay in reach.
    private let newPreview = 6

    var body: some View {
        HStack(spacing: 0) {
            list.frame(width: 300)
            Divider().opacity(0.5)
            if let id = selection, let chat = model.conversations.first(where: { $0.id == id }) {
                ChatDetail(chat: chat).id(chat.id)
            } else {
                emptyDetail
            }
        }
        .onAppear { if selection == nil { selection = (model.conversations.first(where: { model.access($0.id).anyEnabled }) ?? model.newChats.first ?? model.conversations.first)?.id } }
    }

    private var filtered: [Conversation] {
        guard !query.isEmpty else { return model.conversations }
        return model.conversations.filter { c in
            c.displayName.localizedCaseInsensitiveContains(query) || c.participants.contains { $0.handle.contains(query) || ($0.name ?? "").localizedCaseInsensitiveContains(query) }
        }
    }

    var list: some View {
        // Anything with access on counts as shared, reviewed or not, so it can never hide among "new".
        let shared = filtered.filter { model.access($0.id).anyEnabled }
        let new = filtered.filter { !model.state.reviewed.contains($0.id) && !model.access($0.id).anyEnabled }
        let collapse = query.isEmpty && !showAllNew && new.count > newPreview
        let priv = filtered.filter { model.state.reviewed.contains($0.id) && !model.access($0.id).anyEnabled }
        return VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search chats", text: $query).textFieldStyle(.plain)
                if !query.isEmpty { Button { query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary) }.buttonStyle(.plain) }
            }
            .font(.system(size: 13))
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 0.5))
            .padding(.horizontal, 14).padding(.top, 16).padding(.bottom, 10)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    if let problem = model.readProblem {
                        Text("Couldn't read Messages just now, so this list may be out of date. \(model.assistantName) gets nothing until it works again. (\(problem))")
                            .font(.system(size: 11)).foregroundStyle(Theme.caution).fixedSize(horizontal: false, vertical: true)
                            .padding(10).background(Theme.caution.opacity(0.08), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                            .padding(.bottom, 8)
                    }
                    if !model.showsContactNames { contactsBanner }
                    if !shared.isEmpty {
                        SectionLabel(text: "Shared with \(model.assistantName)").padding(.horizontal, 10).padding(.top, 4).padding(.bottom, 4)
                        ForEach(shared) { row($0) }
                    }
                    if !new.isEmpty {
                        newBanner(new).padding(.top, shared.isEmpty ? 0 : 14)
                        ForEach(collapse ? Array(new.prefix(newPreview)) : new) { row($0, isNew: true) }
                        if collapse {
                            Button("Show all \(new.count) new chats") { showAllNew = true }
                                .buttonStyle(.plain).font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.accent)
                                .padding(.horizontal, 10).padding(.vertical, 6)
                        } else if showAllNew && query.isEmpty && new.count > newPreview {
                            Button("Show fewer") { showAllNew = false }
                                .buttonStyle(.plain).font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                                .padding(.horizontal, 10).padding(.vertical, 6)
                        }
                    }
                    if !priv.isEmpty {
                        SectionLabel(text: "Private").padding(.horizontal, 10).padding(.top, 14).padding(.bottom, 4)
                        ForEach(priv) { row($0) }
                    }
                    if filtered.isEmpty {
                        Text(query.isEmpty ? "No chats yet." : "No chats match “\(query)”.")
                            .font(.system(size: 12)).foregroundStyle(.secondary).padding(20)
                    }
                }
                .padding(.horizontal, 8).padding(.bottom, 12)
            }
        }
    }

    var contactsBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "person.crop.circle").font(.system(size: 18)).foregroundStyle(Theme.accent)
            VStack(alignment: .leading, spacing: 2) {
                Text("Show names, not numbers").font(.system(size: 12, weight: .semibold))
                Text("Let Veil look up names in Contacts. They stay on this Mac.")
                    .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 4)
            Button(model.contactsStatus == .notDetermined ? "Allow" : "Settings") {
                if model.contactsStatus == .notDetermined { model.requestContacts() }
                else { SetupView.openSettings("Privacy_Contacts") }
            }.buttonStyle(QuietButtonStyle()).controlSize(.small)
        }
        .padding(10)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 0.5))
        .padding(.horizontal, 2).padding(.bottom, 8)
    }

    func newBanner(_ new: [Conversation]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("New chats · \(new.count)").font(.system(size: 12, weight: .semibold))
                Spacer()
                Button("Keep all private") { model.markReviewed(new.map(\.id)) }
                    .buttonStyle(.plain).font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.accent)
            }
            Text("These stay private until you choose. \(model.assistantName) can only see the name and number.")
                .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .background(Theme.accent.opacity(0.07), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .padding(.horizontal, 2).padding(.bottom, 4)
    }

    func row(_ c: Conversation, isNew: Bool = false) -> some View {
        let a = model.access(c.id)
        let selected = selection == c.id
        return Button { selection = c.id } label: {
            HStack(spacing: 10) {
                Avatar(name: c.displayName, isGroup: c.isGroup, size: 30)
                VStack(alignment: .leading, spacing: 1) {
                    Text(c.displayName).font(.system(size: 13, weight: .medium)).lineLimit(1)
                    Text(isNew ? "New · nothing shared" : summary(a)).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 4)
                if isNew { Circle().fill(Theme.accent).frame(width: 7, height: 7) }
                else if a.hidden { Image(systemName: "eye.slash").font(.system(size: 11)).foregroundStyle(.tertiary) }
            }
            .padding(.horizontal, 8).padding(.vertical, 6)
            .background(selected ? Theme.card : .clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(selected ? Theme.hairline : .clear, lineWidth: 0.5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    func summary(_ a: ChatAccess) -> String {
        if a.hidden { return "Hidden" }
        var parts: [String] = []
        if a.read { parts.append("Read") } else if a.activity { parts.append("Activity") }
        if a.waiting { parts.append("Waiting") }
        if a.draft { parts.append("Drafts") }
        if a.send { parts.append(a.autoSend ? "Auto-send" : "Send") }
        if a.attachments { parts.append("Photos") }
        if a.filtered && !parts.isEmpty { parts.append("Filtered") }
        return parts.isEmpty ? "Private" : parts.joined(separator: " · ")
    }

    var emptyDetail: some View {
        VStack(spacing: 8) {
            Image(systemName: "bubble.left.and.bubble.right").font(.system(size: 28, weight: .light)).foregroundStyle(.tertiary)
            Text("Choose a chat").foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct ChatDetail: View {
    @EnvironmentObject var model: AppModel
    let chat: Conversation
    @State private var confirmAutoSend = false

    var body: some View {
        let a = model.access(chat.id)
        let name = model.assistantName
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack(spacing: 14) {
                    Avatar(name: chat.displayName, isGroup: chat.isGroup, size: 48)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(chat.displayName).font(.system(size: 20, weight: .semibold))
                        Text(chat.subtitle).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(2)
                    }
                    Spacer()
                    if let d = chat.lastActivity { Text(d.relative).font(.system(size: 11)).foregroundStyle(.tertiary) }
                }

                if !model.state.reviewed.contains(chat.id) {
                    HStack(spacing: 10) {
                        Image(systemName: "sparkle").foregroundStyle(Theme.accent)
                        Text("New chat. Everything is off until you decide.").font(.system(size: 12))
                        Spacer()
                        Button("Keep private") { model.markReviewed([chat.id]) }.buttonStyle(QuietButtonStyle())
                    }
                    .padding(12)
                    .background(Theme.accent.opacity(0.07), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }

                VStack(alignment: .leading, spacing: 8) {
                    SectionLabel(text: "What \(name) can do here")
                    Card {
                        ToggleRow(icon: "text.bubble", title: "Read & summarize",
                                  detail: "Read messages in this chat, including its full history.",
                                  isOn: model.binding(chat.id, \.read), disabled: a.hidden)
                        Divider().padding(.leading, 60)
                        ToggleRow(icon: "clock", title: "See activity (no content)",
                                  detail: a.read ? "Included with Read. Turn Read off to share only when messages come and go."
                                                 : "When messages come and go, and who sent them. Never what they say.",
                                  isOn: model.binding(chat.id, \.activity), disabled: a.hidden)
                        Divider().padding(.leading, 60)
                        ToggleRow(icon: "hourglass", title: "Notice who's waiting",
                                  detail: "Point out when the last message is theirs and you haven't replied.",
                                  isOn: model.binding(chat.id, \.waiting), disabled: a.hidden)
                        Divider().padding(.leading, 60)
                        ToggleRow(icon: "square.and.pencil", title: "Write drafts",
                                  detail: "Suggest replies. Drafts wait here for you. Nothing is sent.",
                                  isOn: model.binding(chat.id, \.draft), disabled: a.hidden)
                        Divider().padding(.leading, 60)
                        ToggleRow(icon: "paperplane", title: "Send with your OK",
                                  detail: "Ask to send a message. You approve each one before it goes.",
                                  isOn: model.binding(chat.id, \.send), disabled: a.hidden)
                        if a.send && !a.hidden {
                            Divider().padding(.leading, 60)
                            ToggleRow(icon: "bolt", title: "Auto-send without asking",
                                      detail: autoSendDetail,
                                      isOn: Binding(get: { a.autoSend },
                                                    set: { on in if on { confirmAutoSend = true } else { model.setAutoSend(false, for: chat.id) } }))
                        }
                        Divider().padding(.leading, 60)
                        ToggleRow(icon: "photo.on.rectangle", title: "See photos & files",
                                  detail: "Open pictures and attachments shared in this chat.",
                                  isOn: model.binding(chat.id, \.attachments), disabled: a.hidden)
                    }
                    if a.draft && !a.read && !a.hidden {
                        Text("Tip: drafts are usually better when \(name) can also read the chat.")
                            .font(.system(size: 11)).foregroundStyle(.secondary).padding(.leading, 4)
                    }
                }

                ChatFilterSection(chat: chat)

                Card {
                    ToggleRow(icon: "eye.slash", title: "Hide this chat completely",
                              detail: "\(name) won't see that this chat exists, not even the name.",
                              isOn: model.binding(chat.id, \.hidden))
                }

                HStack(spacing: 10) {
                    Button("Allow all but sending") {
                        // Keeps the content filter (and its settings) as they are.
                        var all = a.allOffKeepingFilter
                        all.read = true; all.waiting = true; all.draft = true; all.attachments = true
                        model.setAccess(all, for: chat.id)
                    }.buttonStyle(QuietButtonStyle())
                    Button("Turn everything off") { model.setAccess(a.allOffKeepingFilter, for: chat.id) }
                        .buttonStyle(QuietButtonStyle())
                    Spacer()
                }
                .disabled(a.hidden)

                Text(footnote(a)).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .padding(28)
            .frame(maxWidth: 620, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .alert("Let \(name) send to \(chat.displayName) without asking?", isPresented: $confirmAutoSend) {
            Button("Turn on auto-send") { model.setAutoSend(true, for: chat.id) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Text messages \(name) asks to send here will go out immediately, up to \(model.limitText). Past that, or with photos or files, you'll be asked as usual. Every auto-sent message is listed under Activity → Auto-sent.")
        }
    }

    var autoSendDetail: String {
        if model.state.autoSendStopped { return "Stopped for every chat. Turn auto-send back on from the menu bar." }
        return "Text goes out right away, up to \(model.limitText). Past that, you'll be asked."
    }

    func footnote(_ a: ChatAccess) -> String {
        if a.hidden { return "This chat is invisible to \(model.assistantName)." }
        if !a.anyEnabled { return "Right now \(model.assistantName) can only see that this chat exists, with its name and number." }
        return "Changes apply instantly. Turning something off also clears any drafts or unsent requests for it."
    }
}
