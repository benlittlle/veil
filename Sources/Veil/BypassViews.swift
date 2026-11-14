import SwiftUI
import VeilCore

/// A calm notice when an assistant's app has Full Disk Access (see `ClientCheck`). Plenty of agent
/// setups run that way on purpose, so it states the fact, explains the options and can be
/// acknowledged per assistant. Shown at the top of Setup & safety and Connect; renders nothing
/// when there's nothing to say.
struct BypassNotice: View {
    @EnvironmentObject var model: AppModel
    @State var expanded = false

    var body: some View {
        let notices = model.bypassWarnings
        if !notices.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(notices) { c in
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: "info.circle").font(.system(size: 16)).foregroundStyle(Theme.accent).frame(width: 20)
                        VStack(alignment: .leading, spacing: 6) {
                            Text("\(c.headline), so it could read Messages directly.").font(.system(size: 13, weight: .semibold))
                                .fixedSize(horizontal: false, vertical: true)
                            Text("Veil's limits only apply to what it asks Veil for.")
                                .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            Button("I understand, don't warn me again") { model.acknowledge(c) }
                                .buttonStyle(QuietButtonStyle()).controlSize(.small)
                        }
                    }
                }
                DisclosureGroup(isExpanded: $expanded) {
                    VStack(alignment: .leading, spacing: 8) {
                        point("Veil's switches decide what an assistant gets *through Veil*. With Full Disk Access it can also open the Messages database itself, and Veil can't see or limit that.")
                        point("Many agents only need a few folders. macOS can grant those on their own under Privacy & Security → Files and Folders, so Full Disk Access is often more than an agent needs.")
                        point("If the agent has its own Messages integration, turn that off so it uses Veil.")
                        point("Running the agent under a separate, non-admin macOS user keeps your Messages folder out of its reach.")
                        point("Or keep things as they are. If you trust this setup, say so above; Veil checks again whenever it connects.")
                        HStack(spacing: 8) {
                            Button("Open Full Disk Access") { AppModel.openFullDiskAccessSettings() }.buttonStyle(QuietButtonStyle()).controlSize(.small)
                            Button("Open Files and Folders") { AppModel.openFilesAndFoldersSettings() }.buttonStyle(QuietButtonStyle()).controlSize(.small)
                        }
                        .padding(.top, 2)
                    }
                    .padding(.top, 8)
                } label: {
                    Text("Why this matters and what you can do").font(.system(size: 12, weight: .medium))
                }
                .padding(.leading, 32)
            }
            .padding(16)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.accent.opacity(0.3), lineWidth: 1))
        }
    }

    func point(_ text: LocalizedStringKey) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text("•").foregroundStyle(.secondary)
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
        .font(.system(size: 12)).foregroundStyle(.secondary)
    }
}

/// Every assistant Veil has seen, with whether it could skip the gate.
struct ClientChecksList: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        if !model.clientChecks.isEmpty {
            Card {
                ForEach(Array(model.clientChecks.enumerated()), id: \.element.id) { i, c in
                    if i > 0 { Divider().padding(.leading, 46) }
                    row(c)
                }
            }
        }
    }

    func row(_ c: ClientCheck) -> some View {
        let acknowledged = c.canBypass && model.isAcknowledged(c)
        return HStack(spacing: 12) {
            Image(systemName: icon(c.reach)).font(.system(size: 17)).foregroundStyle(color(c.reach)).frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(c.name).font(.system(size: 13, weight: .medium))
                    Text(model.isConnected(c) ? "Connected" : "Seen \(c.lastSeen.relative)").font(.system(size: 11)).foregroundStyle(.tertiary)
                }
                Text(status(c, acknowledged: acknowledged)).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if acknowledged {
                Button("Remind me") { model.unacknowledge(c) }.buttonStyle(QuietButtonStyle()).controlSize(.small)
            }
            if !model.isConnected(c) {
                Button("Forget") { model.forgetClientCheck(c.name) }.buttonStyle(QuietButtonStyle()).controlSize(.small)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
    }

    func status(_ c: ClientCheck, acknowledged: Bool) -> String {
        if acknowledged { return ClientCheck.acknowledgedLine + ". It could read Messages directly." }
        if c.canBypass { return "Runs with Full Disk Access, so it could read Messages directly. Veil's limits only apply to what it asks Veil for." }
        return c.detail
    }

    func icon(_ r: ChatDBReach) -> String {
        switch r {
        case .readable: return "info.circle"
        case .blocked: return "checkmark.circle"
        case .cantCheckHTTP, .cantCheckOldRelay: return "questionmark.circle"
        }
    }

    func color(_ r: ChatDBReach) -> Color {
        switch r {
        case .readable: return Theme.accent
        case .blocked: return Theme.calm
        case .cantCheckHTTP, .cantCheckOldRelay: return .secondary
        }
    }
}

