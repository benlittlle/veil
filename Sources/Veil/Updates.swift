import AppKit
import Sparkle

/// Auto-updates through Sparkle. Only the built app has a feed (`SUFeedURL` in Info.plist), so
/// `swift run`, demo mode and snapshots never check. Every update is verified against the
/// EdDSA public key in Info.plist (`SUPublicEDKey`) and Apple's code signature before installing.
@MainActor final class Updates {
    static let shared = Updates()
    private var controller: SPUStandardUpdaterController?

    /// True for a built Veil.app that has an update feed configured.
    var isAvailable: Bool {
        Bundle.main.bundleURL.pathExtension == "app"
            && Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") != nil
            && Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") != nil
    }

    var version: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?" }

    func start() {
        guard isAvailable, controller == nil else { return }
        // Sparkle asks the user once (on the second launch) whether to check automatically.
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
    }

    func checkNow() {
        start()
        NSApp.activate(ignoringOtherApps: true)
        controller?.checkForUpdates(nil)
    }
}
