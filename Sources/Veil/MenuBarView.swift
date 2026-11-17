import SwiftUI
import VeilCore

struct MenuBarView: View {
    @EnvironmentObject var model: AppModel
    var openMain: (Pane) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header

            if let r = model.waitingSettings.last {
                SettingsApprovalCard(request: r, compact: true)
            }
            BypassMenuRow { openMain(.setup) }
            if model.state.agentSettings == .direct {
                // Same quiet shape as the Full Disk Access line: a standing risk, not an event.
                Button { openMain(.settings) } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle").font(.system(size: 11)).foregroundStyle(Theme.caution)
                        Text("\(model.assistantName) changes settings without asking").font(.system(size: 11)).lineLimit(1)
                        Spacer(minLength: 4)
                        Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(.tertiary)
                    }
                    .foregroundStyle(.secondary)
                    .contentShape(Rectangle())
                }.buttonStyle(.plain)
            }

            if let r = model.waitingSends.first {
                ApprovalCard(request: r, compact: true)
            }
            if let r = model.failedSends.first {
                FailedSendCard(request: r, compact: true)
            }

            if !model.drafts.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    SectionLabel(text: "Drafts")
                    ForEach(model.drafts.prefix(3)) { d in DraftRow(draft: d) }
                }
            }

            if !model.newChats.isEmpty {
                Button { openMain(.chats) } label: {
                    HStack(spacing: 8) {
                        Circle().fill(Theme.accent).frame(width: 7, height: 7)
                        Text("\(model.newChats.count) new \(model.newChats.count == 1 ? "chat" : "chats") to review").font(.system(size: 12, weight: .medium))
                        Spacer()
                        Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(.tertiary)
                    }
                    .padding(10).background(Theme.accent.opacity(0.07), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                    .contentShape(Rectangle())
                }.buttonStyle(.plain)
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    SectionLabel(text: "Recent activity")
                    Spacer()
                    Button("See all") { openMain(.activity) }.buttonStyle(.plain).font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.accent)
                }
                if model.log.isEmpty {
                    Text("Quiet so far.").font(.system(size: 12)).foregroundStyle(.secondary).padding(.vertical, 6)
                } else {
                    ForEach(model.log.suffix(3).reversed()) { ActivityRow(entry: $0, compact: true) }
                }
            }

            if !model.autoSendChats.isEmpty || model.state.autoSendStopped {
                AutoSendSwitch()
            }

            Divider()

            HStack {
                Toggle(isOn: Binding(get: { model.state.paused }, set: { model.setPaused($0) })) {
                    Text("Pause everything").font(.system(size: 12))
                }.toggleStyle(.switch).controlSize(.mini).tint(Theme.accent)
                Spacer()
                Button("Open Veil") { openMain(.chats) }.buttonStyle(QuietButtonStyle()).controlSize(.small)
                Menu {
                    if Updates.shared.isAvailable {
                        Button("Check for Updates…") { Updates.shared.checkNow() }
                    }
                    Button("Quit Veil") { NSApp.terminate(nil) }
                } label: { Image(systemName: "ellipsis") }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            }
        }
        .padding(16)
        .frame(width: 360)
        .background(Theme.window)
        .id(model.themeID)
    }

    var header: some View {
        HStack(spacing: 10) {
            AppIconTile(size: 32, dimmed: model.state.paused)
            VStack(alignment: .leading, spacing: 1) {
                Text("Veil").font(.system(size: 13, weight: .semibold))
                Text(status).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
        }
    }

    var status: String {
        if case .tampered = model.integrity { return "Locked. Open Setup & safety to review." }
        if model.state.paused { return "Paused. \(model.assistantName) sees nothing." }
        if model.diskAccessProblem != nil { return "Needs Full Disk Access" }
        let who = model.clients.isEmpty ? "Not connected" : "\(Set(model.clients).sorted().joined(separator: ", ")) connected"
        return "\(who) · \(model.sharedCount) chats shared"
    }
}