/// "Other apps that can read Messages directly": the Full Disk Access list from TCC.db.
/// Hidden entirely when that list couldn't be read.
struct FullDiskAccessSection: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        if let list = model.fullDiskAccess {
            VStack(alignment: .leading, spacing: 10) {
                SectionLabel(text: "Other apps that can read Messages directly")
                Card {
                    if list.isEmpty {
                        Text("Only Veil has Full Disk Access on this Mac.")
                            .font(.system(size: 12)).foregroundStyle(.secondary).padding(14)
                    } else {
                        Text("These apps have Full Disk Access, so they can read Messages directly. Anything started from them, such as an agent in a terminal, can too.")
                            .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            .padding(.horizontal, 14).padding(.top, 12).padding(.bottom, 6)
                        ForEach(list) { g in
                            let highlight = model.isHighlighted(g)
                            HStack(spacing: 10) {
                                Image(systemName: icon(g.kind)).font(.system(size: 13))
                                    .foregroundStyle(highlight ? Theme.accent : .secondary).frame(width: 20)
                                Text(g.name).font(.system(size: 13, weight: highlight ? .medium : .regular))
                                if g.isPath { Text(g.client).font(.system(size: 11, design: .monospaced)).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle) }
                                Spacer()
                                if let c = model.connectedHost(g) {
                                    Pill(text: "\(c.name) may run here", color: Theme.accent)
                                } else if g.kind != .other {
                                    Pill(text: g.kind.label, color: g.kind == .ai ? Theme.accent : .secondary)
                                }
                            }
                            .padding(.horizontal, 14).padding(.vertical, 6)
                        }
                        HStack {
                            Text("Change this in System Settings.").font(.system(size: 12)).foregroundStyle(.secondary)
                            Spacer()
                            Button("Open Full Disk Access") { AppModel.openFullDiskAccessSettings() }.buttonStyle(QuietButtonStyle())
                        }
                        .padding(.horizontal, 14).padding(.vertical, 12)
                    }
                }
            }
        }
    }

    func icon(_ k: FullDiskAccessGrant.Kind) -> String {
        switch k {
        case .ai: return "sparkles"
        case .terminal: return "terminal"
        case .editor: return "chevron.left.forwardslash.chevron.right"
        case .commandLine: return "apple.terminal"
        case .other: return "app"
        }
    }
}

/// A quiet line in the menu bar panel while a Full Disk Access notice is unacknowledged.
struct BypassMenuRow: View {
    @EnvironmentObject var model: AppModel
    var open: () -> Void

    var body: some View {
        let w = model.bypassWarnings
        if !w.isEmpty {
            Button(action: open) {
                HStack(spacing: 6) {
                    Image(systemName: "info.circle").font(.system(size: 11))
                    Text(w.count == 1 ? w[0].headline
                                      : "\(w.count) assistants run with Full Disk Access")
                        .font(.system(size: 11)).lineLimit(1).truncationMode(.tail)
                    Spacer(minLength: 4)
                    Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(.tertiary)
                }
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
            }.buttonStyle(.plain)
        }
    }
}
