import SwiftUI
import VeilCore

/// Claude Desktop, Cursor and Claude Code, each with its status and Add / Fix / Remove.
struct ConnectClientsCard: View {
    @EnvironmentObject var model: AppModel
    @State private var copied = false

    var body: some View {
        Card {
            ForEach(Array(ConnectClientID.allCases.enumerated()), id: \.element) { i, id in
                if i > 0 { Divider().padding(.leading, 46) }
                row(id)
            }
        }
    }

    func row(_ id: ConnectClientID) -> some View {
        let status = model.status(id)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Image(systemName: icon(status)).font(.system(size: 16)).foregroundStyle(color(status)).frame(width: 20)
                VStack(alignment: .leading, spacing: 2) {
                    Text(id.name).font(.system(size: 13, weight: .medium))
                    Text(text(status, id)).font(.system(size: 12)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true).lineLimit(3)
                }
                Spacer()
                buttons(id, status)
            }
            if id == .claudeCode, model.claudeCodeCLI == nil, status != .connected {
                let cmd = ClaudeCodeConnector.commandLine(ClaudeCodeConnector.addArguments(command: model.bridgePath))
                HStack(alignment: .top) {
                    Text(cmd).font(.system(size: 11, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    Button(copied ? "Copied" : "Copy") { model.copy(cmd); copied = true }.buttonStyle(QuietButtonStyle()).controlSize(.small)
                }
                .padding(10).background(Theme.subtle, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .padding(.leading, 32)
            }
            if let m = model.connectMessage[id] {
                Text(m).font(.system(size: 12)).foregroundStyle(Theme.calm).padding(.leading, 32).fixedSize(horizontal: false, vertical: true)
            }
            if let e = model.connectError[id] {
                Text(e).font(.system(size: 12)).foregroundStyle(Theme.caution).padding(.leading, 32).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
    }

    @ViewBuilder func buttons(_ id: ConnectClientID, _ status: ConnectStatus) -> some View {
        let cliMissing = id == .claudeCode && model.claudeCodeCLI == nil
        HStack(spacing: 6) {
            switch status {
            case .notConnected where !cliMissing:
                Button("Add") { model.propose(.add, for: id) }.buttonStyle(PrimaryButtonStyle())
            case .connected where !cliMissing:
                Button("Remove") { model.propose(.remove, for: id) }.buttonStyle(QuietButtonStyle())
            case .otherPath where !cliMissing:
                Button("Remove") { model.propose(.remove, for: id) }.buttonStyle(QuietButtonStyle())
                Button("Fix") { model.propose(.fix, for: id) }.buttonStyle(PrimaryButtonStyle())
            default:
                EmptyView()
            }
        }
        .controlSize(.small)
    }

    func text(_ s: ConnectStatus, _ id: ConnectClientID) -> String {
        switch s {
        case .notInstalled:
            return id == .claudeCode ? "The claude command wasn't found. Run this in a terminal:" : "Not installed."
        case .notConnected:
            return id == .claudeCode && model.claudeCodeCLI == nil ? "The claude command wasn't found. Run this in a terminal:" : "Installed, not connected to Veil."
        case .connected: return "Connected to this copy of Veil."
        case .otherPath(let p, let exists):
            return exists ? "Connected to a different copy of Veil: \(p)" : "Points at a copy of Veil that's no longer there: \(p)"
        case .unreadable(let why): return why
        }
    }

    func icon(_ s: ConnectStatus) -> String {
        switch s {
        case .connected: return "checkmark.circle.fill"
        case .otherPath, .unreadable: return "exclamationmark.circle"
        case .notConnected: return "circle.dashed"
        case .notInstalled: return "minus.circle"
        }
    }

    func color(_ s: ConnectStatus) -> Color {
        switch s {
        case .connected: return Theme.calm
        case .otherPath, .unreadable: return Theme.caution
        default: return .secondary
        }
    }
}

/// Exactly what a one-click change will do, and the OK to do it.
struct ConnectConfirmView: View {
    @EnvironmentObject var model: AppModel
    let change: PendingConnectChange
    @State var showWholeFile = false

    var verb: String {
        switch change.action { case .add: return "Add"; case .fix: return "Fix"; case .remove: return "Remove" }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title).font(.system(size: 15, weight: .semibold))
            if let plan = change.plan { fileDetails(plan) } else { commandDetails }
            HStack {
                Spacer()
                Button("Cancel") { model.pendingChange = nil }.buttonStyle(QuietButtonStyle()).keyboardShortcut(.cancelAction)
                Button(verb) { model.confirm(change) }.buttonStyle(PrimaryButtonStyle())
            }
        }
        .padding(22)
        .frame(width: 560)
        .background(Theme.window)
    }

    var title: String {
        switch change.action {
        case .add: return "Add Veil to \(change.client.name)?"
        case .fix: return "Point \(change.client.name) at this copy of Veil?"
        case .remove: return "Remove Veil from \(change.client.name)?"
        }
    }

    @ViewBuilder func fileDetails(_ plan: ConfigPlan) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            label("File", plan.file.path(percentEncoded: false))
            HStack(alignment: .top, spacing: 10) {
                block("Before", plan.entryBefore ?? "(no veil entry)")
                block("After", plan.entryAfter ?? "(no veil entry)")
            }
            VStack(alignment: .leading, spacing: 4) {
                if plan.createsFile {
                    note("The file doesn't exist yet, so Veil creates it.")
                } else {
                    note("A backup of the current file is saved next to it first (\(plan.file.lastPathComponent).veil-backup-…).")
                }
                note(plan.otherServers.isEmpty ? "There are no other servers in this file." : "Kept exactly as they are: \(plan.otherServers.joined(separator: ", ")), and every other setting.")
                if !plan.createsFile { note("The file is saved with standard JSON formatting, so spacing and key order may change.") }
            }
            DisclosureGroup("Show the whole new file", isExpanded: $showWholeFile) {
                ScrollView {
                    Text(plan.newText).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 180)
                .padding(8).background(Theme.card, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            .font(.system(size: 12))
        }
    }

    var commandDetails: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Veil runs:").font(.system(size: 12)).foregroundStyle(.secondary)
            ForEach(change.commands, id: \.self) { c in
                Text(c).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8).background(Theme.card, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            note("Claude Code saves this in its own user settings. Nothing else is changed.")
        }
    }

    func label(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
            Text(value).font(.system(size: 11, design: .monospaced)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        }
    }

    func block(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
            Text(text).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .padding(8).background(Theme.card, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 0.5))
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    func note(_ t: String) -> some View {
        Text(t).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
}
