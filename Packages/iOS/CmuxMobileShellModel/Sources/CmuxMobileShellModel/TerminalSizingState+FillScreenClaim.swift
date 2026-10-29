public import CmuxTerminalSizing

extension TerminalSizingState {
    /// The policy that lets a phone fill its screen in this terminal, or `nil`
    /// to leave the terminal alone.
    ///
    /// Under the default fit-everyone policy the grid is the smallest attached
    /// viewport, so a phone next to a shorter Mac pane letterboxes. Putting this
    /// phone first in a priority policy gives it the grid while it counts, and
    /// the Mac takes it back once the phone leaves or hands off. Follow latest
    /// is not enough: any Mac input resizes the grid under the phone, so a
    /// follow-latest policy with this phone counted (build 7's claim) moves
    /// over too. Every other policy or counts choice is someone's decision.
    /// - Parameter participantID: The phone's participant id.
    public func fillScreenPolicy(for participantID: String) -> TerminalSizingPolicy? {
        guard let phone = participant(participantID)?.participant,
              let viewport = phone.viewport else { return nil }
        let letterboxed = cols < viewport.cols || rows < viewport.rows
        let defaultLetterbox = policy == .fitEveryone && phone.countsOverride == nil && letterboxed
        let followLatestClaim = policy == .latest && phone.countsOverride == true
        guard defaultLetterbox || followLatestClaim else { return nil }
        return TerminalSizingPolicy(mode: .priority, priority: [phone.priorityKey])
    }
}
