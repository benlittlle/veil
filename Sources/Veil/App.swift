import SwiftUI
import AppKit
import Combine
import VeilCore

@main
struct VeilApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(openMain: { delegate.showMain($0) }).environmentObject(delegate.model)
        } label: {
            MenuBarIcon(glyph: delegate.model.glyph)
        }
        .menuBarExtraStyle(.window)
    }
}

struct MenuBarIcon: View {
    /// Only the glyph's own state, so the status item doesn't redraw on every model change.
    @ObservedObject var glyph: MenuBarGlyph
    var body: some View {
        // A template glyph of the Veil mark: hollow bubble when paused, a dot when a send is waiting.
        Image(nsImage: VeilGlyph.menuBarImage(glyph.style))
    }
}

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let args = CommandLine.arguments
    lazy var model: AppModel = {
        let demo = args.contains("--demo") || args.contains("--snapshot")
        // Bring over an install from before the rename first, so the model reads the moved settings.
        return AppModel(mode: demo ? .demo : .live, migration: demo ? nil : AppModel.migrateLegacyInstall())
    }()
    private var mainWindow: NSWindow?
    private var hosting: NSHostingController<AnyView>?
    private var panel: NSPanel?
    private var panelCloser: AnyCancellable?

    func applicationDidFinishLaunching(_ note: Notification) {
        if let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count {
            MainActor.assumeIsolated { Snapshot.run(model: model, to: URL(fileURLWithPath: args[i + 1])) }
            exit(0)
        }
        NSApp.setActivationPolicy(.accessory)
        MainActor.assumeIsolated {
            model.onSendRequested = { [weak self] _ in self?.showApproval() }
            model.onSettingsRequested = { [weak self] _ in self?.showApproval() }
            model.start()
            if !args.contains("--demo") { Updates.shared.start() }
            // First run, or something needs attention: open the window.
            if args.contains("--no-window") {
            } else if case .tampered = model.integrity {
                showMain(.setup)   // everything is off until the user looks; make that obvious
            } else if model.diskAccessProblem != nil || !model.newChats.isEmpty || args.contains("--demo") {
                showMain(.chats)
            }
        }
    }

    func applicationWillTerminate(_ n: Notification) { MainActor.assumeIsolated { model.stop() } }

    @MainActor func showMain(_ pane: Pane) {
        model.reload()
        let view = AnyView(MainView(pane: pane).environmentObject(model))
        if let w = mainWindow, let hosting {
            hosting.rootView = view
            w.makeKeyAndOrderFront(nil)
        } else {
            let h = NSHostingController(rootView: view)
            let w = NSWindow(contentViewController: h)
            w.title = "Veil"
            w.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            w.isReleasedWhenClosed = false
            w.setContentSize(NSSize(width: 960, height: 640))
            w.center()
            w.setFrameAutosaveName("MainWindow")
            w.delegate = self
            mainWindow = w; hosting = h
            w.makeKeyAndOrderFront(nil)
        }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ n: Notification) {
        guard let w = n.object as? NSWindow, w == mainWindow else { return }
        NSApp.setActivationPolicy(.accessory)
        // Let the window and its views go once it has closed, so nothing in it keeps updating or
        // holding memory while it's hidden. It's rebuilt (same size and place) when opened again.
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.mainWindow === w, !w.isVisible else { return }
                self.mainWindow = nil; self.hosting = nil
            }
        }
    }

    /// A small floating prompt near the top-right of the screen. Stays until the user decides.
    @MainActor func showApproval() {
        if panel == nil {
            let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 400, height: 220),
                            styleMask: [.titled, .fullSizeContentView, .nonactivatingPanel], backing: .buffered, defer: false)
            p.titlebarAppearsTransparent = true
            p.titleVisibility = .hidden
            p.isMovableByWindowBackground = true
            p.level = .floating
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            p.isReleasedWhenClosed = false
            let h = NSHostingView(rootView: ApprovalPanelView().environmentObject(model))
            h.sizingOptions = [.preferredContentSize]
            p.contentView = h
            panel = p
            // Close the panel automatically once nothing is waiting.
            panelCloser = model.$sends.map { _ in () }.merge(with: model.$settingsRequests.map { _ in () })
                .receive(on: DispatchQueue.main).sink { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, let p = self.panel, p.isVisible, self.model.waitingSends.isEmpty, self.model.waitingSettings.isEmpty else { return }
                    p.orderOut(nil)
                }
            }
        }
        guard let p = panel, let screen = NSScreen.main else { return }
        p.backgroundColor = NSColor(Theme.card)   // follows the current theme
        let size = p.contentView?.fittingSize ?? NSSize(width: 400, height: 220)
        p.setContentSize(size)
        let f = screen.visibleFrame
        p.setFrameOrigin(NSPoint(x: f.maxX - size.width - 16, y: f.maxY - size.height - 16))
        p.orderFrontRegardless()   // shown, but never takes keyboard focus
        NSSound(named: "Tink")?.play()
    }
}
