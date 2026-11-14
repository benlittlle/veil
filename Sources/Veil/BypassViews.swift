import SwiftUI
import VeilCore

/// The prominent warning when an assistant's app can read chat.db itself (see `ClientCheck`).
/// Shown at the top of Setup & safety and Connect. Renders nothing when there's nothing to warn about.
struct BypassWarningCard: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        let warnings = model.bypassWarnings
        if !warnings.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 18)).foregroundStyle(Theme.caution)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(title(warnings)).font(.system(size: 14, weight: .semibold))
                        Text("The app \(warnings.count == 1 ? "it runs" : "they run") in has Full Disk Access, so \(warnings.count == 1 ? "it" : "they") can open your Messages database directly and skip every switch in Veil.")
                            .font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
                    }
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("To fix it").font(.system(size: 12, weight: .semibold))
                    Text("1. Open Privacy & Security → Full Disk Access.\n2. Turn off the app \(names(warnings)) \(warnings.count == 1 ? "runs" : "run") in: Claude, Cursor, a terminal, or whichever app launched it.\n3. Quit and reopen \(warnings.count == 1 ? "it" : "them"). Veil checks again each time \(warnings.count == 1 ? "it connects" : "they connect").")
                        .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    let hosts = model.likelyHostsWithDiskAccess
                    if !hosts.isEmpty {
                        Text("Has Full Disk Access and can run an assistant: \(hosts.map(\.name).joined(separator: ", ")).")
                            .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.leading, 30)
                HStack {
                    Spacer()
                    Button("Open Full Disk Access") { AppModel.openFullDiskAccessSettings() }.buttonStyle(PrimaryButtonStyle())
                }
            }
            .padding(16)
            .background(Theme.caution.opacity(0.09), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.caution.opacity(0.45), lineWidth: 1))
        }
    }

    func names(_ w: [ClientCheck]) -> String {
        let n = w.map(\.name)
        return n.count <= 1 ? (n.first ?? "") : n.dropLast().joined(separator: ", ") + " and " + n.last!
    }

    func title(_ w: [ClientCheck]) -> String { "\(names(w)) can read Messages without Veil" }
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
        HStack(spacing: 12) {
            Image(systemName: icon(c.reach)).font(.system(size: 17)).foregroundStyle(color(c.reach)).frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(c.headline).font(.system(size: 13, weight: .medium))
                    Text(model.isConnected(c) ? "Connected" : "Seen \(c.lastSeen.relative)").font(.system(size: 11)).foregroundStyle(.tertiary)
                }
                Text(c.detail).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if !model.isConnected(c) {
                Button("Forget") { model.forgetClientCheck(c.name) }.buttonStyle(QuietButtonStyle()).controlSize(.small)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
    }

    func icon(_ r: ChatDBReach) -> String {
        switch r {
        case .readable: return "exclamationmark.circle.fill"
        case .blocked: return "checkmark.circle.fill"
        case .cantCheckHTTP, .cantCheckOldRelay: return "questionmark.circle"
        }
    }

    func color(_ r: ChatDBReach) -> Color {
        switch r {
        case .readable: return Theme.caution
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
                        Text("These have Full Disk Access, so they can read your messages without asking Veil. Highlighted ones can run an AI assistant; anything launched from them inherits that access.")
                            .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            .padding(.horizontal, 14).padding(.top, 12).padding(.bottom, 6)
                        ForEach(list) { g in
                            HStack(spacing: 10) {
                                Image(systemName: icon(g.kind)).font(.system(size: 13))
                                    .foregroundStyle(g.isLikelyAssistantHost ? Theme.caution : .secondary).frame(width: 20)
                                Text(g.name).font(.system(size: 13, weight: g.isLikelyAssistantHost ? .medium : .regular))
                                if g.isPath { Text(g.client).font(.system(size: 11, design: .monospaced)).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle) }
                                Spacer()
                                if g.isLikelyAssistantHost { Pill(text: g.kind.label, color: Theme.caution) }
                            }
                            .padding(.horizontal, 14).padding(.vertical, 6)
                        }
                        HStack {
                            Text("Turn off any you don't need.").font(.system(size: 12)).foregroundStyle(.secondary)
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

/// One line in the menu bar panel when an assistant can skip the gate.
struct BypassMenuRow: View {
    @EnvironmentObject var model: AppModel
    var open: () -> Void

    var body: some View {
        let w = model.bypassWarnings
        if !w.isEmpty {
            Button(action: open) {
                HStack(alignment: .top, spacing: 8) {
                    Circle().fill(Theme.caution).frame(width: 7, height: 7).padding(.top, 4)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(w.count == 1 ? w[0].headline : "\(w.count) assistants can read Messages without Veil")
                            .font(.system(size: 12, weight: .medium))
                        Text(w.count == 1 ? "The app it runs in has Full Disk Access." : "The apps they run in have Full Disk Access.")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(.tertiary).padding(.top, 3)
                }
                .padding(10).background(Theme.caution.opacity(0.09), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                .contentShape(Rectangle())
            }.buttonStyle(.plain)
        }
    }
}
