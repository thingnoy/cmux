import CmuxMobileShellModel
import CmuxTerminalSizing
import Testing

private let phoneID = "mobile:phone"

private func state(
    grid: TerminalGridSize = TerminalGridSize(cols: 72, rows: 44),
    policy: TerminalSizingPolicy = .fitEveryone,
    phone: TerminalSizingParticipant? = TerminalSizingParticipant(
        id: phoneID,
        userID: "u_maya",
        deviceKind: .iphone,
        viewport: TerminalGridSize(cols: 72, rows: 60)
    )
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
    @Test func letterboxedInEitherDimensionIsClaimable() {
        #expect(state().isFillScreenClaimable(by: phoneID))
        #expect(state(grid: TerminalGridSize(cols: 60, rows: 60)).isFillScreenClaimable(by: phoneID))
    }

    @Test func gridThatFillsThePhoneIsNotClaimable() {
        #expect(!state(grid: TerminalGridSize(cols: 72, rows: 60)).isFillScreenClaimable(by: phoneID))
    }

    @Test func fixedPolicyIsNotClaimable() {
        let fixed = TerminalSizingPolicy(mode: .fixed, fixed: TerminalGridSize(cols: 60, rows: 30))
        #expect(!state(policy: fixed).isFillScreenClaimable(by: phoneID))
    }

    @Test func phoneMissingFromStateOrWithoutViewportIsNotClaimable() {
        #expect(!state(phone: nil).isFillScreenClaimable(by: phoneID))
        let noViewport = TerminalSizingParticipant(id: phoneID, deviceKind: .iphone)
        #expect(!state(phone: noViewport).isFillScreenClaimable(by: phoneID))
    }
}
