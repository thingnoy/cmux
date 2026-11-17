public import CmuxTerminalSizing

/// What a phone sends so it fills its screen in a shared terminal.
public struct TerminalFillScreenClaim: Equatable, Sendable {
    /// Whether to report `counts_override: true` for this phone first.
    public var countsThisPhone: Bool
    /// The policy to set, or `nil` when the policy is already this phone's.
    public var policy: TerminalSizingPolicy?

    public init(countsThisPhone: Bool, policy: TerminalSizingPolicy?) {
        self.countsThisPhone = countsThisPhone
        self.policy = policy
    }
}

extension TerminalSizingState {
    /// What this phone must send to fill its screen in this terminal, or `nil`
    /// to leave the terminal alone.
    ///
    /// Under the default fit-everyone policy the grid is the smallest attached
    /// viewport, so a phone next to a shorter Mac pane letterboxes. Putting this
    /// phone first in a priority policy, with the phone counted, gives it the
    /// grid while it shows the terminal; the Mac takes it back once the phone
    /// leaves or hands off. Three states qualify:
    /// - the default policy letterboxing a phone with no counts choice;
    /// - follow latest with this phone counted (build 7's claim), because any
    ///   Mac input resized the grid under the phone;
    /// - this phone's own priority claim without a counts choice, which is how
    ///   the Mac sees a phone back from a hand-off.
    /// Every other policy or counts choice is someone's decision.
    /// - Parameter participantID: The phone's participant id.
    public func fillScreenClaim(for participantID: String) -> TerminalFillScreenClaim? {
        guard let phone = participant(participantID)?.participant,
              let viewport = phone.viewport else { return nil }
        let phoneFirst = TerminalSizingPolicy(mode: .priority, priority: [phone.priorityKey])
        let letterboxed = cols < viewport.cols || rows < viewport.rows
        switch phone.countsOverride {
        case nil where policy == .fitEveryone && letterboxed:
            return TerminalFillScreenClaim(countsThisPhone: true, policy: phoneFirst)
        case nil where policy == phoneFirst:
            return TerminalFillScreenClaim(countsThisPhone: true, policy: nil)
        case true? where policy == .latest:
            return TerminalFillScreenClaim(countsThisPhone: false, policy: phoneFirst)
        default:
            return nil
        }
    }
}
