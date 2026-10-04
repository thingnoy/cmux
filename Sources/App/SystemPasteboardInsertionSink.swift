import AppKit
import CmuxDictation
import Foundation

/// Inserts finalized dictation into ANY frontmost app by riding the system
/// clipboard: snapshot → write transcript → synthetic Cmd+V → restore.
///
/// The same contract Gemini's StreamToCursor uses, because it is the one
/// insertion contract every macOS app honors. Sequence per call:
///
/// 1. Abort when the focused element is a secure text field (AX check).
/// 2. Snapshot the pasteboard items.
/// 3. Write the transcript plus a `com.cmuxterm.dictation-response` sentinel.
/// 4. Re-activate the captured target app when it lost focus mid-session.
/// 5. Post a synthetic Cmd+V to the target PID.
/// 6. Wait `pasteCompletionDelay` so the target consumes the board.
/// 7. Restore the original items.
///
/// Requires the Accessibility TCC permission (event posting); the first
/// failing call arms Apple's system prompt exactly once.
@MainActor
final class SystemPasteboardInsertionSink: DictationTextSink {
    /// PID captured when the dictation session started — the app the user was
    /// typing in when they pressed fn. `nil` falls back to the current
    /// frontmost app.
    var targetPID: pid_t?

    /// How long to leave the transcript on the board before restoring, in
    /// seconds. Too short and the target pastes the restored contents
    /// instead. A bounded one-shot delay, not synchronization (architecture
    /// carve-out: "genuine delay that is itself the intended behavior").
    var pasteCompletionDelaySeconds: TimeInterval = 0.3

    /// Sentinel type marking our own content, so a stale response from a
    /// previous session is recognizable.
    private static let sentinelType = NSPasteboard.PasteboardType("com.cmuxterm.dictation-response")

    func insertDictationText(_ text: String) -> Bool {
        guard Self.accessibilityTrusted() else {
            // First failure arms Apple's system prompt for the next attempt.
            Self.promptAccessibility()
            cmuxDebugLog("dictation.insert system-pasteboard blocked: accessibility not granted")
            return false
        }
        guard let app = Self.resolveTargetApp(targetPID: targetPID) else {
            cmuxDebugLog("dictation.insert system-pasteboard blocked: target app gone")
            return false
        }
        guard !Self.focusedElementIsSecure(in: app) else {
            cmuxDebugLog("dictation.insert system-pasteboard blocked: secure field")
            return false
        }

        let pasteboard = NSPasteboard.general
        let savedPayloads = Self.snapshotPayloads(of: pasteboard)

        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        pasteboard.setData(Data("v1".utf8), forType: Self.sentinelType)

        Self.activateIfNeeded(app)
        Self.postCommandV(to: app.processIdentifier)
        // Leave the transcript readable while the target pastes it.
        Thread.sleep(forTimeInterval: pasteCompletionDelaySeconds)

        Self.restore(payloads: savedPayloads, to: pasteboard)
        cmuxDebugLog("dictation.insert system-pasteboard delivered pid=\(app.processIdentifier)")
        return true
    }

    // MARK: - Snapshot / restore

    private nonisolated static func snapshotPayloads(of pasteboard: NSPasteboard) -> [[NSPasteboard.PasteboardType: Data]] {
        guard let items = pasteboard.pasteboardItems else { return [] }
        return items.compactMap { item in
            var payload: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types ?? [] {
                if let data = item.data(forType: type) { payload[type] = data }
            }
            return payload.isEmpty ? nil : payload
        }
    }

    private nonisolated static func restore(payloads: [[NSPasteboard.PasteboardType: Data]], to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        guard !payloads.isEmpty else { return }
        for payload in payloads {
            let item = NSPasteboardItem()
            for (type, data) in payload {
                item.setData(data, forType: type)
            }
            pasteboard.writeObjects([item])
        }
    }

    // MARK: - Guards

    /// Accessibility is required to post synthetic events to another process.
    nonisolated static func accessibilityTrusted() -> Bool {
        AXIsProcessTrusted()
    }

    /// Arms Apple's one-time system prompt; the system coalesces while a
    /// prompt is already pending.
    nonisolated static func promptAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    /// Resolves the insertion target: the captured PID while alive, otherwise
    /// the current frontmost app.
    nonisolated static func resolveTargetApp(targetPID: pid_t?) -> NSRunningApplication? {
        if let targetPID, let app = NSRunningApplication(processIdentifier: targetPID) {
            return app
        }
        return NSWorkspace.shared.frontmostApplication
    }

    /// True when the target's focused element is a secure text field — paste
    /// into password fields is a hard no, matching Gemini's PasteDecision.
    nonisolated static func focusedElementIsSecure(in app: NSRunningApplication) -> Bool {
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            appElement,
            kAXFocusedUIElementAttribute as CFString,
            &focused
        ) == .success, let focused else {
            return false
        }
        let element = unsafeDowncast(focused as AnyObject, to: AXUIElement.self)
        var role: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXRoleAttribute as CFString,
            &role
        ) == .success, let role else {
            return false
        }
        let roleString = unsafeDowncast(role as AnyObject, to: NSString.self) as String
        return roleString.contains("SecureTextField")
    }

    private nonisolated static func activateIfNeeded(_ app: NSRunningApplication) {
        guard !app.isActive else { return }
        app.activate()
        Thread.sleep(forTimeInterval: 0.12)
    }

    /// Posts a synthetic Cmd+V keystroke to the target process. Virtual key 9
    /// is ANSI V.
    nonisolated static func postCommandV(to pid: pid_t) {
        guard let keyDown = CGEvent(keyboardEventSource: nil, virtualKey: 9, keyDown: true),
              let keyUpEvent = CGEvent(keyboardEventSource: nil, virtualKey: 9, keyDown: false) else {
            return
        }
        keyDown.flags = .maskCommand
        keyUpEvent.flags = .maskCommand
        keyDown.postToPid(pid)
        Thread.sleep(forTimeInterval: 0.03)
        keyUpEvent.postToPid(pid)
    }
}
