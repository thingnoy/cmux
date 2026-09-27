import Testing
@testable import CmuxDictation

/// Conflict classification over injected keyboard-defaults snapshots.
@Suite
struct FnKeyConflictDetectorTests {
    @Test("Press-fn-twice dictation trigger conflicts with double-tap")
    func autoTriggerConflicts() {
        let detector = FnKeyConflictDetector(
            signals: .init(dictationAutoTrigger: 1, fnUsageType: 0)
        )
        #expect(detector.isConflicted)
        #expect(detector.conflictReason == FnKeyConflictReason.doublePress.rawValue)
    }

    @Test("Globe press set to dictation conflicts with push-to-talk")
    func pressToDictateConflicts() {
        let detector = FnKeyConflictDetector(
            signals: .init(dictationAutoTrigger: nil, fnUsageType: 3)
        )
        #expect(detector.isConflicted)
        #expect(detector.conflictReason == FnKeyConflictReason.pressToDictate.rawValue)
    }

    @Test("Emoji picker and unset keys are conflict-free")
    func clearMachineHasNoConflict() {
        let unset = FnKeyConflictDetector(signals: .init())
        #expect(!unset.isConflicted)
        #expect(unset.conflictReason == nil)

        let emoji = FnKeyConflictDetector(
            signals: .init(dictationAutoTrigger: 0, fnUsageType: 0)
        )
        #expect(!emoji.isConflicted)
    }

    @Test("Auto trigger takes precedence when both signals collide")
    func precedenceIsDeterministic() {
        let detector = FnKeyConflictDetector(
            signals: .init(dictationAutoTrigger: 1, fnUsageType: 3)
        )
        #expect(detector.conflictReason == FnKeyConflictReason.doublePress.rawValue)
    }
}
