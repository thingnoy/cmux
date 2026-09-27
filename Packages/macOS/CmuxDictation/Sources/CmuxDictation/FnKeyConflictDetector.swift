import Foundation

/// Detects conflicts between cmux's fn-key dictation triggers and Apple's
/// own Globe/Fn dictation behaviors (System Settings > Keyboard > Dictation).
///
/// Mirrors the approach observed in Gemini for Mac's `FnKeyConflictDetector`:
/// read the system's keyboard defaults and warn when a double-press or press
/// gesture on the Globe/Fn key would fire Apple dictation alongside (or
/// instead of) cmux's triggers.
///
/// Signals (both optional; a missing key means "never configured"):
/// - `dictationAutoTrigger`: `com.apple.HIToolbox` `AppleDictationAutoTrigger`
///   — `1` enables Apple's "press 🌐 twice to start dictation" trigger, which
///   collides with cmux's double-tap-fn toggle.
/// - `fnUsageType`: `com.apple.HIToolbox` `AppleFnUsageType` — the
///   "press 🌐 key to" behavior. Value `3` starts dictation from a
///   Globe/Fn press, colliding with cmux's hold-fn push-to-talk. `0`
///   (Emoji & Symbols) and `1` (input source) do not collide.
public struct FnKeyConflictDetector: Equatable, Sendable {
    /// Raw keyboard-defaults values the detector reasons about.
    public struct Signals: Equatable, Sendable {
        /// `AppleDictationAutoTrigger` value, when present.
        public var dictationAutoTrigger: Int?
        /// `AppleFnUsageType` value, when present.
        public var fnUsageType: Int?

        /// Builds a signals snapshot.
        public init(dictationAutoTrigger: Int? = nil, fnUsageType: Int? = nil) {
            self.dictationAutoTrigger = dictationAutoTrigger
            self.fnUsageType = fnUsageType
        }
    }

    /// `AppleFnUsageType` value that starts dictation from a Globe/Fn press.
    /// (0 = Emoji & Symbols, 1 = input source; only 3 collides.)
    private static let dictationFnUsageType = 3

    private let signals: Signals

    /// Builds a detector over an injected signals snapshot.
    public init(signals: Signals) {
        self.signals = signals
    }

    /// Reads the current system keyboard defaults.
    ///
    /// Uses `CFPreferences` so another app's domain is read without touching
    /// `UserDefaults(suiteName:)` (which is not meant for foreign domains).
    public static func readSystemSignals() -> Signals {
        Signals(
            dictationAutoTrigger: Self.readInteger(
                domain: "com.apple.HIToolbox" as CFString,
                key: "AppleDictationAutoTrigger" as CFString
            ),
            fnUsageType: Self.readInteger(
                domain: "com.apple.HIToolbox" as CFString,
                key: "AppleFnUsageType" as CFString
            )
        )
    }

    private static func readInteger(domain: CFString, key: CFString) -> Int? {
        let raw = CFPreferencesCopyAppValue(key, domain)
        return (raw as? NSNumber)?.intValue
    }

    /// Whether any Globe/Fn dictation behavior collides with cmux's triggers.
    public var isConflicted: Bool { conflictReason != nil }

    /// Human-readable conflict description for HUD display; `nil` when clear.
    public var conflictReason: String? {
        if signals.dictationAutoTrigger == 1 {
            return FnKeyConflictReason.doublePress.rawValue
        }
        if signals.fnUsageType == Self.dictationFnUsageType {
            return FnKeyConflictReason.pressToDictate.rawValue
        }
        return nil
    }
}

/// Machine-readable conflict categories.
public enum FnKeyConflictReason: String, Equatable, Sendable {
    /// Apple's "press 🌐 twice to start dictation" trigger is enabled.
    case doublePress
    /// The Globe/Fn press itself is set to start dictation.
    case pressToDictate
}
