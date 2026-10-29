import CmuxMobileShellModel
import CmuxTerminalSizing
import Testing

private let phoneID = "mobile:phone"
private let phoneFirst = TerminalSizingPolicy(mode: .priority, priority: ["u_maya/iphone/phone-device"])

private func phone(
    viewport: TerminalGridSize? = TerminalGridSize(cols: 72, rows: 60),
    countsOverride: Bool? = nil
) -> TerminalSizingParticipant {
    TerminalSizingParticipant(
        id: phoneID,
        userID: "u_maya",
        deviceKind: .iphone,
        deviceID: "phone-device",
        viewport: viewport,
        countsOverride: countsOverride
    )
}

private func state(
    grid: TerminalGridSize = TerminalGridSize(cols: 72, rows: 44),
    policy: TerminalSizingPolicy = .fitEveryone,
    phone: TerminalSizingParticipant? = phone()
) -> TerminalSizingState {
    let mac = TerminalSizingParticipant(
        id: "c3",
        userID: "u_maya",
        deviceKind: .mac,
        viewport: TerminalGridSize(cols: 120, rows: 44)
    )
    return TerminalSizingState(
        generation: 1,
        cols: grid.cols,
        rows: grid.rows,
        reason: .smallest,
        owners: ["c3"],
        policy: policy,
        participants: ([mac] + [phone].compactMap { $0 })
            .map { TerminalSizingParticipantState(participant: $0, counts: true) }
    )
}

@Suite struct TerminalSizingStateFillScreenClaimTests {
    @Test func letterboxedInEitherDimensionPutsThisPhoneFirst() {
        #expect(state().fillScreenPolicy(for: phoneID) == phoneFirst)
        #expect(state(grid: TerminalGridSize(cols: 60, rows: 60)).fillScreenPolicy(for: phoneID) == phoneFirst)
    }

    @Test func gridThatFillsThePhoneUnderTheDefaultIsLeftAlone() {
        #expect(state(grid: TerminalGridSize(cols: 72, rows: 60)).fillScreenPolicy(for: phoneID) == nil)
    }

    /// Build 7 set follow-latest with the phone counted. Any Mac keystroke then
    /// resized the grid under the phone, so that claim moves to priority even
    /// while the phone currently fills.
    @Test func followLatestWithThisPhoneCountedMovesToPriority() {
        let claimed = state(
            grid: TerminalGridSize(cols: 72, rows: 60),
            policy: .latest,
            phone: phone(countsOverride: true)
        )
        #expect(claimed.fillScreenPolicy(for: phoneID) == phoneFirst)
    }

    @Test func followLatestWithoutTheCountsClaimIsLeftAlone() {
        #expect(state(policy: .latest).fillScreenPolicy(for: phoneID) == nil)
        #expect(state(policy: .latest, phone: phone(countsOverride: false)).fillScreenPolicy(for: phoneID) == nil)
    }

    @Test func otherPoliciesAndCountsChoicesAreLeftAlone() {
        let fixed = TerminalSizingPolicy(mode: .fixed, fixed: TerminalGridSize(cols: 60, rows: 30))
        #expect(state(policy: fixed).fillScreenPolicy(for: phoneID) == nil)
        #expect(state(policy: phoneFirst).fillScreenPolicy(for: phoneID) == nil)
        #expect(state(phone: phone(countsOverride: true)).fillScreenPolicy(for: phoneID) == nil)
        #expect(state(phone: phone(countsOverride: false)).fillScreenPolicy(for: phoneID) == nil)
    }

    @Test func phoneMissingFromStateOrWithoutViewportIsLeftAlone() {
        #expect(state(phone: nil).fillScreenPolicy(for: phoneID) == nil)
        #expect(state(phone: phone(viewport: nil)).fillScreenPolicy(for: phoneID) == nil)
    }
}
