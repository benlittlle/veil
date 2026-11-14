import SwiftUI
import ServiceManagement
import VeilCore

struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    @State private var keyDraft = ""
    @State private var confirmDirect = false
    @State private var showWebhook = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                PaneHeader(title: "Settings", subtitle: "How Veil looks, when it runs, and who it pings.")

                VStack(alignment: .leading, spacing: 8) {
                    SectionLabel(text: "Appearance")
                    Card {
                        row("Mode", "Follow your Mac, or pick one.") {
                            Picker("", selection: $model.appearance) {
                                ForEach(AppearanceChoice.allCases) { Text($0.rawValue).tag($0) }
                            }.pickerStyle(.segmented).labelsHidden().frame(width: 210)
                        }
                        Divider().padding(.leading, 16)
                        row("Accent color", "Used for switches, buttons and highlights.") {
                            HStack(spacing: 10) {
                                ForEach(AccentChoice.allCases) { choice in swatch(choice) }
                            }
                        }
                        Divider().padding(.leading, 16)
                        row("Background", "Warm paper tones, or plain neutral grey.") {
                            Picker("", selection: $model.surface) {
                                ForEach(SurfaceChoice.allCases) { Text($0.rawValue).tag($0) }
                            }.pickerStyle(.segmented).labelsHidden().frame(width: 150)
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 8) {
                    SectionLabel(text: "General")
                    Card {
                        row("Open at login", loginDetail) {
                            Toggle("", isOn: Binding(get: { model.loginItemStatus == .enabled || model.loginItemStatus == .requiresApproval },
                                                     set: { model.setOpenAtLogin($0) }))
                                .toggleStyle(.switch).labelsHidden().tint(Theme.accent).controlSize(.small)
                                .disabled(model.mode == .demo)
                        }
                        Divider().padding(.leading, 16)
                        row("Assistant name", "Used in labels and the send prompt.") {
                            TextField("", text: $model.assistantName).textFieldStyle(.roundedBorder).frame(width: 160)
                        }
                        if Updates.shared.isAvailable {
                            Divider().padding(.leading, 16)
                            row("Updates", "Version \(Updates.shared.version). Updates are signed and checked before they install.") {
                                Button("Check Now") { Updates.shared.checkNow() }.controlSize(.small)
                            }
                        }
                    }
                    if let e = model.loginItemError {
                        Text(e).font(.system(size: 11)).foregroundStyle(Theme.caution).padding(.leading, 4)
                    }
                }

                agentSection

                filterSection

                autoSendSection

                pingsSection
            }
            .padding(28).frame(maxWidth: 640, alignment: .leading).frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear { model.loginItemStatus = SMAppService.mainApp.status }
    }

    // MARK: Assistant can change settings

    var agentSection: some View {
        let mode = model.state.agentSettings
        let name = model.assistantName
        return VStack(alignment: .leading, spacing: 8) {
            SectionLabel(text: "\(name)'s access to settings")
            Card {
                VStack(alignment: .leading, spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(name) can change settings").font(.system(size: 13, weight: .medium))
                        Text(agentDetail(mode)).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    Picker("", selection: Binding(get: { mode }, set: { m in
                        if m == .direct { confirmDirect = true } else { model.setAgentSettings(m) }
                    })) {
                        ForEach(AgentSettingsMode.allCases, id: \.self) { Text($0.title).tag($0) }
                    }.pickerStyle(.segmented).labelsHidden().fixedSize()
                    .accessibilityLabel("Assistant can change settings")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16).padding(.vertical, 12)
            }
            if mode == .direct {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.caution)
                    Text("\(name) changes settings without asking. A message it reads could trick it into opening up chats or turning on auto-send. Choose Ask me to approve each change.")
                        .font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.caution.opacity(0.10), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
        }
        .alert("Let \(name) change settings without asking?", isPresented: $confirmDirect) {
            Button("Apply directly", role: .destructive) { model.setAgentSettings(.direct) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("\(name) will be able to turn on Read, Send, auto-send and the other switches for any chat it can see, change the content filter and pause Veil, and the change happens right away. A message it reads could trick it into opening up chats or turning on auto-send. You'll get a notification for each change, and allowing PINs and codes still asks you. Hidden chats, the webhook and this setting stay out of reach.")
        }
    }

    func agentDetail(_ mode: AgentSettingsMode) -> String {
        switch mode {
        case .off: return "Only you can change what \(model.assistantName) sees and does. It can still ask you in conversation."
        case .ask: return "\(model.assistantName) can ask to change switches, the content filter, auto-send and pings. You allow or decline each change."
        case .direct: return "\(model.assistantName) changes switches, the content filter, auto-send and pings right away. You're notified of each change."
        }
    }

    // MARK: Content filter

    var filterSection: some View {
        let profile = model.state.effectiveFilterProfile
        let filtered = model.conversations.filter { model.access($0.id).filtered && !model.access($0.id).hidden }
        return VStack(alignment: .leading, spacing: 8) {
            SectionLabel(text: "Content filter")
            Card {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Default settings for filtered chats").font(.system(size: 13, weight: .medium))
                    Text("Turn the filter on per chat under Chats. Everything is checked on this Mac first. It lowers the risk but can't catch everything; only Read off keeps a chat fully private.")
                        .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    FilterModelStatus(policy: profile).padding(.top, 2)
                    Text(filtered.isEmpty ? "No chats are filtered yet." : "Filtered: " + filtered.map(\.displayName).joined(separator: ", "))
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16).padding(.vertical, 12)
            }
            FilterPolicyEditor(policy: profile, onChange: { model.setFilterProfile($0) }, collapsible: true)
            if profile != .standard {
                Button("Back to the standard settings") { model.setFilterProfile(.standard) }
                    .buttonStyle(.plain).font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.accent).padding(.leading, 4)
            }
        }
    }

    // MARK: Auto-send

    var autoSendSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(text: "Auto-send")
            Card {
                row("Allow auto-send", model.state.autoSendStopped
                    ? "Stopped. Every message needs your OK, even in chats set to auto-send."
                    : "Chats set to auto-send skip the prompt for text. Turn off to stop them all.") {
                    Toggle("", isOn: Binding(get: { !model.state.autoSendStopped }, set: { model.setAutoSendStopped(!$0) }))
                        .toggleStyle(.switch).labelsHidden().tint(Theme.accent).controlSize(.small)
                        .accessibilityLabel("Allow auto-send")
                }
                Divider().padding(.leading, 16)
                row("Limit per chat", "Past this, \(model.assistantName)'s messages wait for your OK again.") {
                    let l = model.state.effectiveAutoSendLimit
                    HStack(spacing: 6) {
                        Stepper("\(l.count)", value: Binding(get: { l.count }, set: { model.setAutoSendLimit(AutoSendLimit(count: $0, minutes: l.minutes)) }), in: 1...50)
                            .font(.system(size: 12)).fixedSize()
                        Text("every").font(.system(size: 12)).foregroundStyle(.secondary)
                        Picker("", selection: Binding(get: { l.minutes }, set: { model.setAutoSendLimit(AutoSendLimit(count: l.count, minutes: $0)) })) {
                            ForEach(Array(Set([5, 10, 15, 30, 60, l.minutes])).sorted(), id: \.self) { Text("\($0) min").tag($0) }
                        }.labelsHidden().fixedSize()
                    }
                }
                Divider().padding(.leading, 16)
                row("Notify me", "A notification after each auto-sent message, and each settings change made without asking.") {
                    Toggle("", isOn: $model.autoSendNotify)
                        .toggleStyle(.switch).labelsHidden().tint(Theme.accent).controlSize(.small)
                        .accessibilityLabel("Notify after each auto-send")
                }
                Divider().padding(.leading, 16)
                row("Chats", model.autoSendChats.isEmpty ? "None. Turn it on per chat under Chats, after Send with your OK."
                    : model.autoSendChats.map(\.displayName).joined(separator: ", ")) { EmptyView() }
            }
        }
    }

    // MARK: New-message pings

    /// The webhook rows stay folded away until pings are on or something is filled in.
    var webhookConfigured: Bool { model.webhookEnabled || !model.webhookURL.isEmpty || model.webhookKeySaved }

    var pingsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(text: "New-message pings")
            Card {
                row("Ping on new messages", "Tell \(model.assistantName) when a chat with Read or Activity on gets a message. Pings name the chat, never what was said.") {
                    Toggle("", isOn: $model.webhookEnabled)
                        .toggleStyle(.switch).labelsHidden().tint(Theme.accent).controlSize(.small)
                        .accessibilityLabel("Ping on new messages")
                }
                Divider().padding(.leading, 16)
                row("Ping when I reply", "Your own messages ping too, so \(model.assistantName) knows you've answered.") {
                    Toggle("", isOn: $model.webhookPingReplies)
                        .toggleStyle(.switch).labelsHidden().tint(Theme.accent).controlSize(.small)
                        .accessibilityLabel("Ping when I reply")
                }
                if webhookConfigured || showWebhook {
                    webhookRows
                } else {
                    Divider().padding(.leading, 16)
                    row("Webhook", "Where pings go. Set this up to use pings.") {
                        Button("Set Up…") { showWebhook = true }.buttonStyle(QuietButtonStyle())
                    }
                }
            }
            if let p = model.webhookProblem {
                Text(p).font(.system(size: 11)).foregroundStyle(Theme.caution).padding(.leading, 4)
            }

            if webhookConfigured || !model.webhookLog.isEmpty {
                recentPings
            }
        }
    }

    @ViewBuilder var webhookRows: some View {
                Divider().padding(.leading, 16)
                row("Webhook address", "Where pings are sent. Must be https.") {
                    TextField("https://", text: $model.webhookURL).textFieldStyle(.roundedBorder).frame(width: 260)
                }
                Divider().padding(.leading, 16)
                row("Header", "Carries the key. Authorization sends “Bearer <key>”; any other header sends the key on its own.") {
                    TextField("Authorization", text: $model.webhookHeader).textFieldStyle(.roundedBorder).frame(width: 160)
                }
                Divider().padding(.leading, 16)
                row("Key", model.webhookKeySaved ? "Saved in your Keychain. Never shown to the assistant or written to any log." : "Paste the secret your webhook expects.") {
                    HStack(spacing: 8) {
                        SecureField(model.webhookKeySaved ? "Replace key" : "Paste key", text: $keyDraft)
                            .textFieldStyle(.roundedBorder).frame(width: 140)
                            .onSubmit(saveKey)
                        Button("Save", action: saveKey).buttonStyle(QuietButtonStyle()).disabled(keyDraft.isEmpty)
                        if model.webhookKeySaved {
                            Button("Remove") { model.removeWebhookKey() }.buttonStyle(QuietButtonStyle())
                        }
                    }
                    .lineLimit(1)
                    .fixedSize()   // keep the buttons on one line; the description wraps instead
                }
                Divider().padding(.leading, 16)
                HStack(spacing: 12) {
                    Button(model.webhookTesting ? "Sending…" : "Send test ping") { model.sendTestPing() }
                        .buttonStyle(PrimaryButtonStyle())
                        .opacity(canTest ? 1 : 0.45)
                        .disabled(model.webhookTesting || WebhookConfig.problem(url: model.webhookURL, headerName: model.webhookHeader) != nil || !model.webhookKeySaved)
                    Text("Sends {\"event\":\"test\"} once, even with pings off.").font(.system(size: 12)).foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 16).padding(.vertical, 12)
    }

    @ViewBuilder var recentPings: some View {
            HStack {
                SectionLabel(text: "Recent pings")
                Spacer()
                Button("Clear") { model.clearWebhookLog() }.buttonStyle(.plain).font(.system(size: 12))
                    .foregroundStyle(.secondary).disabled(model.webhookLog.isEmpty)
            }.padding(.top, 10)
            Card {
                let recent = Array(model.webhookLog.suffix(25).reversed())
                if recent.isEmpty {
                    Text("No pings yet.").font(.system(size: 12)).foregroundStyle(.secondary)
                        .padding(.horizontal, 16).padding(.vertical, 12).frame(maxWidth: .infinity, alignment: .leading)
                }
                ForEach(Array(recent.enumerated()), id: \.element.id) { i, e in
                    if i > 0 { Divider().padding(.leading, 56) }
                    pingRow(e)
                }
            }
    }

    var canTest: Bool {
        !model.webhookTesting && model.webhookKeySaved && WebhookConfig.problem(url: model.webhookURL, headerName: model.webhookHeader) == nil
    }

    func saveKey() {
        guard !keyDraft.isEmpty else { return }
        model.saveWebhookKey(keyDraft)
        keyDraft = ""
    }

    func pingRow(_ e: WebhookLogEntry) -> some View {
        let ok = e.outcome == .sent
        let title = e.event == "test" ? "Test ping" : "Ping about \(model.chatName(e.chatID ?? ""))"
        let parts = [e.messageID.map { "Message \($0)" }, e.attempt > 1 ? "try \(e.attempt)" : nil, e.detail].compactMap { $0 }
        return HStack(alignment: .top, spacing: 12) {
            Image(systemName: ok ? "dot.radiowaves.up.forward" : "exclamationmark.triangle")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(ok ? Color.secondary : Theme.caution)
                .frame(width: 28, height: 28)
                .background(ok ? Theme.subtle : Theme.caution.opacity(0.12), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(title).font(.system(size: 13, weight: .medium)).lineLimit(1)
                    switch e.outcome {
                    case .sent: EmptyView()
                    case .retrying: Pill(text: "Retrying", color: .secondary)
                    case .failed: Pill(text: "Failed", color: Theme.caution)
                    case .dropped: Pill(text: "Dropped", color: Theme.caution)
                    }
                }
                Text(parts.joined(separator: " · ")).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer(minLength: 8)
            Text(e.date.clock).font(.system(size: 11)).foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
    }

    var loginDetail: String {
        switch model.loginItemStatus {
        case .requiresApproval: return "Almost there: allow Veil in System Settings → General → Login Items."
        case .enabled: return "Starts quietly in the menu bar when you log in."
        default: return "Recommended, so send prompts work right after a restart."
        }
    }

    func swatch(_ c: AccentChoice) -> some View {
        let selected = model.accent == c
        return Button { model.accent = c } label: {
            Circle()
                .fill(Color(nsColor: Theme.dynamic(light: c.colors.light, dark: c.colors.dark)))
                .frame(width: 20, height: 20)
                .overlay(Circle().strokeBorder(Color.primary.opacity(selected ? 0.55 : 0), lineWidth: 2).padding(-4))
                .padding(4)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(c.rawValue)
        .accessibilityLabel("\(c.rawValue) accent\(selected ? ", selected" : "")")
    }

    func row<Control: View>(_ title: String, _ detail: String, @ViewBuilder control: () -> Control) -> some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .medium))
                Text(detail).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            control()
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
    }
}
