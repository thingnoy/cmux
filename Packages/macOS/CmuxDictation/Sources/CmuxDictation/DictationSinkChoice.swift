import Foundation

/// Where a finalized transcript should be inserted.
public enum DictationSinkChoice: Equatable, Sendable {
    /// Frontmost app is cmux itself — write into the focused terminal surface.
    case focusedSurface
    /// Frontmost app is something else — ride the system clipboard + Cmd+V.
    case systemPasteboard
}

/// Decides the insertion route from the frontmost app's bundle ID.
///
/// Pure and injectable so tests pin both routes without AppKit; the app
/// wiring supplies `Bundle.main.bundleIdentifier` as the own-ID.
public enum DictationSinkChoiceResolver {
    /// Chooses the insertion route.
    ///
    /// - Parameters:
    ///   - frontmostBundleID: Bundle ID of the current frontmost application,
    ///     or `nil` when it cannot be determined.
    ///   - ownBundleID: This app's bundle ID.
    /// - Returns: `.focusedSurface` when the frontmost app is cmux itself,
    ///   otherwise `.systemPasteboard` (including the undeterminable case —
    ///   clipboard paste is the contract every app accepts).
    public static func choose(
        frontmostBundleID: String?,
        ownBundleID: String
    ) -> DictationSinkChoice {
        guard let frontmostBundleID else { return .systemPasteboard }
        return frontmostBundleID == ownBundleID ? .focusedSurface : .systemPasteboard
    }
}
