import Testing
@testable import CmuxDictation

/// Insertion-route decision — pins the contract "cmux terminal → surface,
/// everything else → system clipboard".
@Suite
struct DictationSinkChoiceTests {
    private let ownID = "com.cmuxterm.app"

    @Test("Frontmost cmux routes to the focused surface")
    func frontmostSelfUsesSurface() {
        #expect(
            DictationSinkChoiceResolver.choose(frontmostBundleID: ownID, ownBundleID: ownID)
                == .focusedSurface
        )
    }

    @Test("Any other frontmost app routes to the system clipboard")
    func frontmostOtherUsesClipboard() {
        #expect(
            DictationSinkChoiceResolver.choose(frontmostBundleID: "com.apple.Safari", ownBundleID: ownID)
                == .systemPasteboard
        )
    }

    @Test("Undeterminable frontmost falls back to the clipboard contract")
    func unknownFallsBackToClipboard() {
        #expect(
            DictationSinkChoiceResolver.choose(frontmostBundleID: nil, ownBundleID: ownID)
                == .systemPasteboard
        )
    }
}
