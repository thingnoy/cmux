internal import CmuxMobileShellModel
internal import Foundation

@MainActor
extension MobileShellComposite {
    /// Parks a composer send while connection recovery has retired the dead
    /// client and is dialing its replacement, until a client is installed,
    /// recovery stops (success, failure, or cancellation), or the
    /// reconnect-attempt deadline elapses. A send with no recovery in flight
    /// (signed out, Mac forgotten, plain disconnect) returns at once, as does
    /// one for a locally served or external-host terminal.
    ///
    /// - Returns: `false` when the send must fail because it waited and the
    ///   wait ended without a client, after a sign-out or account switch, or
    ///   with a client for a different Mac than the one being redialed. The
    ///   text was composed for a terminal on that Mac, and another Mac can
    ///   report the same terminal id.
    func awaitRemoteClientDuringConnectionRecovery(
        terminalID: MobileTerminalPreview.ID
    ) async -> Bool {
        guard composerSendWaitsForRecovery(terminalID: terminalID) else { return true }
        let waitSignInGeneration = signInGeneration
        let waitMacKey = foregroundOrRecoveryMacKey
        let nanoseconds = runtime?.reconnectAttemptDeadlineNanoseconds
            ?? 30_000_000_000
        let deadline = ContinuousClock.now + .nanoseconds(Int64(clamping: nanoseconds))
        let timeout = Task { @MainActor [weak self] in
            guard (try? await Task.sleep(until: deadline, clock: .continuous)) != nil else { return }
            self?.resumeComposerSendClientWaiters()
        }
        defer { timeout.cancel() }
        while composerSendWaitsForRecovery(terminalID: terminalID),
              ContinuousClock.now < deadline {
            await withCheckedContinuation { continuation in
                composerSendClientWaiters.append(continuation)
            }
        }
        return remoteClient != nil
            && signInGeneration == waitSignInGeneration
            && foregroundMacKey == waitMacKey
    }

    private func composerSendWaitsForRecovery(
        terminalID: MobileTerminalPreview.ID
    ) -> Bool {
        remoteClient == nil
            && isRecoveringConnection
            && !locallyServedOwnsSurface(terminalID.rawValue)
            && !externalHostOwnsSurface(terminalID.rawValue)
    }

    func resumeComposerSendClientWaiters() {
        let waiters = composerSendClientWaiters
        composerSendClientWaiters = []
        for waiter in waiters {
            waiter.resume()
        }
    }
}