struct DraftRow: View {
    @EnvironmentObject var model: AppModel
    let draft: Draft
    @State private var copied = false
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("To \(draft.chatName)").font(.system(size: 12, weight: .medium))
                Spacer()
                Text(draft.created.relative).font(.system(size: 11)).foregroundStyle(.tertiary)
            }
            Text(draft.text).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(3).textSelection(.enabled)
            HStack(spacing: 12) {
                Spacer()
                Button("Discard") { model.discardDraft(draft.id) }
                Button(copied ? "Copied" : "Copy") { model.copy(draft.text); copied = true }
            }.buttonStyle(.plain).font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.accent)
        }
        .padding(10)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 0.5))
    }
}

/// The approve / don't send prompt. Shown in a floating panel and in the menu.
struct ApprovalCard: View {
    @EnvironmentObject var model: AppModel
    let request: SendRequest
    var compact = false
    /// Send stays disabled briefly so a keystroke meant for another app can't approve it.
    @State private var armed = false

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 10 : 14) {
            HStack(spacing: 10) {
                Avatar(name: request.chatName, size: compact ? 28 : 36)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Send this to \(request.chatName)?").font(.system(size: compact ? 13 : 15, weight: .semibold))
                    // Any member can rename a group, so the prompt also says who it really reaches.
                    if !request.recipients.isEmpty {
                        Text(request.recipients).font(.system(size: 11, weight: .medium)).lineLimit(2)
                    }
                    Text("\(model.assistantName) wrote it. Nothing goes out unless you say so.")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            HStack {
                Spacer(minLength: 40)
                Text(request.text)
                    .font(.system(size: 13)).foregroundStyle(.white)
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(Theme.bubble, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                if model.waitingSends.count > 1 {
                    Text("\(model.waitingSends.count - 1) more waiting").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Don't send") { model.decline(request.id) }
                    .buttonStyle(QuietButtonStyle()).keyboardShortcut(.cancelAction)
                Button("Send") { model.approve(request.id) }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(!armed).opacity(armed ? 1 : 0.5)
            }
        }
        .padding(compact ? 12 : 20)
        .task(id: request.id) {
            armed = false
            try? await Task.sleep(for: .seconds(1.2))
            armed = true
        }
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(compact ? Theme.accent.opacity(0.35) : .clear, lineWidth: 1))
    }
}

/// Floating panel content: shows the oldest waiting request, if any (settings changes first).
struct ApprovalPanelView: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        if let r = model.waitingSettings.last {
            SettingsApprovalCard(request: r).frame(width: 400)
        } else if let r = model.waitingSends.last {
            ApprovalCard(request: r).frame(width: 400)
        } else if let r = model.failedSends.first {
            FailedSendCard(request: r).frame(width: 400)
        } else {
            Color.clear.frame(width: 400, height: 1)
        }
    }
}

/// A message Messages didn't take. Says why, and keeps the text so it can be sent by hand.
struct FailedSendCard: View {
    @EnvironmentObject var model: AppModel
    let request: SendRequest
    var compact = false
    @State private var copied = false

    private var reason: String {
        if case .failed(let why) = request.status { return why }
        return ""
    }

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 8 : 12) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.caution)
                    .font(.system(size: compact ? 13 : 15))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Couldn't send to \(request.chatName)").font(.system(size: compact ? 13 : 15, weight: .semibold))
                    Text(reason).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            Text(request.text).font(.system(size: 12)).foregroundStyle(.secondary)
                .lineLimit(compact ? 2 : 4).textSelection(.enabled)
            HStack(spacing: 8) {
                Spacer()
                if reason == AppleScriptSender.notAllowed {
                    Button("Open Settings") { AppModel.openPrivacy("Privacy_Automation") }.buttonStyle(QuietButtonStyle())
                }
                Button("Dismiss") { model.dismissFailure(request.id) }.buttonStyle(QuietButtonStyle())
                Button(copied ? "Copied" : "Copy text") { model.copy(request.text); copied = true }.buttonStyle(PrimaryButtonStyle())
            }
        }
        .padding(compact ? 12 : 20)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(compact ? Theme.caution.opacity(0.35) : .clear, lineWidth: 1))
    }
}

