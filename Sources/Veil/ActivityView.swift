import SwiftUI
import VeilCore

struct ActivityView: View {
    @EnvironmentObject var model: AppModel
    enum Filter { case all, blocked, autoSent }
    @State private var filter: Filter
    init(filter: Filter = .all) { _filter = State(initialValue: filter) }
    @State private var query = ""

    var body: some View {
        if filter == .autoSent { autoSentBody } else { logBody }
    }

    var picker: some View {
        Picker("", selection: $filter) {
            Text("All").tag(Filter.all)
            Text("Blocked").tag(Filter.blocked)
            Text("Auto-sent").tag(Filter.autoSent)
        }.pickerStyle(.segmented).labelsHidden().frame(width: 230)
    }

    var filterField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField(filter == .autoSent ? "Filter by chat or text" : "Filter by chat or action", text: $query).textFieldStyle(.plain)
        }
        .font(.system(size: 13)).padding(.horizontal, 10).padding(.vertical, 7)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 0.5))
    }

    /// Every message sent without a prompt, with its full text.
    var autoSentBody: some View {
        let items = model.autoSendHistory.reversed().filter { r in
            query.isEmpty || [r.chatName, r.text].contains { $0.localizedCaseInsensitiveContains(query) }
        }
        let days = Dictionary(grouping: items) { Calendar.current.startOfDay(for: $0.date) }.sorted { $0.key > $1.key }
        return VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .bottom) {
                PaneHeader(title: "Activity", subtitle: "Messages \(model.assistantName) sent without asking, in chats set to auto-send.")
                Spacer()
                picker
                Button("Clear") { model.clearAutoSendHistory() }.buttonStyle(QuietButtonStyle()).disabled(model.autoSendHistory.isEmpty)
            }
            filterField
            if items.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "bolt").font(.system(size: 26, weight: .light)).foregroundStyle(.tertiary)
                    Text(model.autoSendHistory.isEmpty ? "Nothing has been auto-sent." : "No matching messages.")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 18) {
                        ForEach(days, id: \.key) { day, rows in
                            VStack(alignment: .leading, spacing: 8) {
                                SectionLabel(text: day.formatted(.dateTime.weekday(.wide).month().day()))
                                Card {
                                    ForEach(Array(rows.enumerated()), id: \.element.id) { i, r in
                                        if i > 0 { Divider().padding(.leading, 56) }
                                        AutoSentRow(record: r)
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        .padding(28)
    }

    @ViewBuilder var logBody: some View {
        let onlyBlocked = filter == .blocked
        let entries = model.log.reversed().filter { e in
            (!onlyBlocked || e.outcome != .allowed) &&
            (query.isEmpty || [e.chatName ?? "", e.summary, e.client, ActivityRow.verb(e.tool)].contains { $0.localizedCaseInsensitiveContains(query) })
        }
        let days = Dictionary(grouping: entries) { Calendar.current.startOfDay(for: $0.date) }.sorted { $0.key > $1.key }

        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .bottom) {
                PaneHeader(title: "Activity", subtitle: "Every request \(model.assistantName) makes, and what it got back.")
                Spacer()
                picker
                Button("Clear") { model.clearLog() }.buttonStyle(QuietButtonStyle()).disabled(model.log.isEmpty)
            }
            filterField

            if entries.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "clock").font(.system(size: 26, weight: .light)).foregroundStyle(.tertiary)
                    Text(model.log.isEmpty ? "Nothing yet. Requests will show up here as they happen." : "No matching activity.")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 18) {
                        ForEach(days, id: \.key) { day, items in
                            VStack(alignment: .leading, spacing: 8) {
                                SectionLabel(text: day.formatted(.dateTime.weekday(.wide).month().day()))
                                Card {
                                    ForEach(Array(items.enumerated()), id: \.element.id) { i, e in
                                        if i > 0 { Divider().padding(.leading, 56) }
                                        ActivityRow(entry: e)
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        .padding(28)
    }
}

struct AutoSentRow: View {
    let record: AutoSendRecord
    var body: some View {
        let ok = record.outcome == .sent
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: ok ? "bolt.fill" : "exclamationmark.triangle")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(ok ? Theme.accent : Theme.caution)
                .frame(width: 28, height: 28)
                .background((ok ? Theme.accent : Theme.caution).opacity(0.12), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(ok ? "Sent to" : "Couldn't send to").font(.system(size: 13, weight: .medium))
                    Text(record.chatName).font(.system(size: 13)).foregroundStyle(.secondary).lineLimit(1)
                    if !ok { Pill(text: "Failed", color: Theme.caution) }
                }
                Text(record.text).font(.system(size: 13)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                if let d = record.detail { Text(d).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2) }
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 2) {
                Text(record.date.clock).font(.system(size: 11)).foregroundStyle(.tertiary)
                Text(record.client).font(.system(size: 11)).foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
    }
}

struct ActivityRow: View {
    let entry: LogEntry
    var compact = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: autoSent ? "bolt.fill" : Self.icon(entry.tool))
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(entry.outcome == .allowed ? Color.secondary : Theme.caution)
                .frame(width: 28, height: 28)
                .background(entry.outcome == .allowed ? Theme.subtle : Theme.caution.opacity(0.12), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(autoSent ? "Auto-sent to" : Self.verb(entry.tool)).font(.system(size: 13, weight: .medium))
                    if let c = entry.chatName { Text(c).font(.system(size: 13)).foregroundStyle(.secondary).lineLimit(1) }
                    if entry.outcome == .denied { Pill(text: "Blocked", color: Theme.caution) }
                    if entry.outcome == .failed { Pill(text: "Error", color: Theme.caution) }
                }
                Text(entry.summary).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(compact ? 1 : 3)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 2) {
                Text(entry.date.clock).font(.system(size: 11)).foregroundStyle(.tertiary)
                if !compact { Text(entry.client).font(.system(size: 11)).foregroundStyle(.tertiary) }
            }
        }
        .padding(.horizontal, compact ? 0 : 14).padding(.vertical, compact ? 4 : 10)
    }

    var autoSent: Bool { entry.tool == "request_send" && entry.summary.hasPrefix("Auto-sent") }

    static func verb(_ tool: String) -> String {
        switch tool {
        case "list_chats": return "Looked at chat list"
        case "read_chat": return "Read"
        case "search_messages": return "Searched"
        case "waiting_on_reply": return "Checked who's waiting"
        case "list_attachments": return "Listed photos in"
        case "get_attachment": return "Opened a photo or file"
        case "draft_reply": return "Drafted a reply to"
        case "request_send": return "Asked to send to"
        case "check_send_status": return "Checked a send"
        case "approve_send": return "You sent"
        case "decline_send": return "You declined"
        case "get_settings": return "Looked at settings"
        case "get_chat_settings": return "Looked at settings for"
        case "change_chat_settings": return "Settings for"
        case "change_app_settings": return "App settings"
        case "check_settings_request": return "Checked a settings request"
        case "approve_settings": return "You approved settings"
        case "decline_settings": return "You declined settings"
        case "expire_settings": return "Settings request expired"
        default: return tool
        }
    }

    static func icon(_ tool: String) -> String {
        switch tool {
        case "list_chats": return "list.bullet"
        case "read_chat": return "text.bubble"
        case "search_messages": return "magnifyingglass"
        case "waiting_on_reply": return "hourglass"
        case "list_attachments", "get_attachment": return "photo"
        case "draft_reply": return "square.and.pencil"
        case "request_send", "check_send_status", "approve_send", "decline_send": return "paperplane"
        case "get_settings", "get_chat_settings", "change_chat_settings", "change_app_settings", "check_settings_request",
             "approve_settings", "decline_settings", "expire_settings": return "slider.horizontal.3"
        default: return "questionmark"
        }
    }
}
