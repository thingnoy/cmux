import AppKit
import CmuxDictation
import Foundation

/// Picks the insertion route per transcript: cmux frontmost → focused
/// surface sink; anything else → system clipboard sink.
///
/// The system sink receives the frontmost PID captured at insert time, so a
/// focus change mid-session re-activates the original target instead of
/// pasting into whatever the user switched to.
@MainActor
struct DictationRoutingSink: DictationTextSink {
    private let surfaceSink: DictationSurfaceTextSink
    private let systemSink: SystemPasteboardInsertionSink
    private let ownBundleID: String

    /// Creates the router over the two concrete sinks. No default values:
    /// both sinks are `@MainActor`-isolated, so they must be constructed at
    /// the (main-actor) call site rather than in a default-argument
    /// generator.
    init(
        surfaceSink: DictationSurfaceTextSink,
        systemSink: SystemPasteboardInsertionSink,
        ownBundleID: String = Bundle.main.bundleIdentifier ?? ""
    ) {
        self.surfaceSink = surfaceSink
        self.systemSink = systemSink
        self.ownBundleID = ownBundleID
    }

    func insertDictationText(_ text: String) -> Bool {
        let frontmost = NSWorkspace.shared.frontmostApplication
        switch DictationSinkChoiceResolver.choose(
            frontmostBundleID: frontmost?.bundleIdentifier,
            ownBundleID: ownBundleID
        ) {
        case .focusedSurface:
            return surfaceSink.insertDictationText(text)
        case .systemPasteboard:
            if systemSink.targetPID == nil {
                systemSink.targetPID = frontmost?.processIdentifier
            }
            return systemSink.insertDictationText(text)
        }
    }
}
