import SwiftUI
import AppKit
import VeilCore

/// `Veil --snapshot <dir>` renders each screen with demo data to PNGs.
/// Handy for reviewing the UI without granting any permissions.
@MainActor
enum Snapshot {
    static func run(model: AppModel, to dir: URL) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        model.reloadNow()
        // The ordinary screens show no bypass warnings; they get their own snapshots below.
        for c in AppModel.demoClientChecks { model.forgetClientCheck(c.name) }
        model.clientChecks = model.clientCheckStore.all
        // Simulate an assistant session so the log, drafts and approval prompt have content.
        let g = model.gate
        _ = g.call(tool: "list_chats", arguments: [:], client: "Assistant")
        _ = g.call(tool: "waiting_on_reply", arguments: [:], client: "Assistant")
        _ = g.call(tool: "read_chat", arguments: ["chat_id": .string(DemoData.ID.mom)], client: "Assistant")
        _ = g.call(tool: "read_chat", arguments: ["chat_id": .string(DemoData.ID.therapist)], client: "Assistant")
        _ = g.call(tool: "search_messages", arguments: ["query": "Thursday"], client: "Assistant")
        _ = g.call(tool: "draft_reply", arguments: ["chat_id": .string(DemoData.ID.alex), "text": "Booked the 7pm slot, see you there!"], client: "Assistant")
        _ = g.call(tool: "request_send", arguments: ["chat_id": .string(DemoData.ID.mom), "text": "Free now, calling you in 5!"], client: "Assistant")
        model.log = g.log.all
        model.drafts = g.drafts
        model.sends = g.sends
        model.clients = ["Assistant"]
        model.assistantName = "Assistant"   // same screenshots on every Mac (demo runs use their own defaults domain)

