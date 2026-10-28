public import CmuxTerminalSizing

extension TerminalSizingState {
    /// Whether a phone may take over this terminal's size so the grid fills it.
    ///
    /// Under the default fit-everyone policy the grid is the smallest attached
    /// viewport, so a phone next to a shorter Mac pane letterboxes. Following
    /// the latest device with the phone counted gives the grid to whichever
    /// device was used last. Only the untouched default qualifies, never a
    /// policy or counts choice someone made.
    /// - Parameter participantID: The phone's participant id.
    /// - Returns: `true` when the policy is the default, the phone has a
    ///   viewport and no counts override, and the grid is smaller than that
    ///   viewport in some dimension.
    public func isFillScreenClaimable(by participantID: String) -> Bool {
        guard policy == .fitEveryone,
              let phone = participant(participantID)?.participant,
              phone.countsOverride == nil,
              let viewport = phone.viewport else { return false }
        return cols < viewport.cols || rows < viewport.rows
    }
}