/// Allow / Don't allow for a settings change the assistant asked for. Same protections as the send
/// prompt: the panel never takes keyboard focus, Allow arms after a moment, and a request is applied once.
struct SettingsApprovalCard: View {
    @EnvironmentObject var model: AppModel
    let request: SettingsRequest
    var compact = false
    @State private var armed = false

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 10 : 14) {
            HStack(spacing: 10) {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: compact ? 12 : 14, weight: .medium)).foregroundStyle(Theme.accent)
                    .frame(width: compact ? 28 : 36, height: compact ? 28 : 36)
                    .background(Theme.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                VStack(alignment: .leading, spacing: 1) {
                    Text("\(model.assistantName) wants to change settings").font(.system(size: compact ? 13 : 15, weight: .semibold))
                    Text("Nothing changes unless you allow it. Only allow changes you asked for.")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            VStack(alignment: .leading, spacing: 5) {
                ForEach(Array(request.phrases.prefix(compact ? 4 : 12).enumerated()), id: \.offset) { _, line in
                    HStack(alignment: .firstTextBaseline, spacing: 7) {
                        Circle().fill(Theme.accent).frame(width: 5, height: 5).alignmentGuide(.firstTextBaseline) { $0[.bottom] + 1 }
                        Text(line.prefix(1).uppercased() + line.dropFirst())
                            .font(.system(size: 13)).fixedSize(horizontal: false, vertical: true)
                    }
                }
                if compact && request.phrases.count > 4 {
                    Text("and \(request.phrases.count - 4) more").font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.subtle, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            if let c = request.caution {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.caution)
                    Text(c).font(.system(size: 11)).fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack(spacing: 8) {
                // The client picks its own name, so it's shown as a cleaned-up label only.
                Text("Asked by \(request.client)").font(.system(size: 11)).foregroundStyle(.tertiary).lineLimit(1)
                if model.waitingSettings.count > 1 {
                    Text("· \(model.waitingSettings.count - 1) more waiting").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Don't allow") { model.declineSettings(request.id) }
                    .buttonStyle(QuietButtonStyle()).keyboardShortcut(.cancelAction)
                Button("Allow") { model.approveSettings(request.id) }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(!armed).opacity(armed ? 1 : 0.5)
            }
        }
        .padding(compact ? 12 : 20)
        .task(id: request.id) {
            armed = false
            try? await Task.sleep(for: .seconds(1.2))
            armed = true
        }
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(compact ? Theme.accent.opacity(0.35) : .clear, lineWidth: 1))
    }
}

/// Kill switch for every chat's auto-send. Per-chat choices are kept.
struct AutoSendSwitch: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        let stopped = model.state.autoSendStopped
        let n = model.autoSendChats.count
        HStack(spacing: 10) {
            Image(systemName: stopped ? "bolt.slash" : "bolt.fill")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(stopped ? Color.secondary : Theme.accent)
                .frame(width: 28, height: 28)
                .background(stopped ? Theme.subtle : Theme.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            VStack(alignment: .leading, spacing: 1) {
                Text("Auto-send").font(.system(size: 12, weight: .medium))
                Text(stopped ? "Stopped. Every send needs your OK." : "On for \(n) \(n == 1 ? "chat" : "chats") · \(model.state.effectiveAutoSendLimit.count) per \(model.state.effectiveAutoSendLimit.minutes) min")
                    .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Toggle("", isOn: Binding(get: { !stopped }, set: { model.setAutoSendStopped(!$0) }))
                .toggleStyle(.switch).labelsHidden().controlSize(.mini).tint(Theme.accent)
                .accessibilityLabel("Auto-send for all chats")
        }
        .padding(10)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 0.5))
    }
}