        for dark in [false, true] {
            let suffix = dark ? "-dark" : ""
            render(MainView(pane: .chats, selectedChat: DemoData.ID.mom), size: CGSize(width: 960, height: 640), dark: dark, to: dir.appendingPathComponent("chats\(suffix).png"), model: model)
            render(MainView(pane: .chats, selectedChat: DemoData.ID.unknown), size: CGSize(width: 960, height: 640), dark: dark, to: dir.appendingPathComponent("chats-new\(suffix).png"), model: model)
            render(MainView(pane: .activity), size: CGSize(width: 960, height: 640), dark: dark, to: dir.appendingPathComponent("activity\(suffix).png"), model: model)
            render(MainView(pane: .connect), size: CGSize(width: 960, height: 1000), dark: dark, to: dir.appendingPathComponent("connect\(suffix).png"), model: model)
            render(MainView(pane: .setup), size: CGSize(width: 960, height: 760), dark: dark, to: dir.appendingPathComponent("setup\(suffix).png"), model: model)
            render(MenuBarView(openMain: { _ in }), size: nil, dark: dark, to: dir.appendingPathComponent("menu\(suffix).png"), model: model)
            render(ApprovalPanelView().background(Theme.card), size: nil, dark: dark, to: dir.appendingPathComponent("approval\(suffix).png"), model: model)
        }
        render(MainView(pane: .settings), size: CGSize(width: 960, height: 2900), dark: false, to: dir.appendingPathComponent("settings.png"), model: model)
        model.webhookKeySaved = true   // in memory only, to show the saved-key layout
        render(MainView(pane: .settings), size: CGSize(width: 780, height: 3200), dark: true, to: dir.appendingPathComponent("settings-narrow-dark.png"), model: model)
        model.webhookKeySaved = false
        model.accent = .ocean; model.surface = .neutral
        render(MainView(pane: .chats, selectedChat: DemoData.ID.mom), size: CGSize(width: 960, height: 640), dark: true, to: dir.appendingPathComponent("chats-ocean-neutral-dark.png"), model: model)
        model.accent = .graphite; model.surface = .warm
        // Auto-send: Mom set to auto-send, one message sent without a prompt.
        model.setAutoSend(true, for: DemoData.ID.mom)
        _ = g.call(tool: "request_send", arguments: ["chat_id": .string(DemoData.ID.mom), "text": "Running 10 minutes late, start without me!"], client: "Assistant")
        model.autoSendHistory = g.autoSends.all
        model.log = g.log.all
        render(MainView(pane: .chats, selectedChat: DemoData.ID.mom), size: CGSize(width: 960, height: 760), dark: false, to: dir.appendingPathComponent("chats-autosend.png"), model: model)
        render(ActivityView(filter: .autoSent).background(Theme.window), size: CGSize(width: 760, height: 420), dark: false, to: dir.appendingPathComponent("activity-autosent.png"), model: model)
        render(MenuBarView(openMain: { _ in }), size: nil, dark: false, to: dir.appendingPathComponent("menu-autosend.png"), model: model)
        // Activity only: the therapist chat shares timing, never content.
        model.setAccess(ChatAccess(activity: true), for: DemoData.ID.therapist)
        render(MainView(pane: .chats, selectedChat: DemoData.ID.therapist), size: CGSize(width: 960, height: 800), dark: false, to: dir.appendingPathComponent("chats-activity.png"), model: model)
        render(MainView(pane: .chats, selectedChat: DemoData.ID.therapist), size: CGSize(width: 960, height: 800), dark: true, to: dir.appendingPathComponent("chats-activity-dark.png"), model: model)
        // Assistant can change settings: Ask me, with one request waiting; then Apply directly.
        model.setAgentSettings(.ask)
        _ = g.call(tool: "change_chat_settings", arguments: ["chat_id": .string(DemoData.ID.alex), "send": true, "auto_send": true], client: "Assistant")
        model.settingsRequests = g.settingsRequests
        model.log = g.log.all
        for dark in [false, true] {
            render(ApprovalPanelView().background(Theme.card), size: nil, dark: dark, to: dir.appendingPathComponent("approval-settings\(dark ? "-dark" : "").png"), model: model)
            render(MainView(pane: .settings), size: CGSize(width: 960, height: 900), dark: dark, to: dir.appendingPathComponent("settings-agent\(dark ? "-dark" : "").png"), model: model)
        }
        render(MenuBarView(openMain: { _ in }), size: nil, dark: false, to: dir.appendingPathComponent("menu-settings.png"), model: model)
        for r in g.settingsRequests { g.declineSettings(r.id) }
        model.setAgentSettings(.direct)
        _ = g.call(tool: "change_chat_settings", arguments: ["chat_id": .string(DemoData.ID.climbing), "activity": true], client: "Assistant")
        model.log = g.log.all
        render(MainView(pane: .settings), size: CGSize(width: 960, height: 900), dark: false, to: dir.appendingPathComponent("settings-agent-direct.png"), model: model)
        render(ActivityView().background(Theme.window), size: CGSize(width: 760, height: 420), dark: false, to: dir.appendingPathComponent("activity-settings.png"), model: model)
        model.setAgentSettings(.off)
        model.settingsRequests = g.settingsRequests
        // Content filter: Alex's chat is filtered in demo mode, with sensitive-looking demo messages.
        model.refreshFilterStatus()
        _ = g.call(tool: "read_chat", arguments: ["chat_id": .string(DemoData.ID.alex)], client: "Assistant")
        model.log = g.log.all
        model.loadFilterReview(DemoData.ID.alex, wait: true)
        for dark in [false, true] {
            render(MainView(pane: .chats, selectedChat: DemoData.ID.alex), size: CGSize(width: 960, height: 1900), dark: dark,
                   to: dir.appendingPathComponent("chats-filter\(dark ? "-dark" : "").png"), model: model)
            render(MainView(pane: .settings), size: CGSize(width: 960, height: 2900), dark: dark,
                   to: dir.appendingPathComponent("settings-filter\(dark ? "-dark" : "").png"), model: model)
        }
        render(ActivityView().background(Theme.window), size: CGSize(width: 760, height: 420), dark: false, to: dir.appendingPathComponent("activity-filter.png"), model: model)
        // This chat's own settings, with codes allowed (warning), and Apple Intelligence off.
        var custom = FilterPolicy.standard
        custom.set(.codes, .allow); custom.set(.profanity, .allow); custom.attachments = .allow
        model.setChatFilterPolicy(custom, for: DemoData.ID.alex)
        model.filterStatus = .unavailable("Apple Intelligence is turned off. Turn it on in System Settings → Apple Intelligence & Siri.")
        model.loadFilterReview(DemoData.ID.alex, wait: true)
        for dark in [false, true] {
            render(MainView(pane: .chats, selectedChat: DemoData.ID.alex), size: CGSize(width: 960, height: 2700), dark: dark,
                   to: dir.appendingPathComponent("chats-filter-custom\(dark ? "-dark" : "").png"), model: model)
        }
        model.setChatFilterPolicy(nil, for: DemoData.ID.alex)
        model.refreshFilterStatus()
        // Locked: a permissions file whose key didn't come over from the old install (in memory only).
        let saved = (model.integrity, model.signingKeyMissing, model.legacyKeyAvailable)
        model.integrity = .tampered("The key that signs your permissions isn't in your Keychain, so the permissions file can't be checked.")
        model.signingKeyMissing = true; model.legacyKeyAvailable = true
        for dark in [false, true] {
            render(MainView(pane: .setup), size: CGSize(width: 960, height: 760), dark: dark, to: dir.appendingPathComponent("setup-locked\(dark ? "-dark" : "").png"), model: model)
        }
        render(MenuBarView(openMain: { _ in }), size: nil, dark: false, to: dir.appendingPathComponent("menu-locked.png"), model: model)
        (model.integrity, model.signingKeyMissing, model.legacyKeyAvailable) = saved
        // Bypass warnings: Grok Bot's app has Full Disk Access; Assistant checked out fine; a web client can't be checked.
        model.clientCheckStore.record(ClientCheck(name: "Assistant", transport: .relay, reach: .blocked))
        for c in AppModel.demoClientChecks { model.clientCheckStore.record(c) }
        model.clientCheckStore.record(ClientCheck(name: "Grok Bot", transport: .relay, reach: .readable))
        model.clientChecks = model.clientCheckStore.all
        model.clients = ["Assistant", "Grok Bot"]
        for dark in [false, true] {
            let suffix = dark ? "-dark" : ""
            render(MainView(pane: .setup), size: CGSize(width: 960, height: 1500), dark: dark, to: dir.appendingPathComponent("setup-bypass\(suffix).png"), model: model)
            render(MainView(pane: .connect), size: CGSize(width: 960, height: 1100), dark: dark, to: dir.appendingPathComponent("connect-bypass\(suffix).png"), model: model)
            render(MenuBarView(openMain: { _ in }), size: nil, dark: dark, to: dir.appendingPathComponent("menu-bypass\(suffix).png"), model: model)
        }
        render(BypassNotice(expanded: true).padding(20).frame(width: 640).background(Theme.window), size: nil, dark: false,
               to: dir.appendingPathComponent("notice-expanded.png"), model: model)
        // After "I understand": a quiet status line instead of the notice.
        model.acknowledge(ClientCheck(name: "Grok Bot", transport: .relay, reach: .readable))
        render(MainView(pane: .setup), size: CGSize(width: 960, height: 1300), dark: false, to: dir.appendingPathComponent("setup-acknowledged.png"), model: model)
        render(MenuBarView(openMain: { _ in }), size: nil, dark: false, to: dir.appendingPathComponent("menu-acknowledged.png"), model: model)
        model.unacknowledge(ClientCheck(name: "Grok Bot", transport: .relay, reach: .readable))
        for c in model.clientCheckStore.all { model.forgetClientCheck(c.name) }
        model.clientChecks = []
        model.clients = ["Assistant"]
        // One-click connect, on the demo's fake home folder: the review sheet, then the result.
        model.propose(.add, for: .claudeDesktop)
        if let change = model.pendingChange {
            for dark in [false, true] {
                render(ConnectConfirmView(change: change, showWholeFile: true), size: nil, dark: dark,
                       to: dir.appendingPathComponent("connect-confirm\(dark ? "-dark" : "").png"), model: model)
            }
            model.confirm(change)
        }
        model.propose(.fix, for: .cursor)
        if let change = model.pendingChange {
            render(ConnectConfirmView(change: change), size: nil, dark: false, to: dir.appendingPathComponent("connect-confirm-fix.png"), model: model)
            model.pendingChange = nil
        }
        render(MainView(pane: .connect), size: CGSize(width: 960, height: 1000), dark: false, to: dir.appendingPathComponent("connect-added.png"), model: model)
        renderGlyphs(to: dir.appendingPathComponent("menubar-glyph.png"))
        model.diskAccessProblem = "no access"
        render(MainView(pane: .chats), size: CGSize(width: 960, height: 640), dark: false, to: dir.appendingPathComponent("onboarding.png"), model: model)
        print("Snapshots written to \(dir.path)")
    }

    /// The menu bar glyph in each state, at 1x and 2x, on light and dark menu bar colors.
    static func renderGlyphs(to url: URL) {
        let styles: [VeilGlyph.Style] = [.normal, .attention, .paused]
        let cell: CGFloat = 44, scale: CGFloat = 4
        let rows: [(NSColor, NSColor)] = [(NSColor(white: 0.93, alpha: 1), .black), (NSColor(white: 0.16, alpha: 1), .white)]
        let width = Int(cell * CGFloat(styles.count * 2) * scale), height = Int(cell * CGFloat(rows.count) * scale)
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4,
                                         hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let ctx = NSGraphicsContext(bitmapImageRep: rep) else { return }
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = ctx
        for (r, (bg, fg)) in rows.enumerated() {
            for (c, style) in (styles + styles).enumerated() {
                let px: CGFloat = c < styles.count ? 1 : 2   // left half: 1x pixels, right half: 2x pixels
                let origin = CGPoint(x: CGFloat(c) * cell * scale, y: CGFloat(rows.count - 1 - r) * cell * scale)
                bg.setFill(); CGRect(origin: origin, size: CGSize(width: cell * scale, height: cell * scale)).fill()
                // Draw at the real pixel size, then blow it up without smoothing to show actual pixels.
                let img = VeilGlyph.menuBarImage(style)
                let pixels = Int(18 * px)
                guard let small = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4,
                                                   hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
                      let sctx = NSGraphicsContext(bitmapImageRep: small) else { continue }
                NSGraphicsContext.current = sctx
                img.draw(in: CGRect(x: 0, y: 0, width: pixels, height: pixels))
                fg.set(); CGRect(x: 0, y: 0, width: pixels, height: pixels).fill(using: .sourceIn)
                NSGraphicsContext.current = ctx
                ctx.imageInterpolation = .none
                let side = 18 * scale * 2
                NSImage(cgImage: small.cgImage!, size: .zero).draw(in: CGRect(x: origin.x + (cell * scale - side) / 2, y: origin.y + (cell * scale - side) / 2, width: side, height: side))
            }
        }
        NSGraphicsContext.restoreGraphicsState()
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }

    static func render<V: View>(_ view: V, size: CGSize?, dark: Bool, to url: URL, model: AppModel) {
        let host = NSHostingView(rootView: view.environmentObject(model))
        let fitting = size ?? host.fittingSize
        host.frame = CGRect(origin: .zero, size: fitting)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }
}
