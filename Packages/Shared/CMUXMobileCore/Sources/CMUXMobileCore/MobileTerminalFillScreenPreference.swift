import Foundation

/// Whether the phone takes over a terminal it shares with the same user's Mac
/// so the grid fills the phone instead of fitting both screens. Shared by the
/// writer (the iOS Settings screen) and the reader (the shell composite when a
/// size state arrives).
public struct MobileTerminalFillScreenPreference {
    /// UserDefaults key, written by Settings and read when a size state arrives.
    public static let defaultsKey = "cmux.mobile.fillScreenWhenShared"

    private let defaults: UserDefaults

    /// Creates a reader backed by the supplied defaults store.
    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// The stored preference, `true` when nothing is stored.
    public var isEnabled: Bool {
        defaults.object(forKey: Self.defaultsKey) as? Bool ?? true
    }
}
