import SwiftUI
import VeilCore

enum Pane: String, CaseIterable, Identifiable {
    case chats = "Chats", activity = "Activity", connect = "Connect", setup = "Setup & safety", settings = "Settings"
    var id: String { rawValue }
    var icon: String {
        switch self {
        case .chats: return "bubble.left.and.bubble.right"
        case .activity: return "clock"
        case .connect: return "link"
        case .setup: return "checkmark.shield"
        case .settings: return "gearshape"
        }
    }
}

struct MainView: View {
    @EnvironmentObject var model: AppModel
    @State var pane: Pane = .chats
    @State var selectedChat: String?

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider().opacity(0.5)
            Group {
                if let problem = model.diskAccessProblem, pane == .chats {
                    OnboardingView(problem: problem)
                } else {
                    switch pane {
                    case .chats: ChatsView(selection: $selectedChat)
                    case .activity: ActivityView()
                    case .connect: ConnectView()
                    case .setup: SetupView()
                    case .settings: SettingsView()
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .id(model.themeID)
        .alert("Couldn't save that change", isPresented: Binding(get: { model.saveError != nil }, set: { if !$0 { model.saveError = nil } })) {
            Button("OK") { model.saveError = nil }
        } message: {
            Text((model.saveError ?? "") + " Nothing was changed, so the assistant's access stays as it was.")
        }
        .background(Theme.window)
        .frame(minWidth: 860, minHeight: 560)
    }

    var sidebar: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 10) {
                AppIconTile(size: 30, dimmed: model.state.paused)
                VStack(alignment: .leading, spacing: 0) {
                    Text("Veil").font(.system(size: 13, weight: .semibold))
                    Text(model.state.paused ? "Paused" : "\(model.sharedCount) chats shared")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 10).padding(.top, 36).padding(.bottom, 18)

            ForEach(Pane.allCases) { p in
                Button { pane = p } label: {
                    HStack(spacing: 9) {
                        Image(systemName: p.icon).frame(width: 18)
                        Text(p.rawValue)
                        Spacer()
                        if p == .chats, !model.newChats.isEmpty { Pill(text: "\(model.newChats.count) new", color: Theme.accent) }
                        if p == .setup, model.diskAccessProblem != nil || isTampered || !model.bypassWarnings.isEmpty { Circle().fill(Theme.caution).frame(width: 7, height: 7) }
                    }
                    .font(.system(size: 13, weight: pane == p ? .medium : .regular))
                    .padding(.horizontal, 10).padding(.vertical, 7)
                    .background(pane == p ? Theme.subtle : .clear, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Spacer()
            Toggle(isOn: Binding(get: { model.state.paused }, set: { model.setPaused($0) })) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Pause everything").font(.system(size: 12, weight: .medium))
                    Text("\(model.assistantName) sees nothing").font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.switch).controlSize(.mini).tint(Theme.accent)
            .padding(10)
        }
        .padding(.horizontal, 10).padding(.bottom, 10)
        .frame(width: 210)
        .background(Theme.subtle.opacity(0.5))
    }

    var isTampered: Bool { if case .tampered = model.integrity { return true }; return false }
}

struct PaneHeader: View {
    let title: String
    let subtitle: String
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 22, weight: .semibold))
            Text(subtitle).font(.system(size: 13)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct OnboardingView: View {
    @EnvironmentObject var model: AppModel
    let problem: String

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            Image(systemName: "lock.open.display").font(.system(size: 34, weight: .light)).foregroundStyle(Theme.accent)
            PaneHeader(title: "One permission to get started",
                       subtitle: "Veil needs Full Disk Access so it can read your Messages history on this Mac. Nothing leaves your Mac unless you allow it, chat by chat.")
            Card {
                step(1, "Open Privacy & Security → Full Disk Access", "Use the button below.")
                Divider().padding(.leading, 52)
                step(2, "Turn on Veil", "If it isn't listed, click + and choose Veil in your Applications folder.")
                Divider().padding(.leading, 52)
                step(3, "Come back here", "Veil checks again automatically.")
            }
            .frame(maxWidth: 520)
            HStack(spacing: 10) {
                Button("Open System Settings") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!)
                }.buttonStyle(PrimaryButtonStyle())
                Button("Check again") { model.reload() }.buttonStyle(QuietButtonStyle())
            }
            Text("Please don't give Full Disk Access to \(model.assistantName) itself. That would let it read every chat directly and skip this gate.")
                .font(.system(size: 12)).foregroundStyle(.secondary).frame(maxWidth: 520, alignment: .leading)
            Spacer()
        }
        .padding(40)
        .frame(maxWidth: .infinity, alignment: .leading)
        .onReceive(Timer.publish(every: 3, on: .main, in: .common).autoconnect()) { _ in model.reload() }
    }

    func step(_ n: Int, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Text("\(n)").font(.system(size: 12, weight: .semibold, design: .rounded))
                .frame(width: 22, height: 22).background(Theme.subtle, in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .medium))
                Text(detail).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
    }
}
