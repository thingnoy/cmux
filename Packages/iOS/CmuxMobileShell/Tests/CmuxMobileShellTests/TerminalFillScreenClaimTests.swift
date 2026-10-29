import CMUXMobileCore
import CmuxMobileRPC
import CmuxMobileShellModel
import CmuxTerminalSizing
import Foundation
import Testing
@testable import CmuxMobileShell

// A phone sharing a terminal with the same user's Mac under the default
// fit-everyone policy gets min(Mac, phone) and letterboxes. With the
// fill-screen preference on, the phone counts itself and puts itself first in
// a priority policy, once, so it fills while it shows the terminal. Follow
// latest is not enough: any Mac input resizes the grid under the phone.

private let surfaceID = "live-terminal"
private let phoneID = "mobile:phone"
private let phoneViewport = (cols: 72, rows: 60)
private let phonePriorityKey = "u_maya/iphone/phone-device"

/// A connected phone with the terminal mounted at `phoneViewport`. The
/// collector keeps the surface mounted; dropping it clears the reported
/// viewport the counts report needs.
@MainActor
private func makeStore(
    router: LivenessHostRouter,
    fillScreen: Bool? = nil
) async throws -> (MobileShellComposite, OutputCollector) {
    let store = try await makeConnectedStore(router: router, box: TransportBox(), clock: TestClock())
    let defaults = try #require(UserDefaults(suiteName: "fill-screen-\(UUID().uuidString)"))
    if let fillScreen {
        defaults.set(fillScreen, forKey: MobileTerminalFillScreenPreference.defaultsKey)
    }
    store.terminalFillScreenDefaults = defaults
    await router.enqueueReplayTexts(["cold-replay", "initial-viewport-replay"])
    let output = OutputCollector()
    output.mount(store: store, surfaceID: surfaceID)
    #expect(try await pollUntil { output.lines.count == 1 }, "cold replay")
    _ = await store.updateTerminalViewport(
        surfaceID: surfaceID,
        columns: phoneViewport.cols,
        rows: phoneViewport.rows
    )
    #expect(try await pollUntil { output.lines.count == 2 }, "viewport replay")
    return (store, output)
}

@MainActor
private func sizeStateEnvelope(
    grid: (cols: Int, rows: Int) = (72, 44),
    policy: TerminalSizingPolicy = .fitEveryone,
    phoneCountsOverride: Bool? = nil
) throws -> MobileEventEnvelope {
    let policyObject = try JSONSerialization.jsonObject(with: JSONEncoder().encode(policy))
    let payload: [String: Any] = [
        "surface_id": surfaceID,
        "self_participant_id": phoneID,
        "state": [
            "generation": 7, "cols": grid.cols, "rows": grid.rows,
            "reason": policy.mode.rawValue,
            "owners": [phoneID, "c3"],
            "policy": policyObject,
            "participants": [
                ["id": "c3", "user_id": "u_maya", "device_kind": "mac", "device_name": "Mac Studio",
                 "viewport": ["cols": 120, "rows": 44], "counts": true],
                ["id": phoneID, "user_id": "u_maya", "device_kind": "iphone", "device_name": "iPhone",
                 "device_id": "phone-device",
                 "viewport": ["cols": phoneViewport.cols, "rows": phoneViewport.rows], "counts": true,
                 "counts_override": phoneCountsOverride.map { $0 as Any } ?? NSNull()],
            ],
        ] as [String: Any],
    ]
    return MobileEventEnvelope(
        topic: MobileShellComposite.terminalSizeStateTopic,
        payloadJSON: try JSONSerialization.data(withJSONObject: payload),
        streamID: nil
    )
}

private func countsOverrideReports(_ router: LivenessHostRouter) async -> [Bool] {
    await router.requests(for: "mobile.terminal.viewport").compactMap(\.countsOverride)
}

/// Waits briefly for a claim that must not happen.
private func claimed(_ router: LivenessHostRouter, atLeast count: Int = 1) async -> Bool {
    await router.waitForCount(
        of: "mobile.terminal.size_policy.set",
        atLeast: count,
        timeoutNanoseconds: 300_000_000,
        recordIssueOnTimeout: false
    )
}

@MainActor
@Suite struct TerminalFillScreenClaimTests {
    @Test func letterboxedPhoneClaimsPriorityAndCountsOnce() async throws {
        let router = LivenessHostRouter()
        let (store, output) = try await makeStore(router: router)

        store.handleTerminalSizeStateEvent(try sizeStateEnvelope())

        #expect(await router.waitForCount(of: "mobile.terminal.size_policy.set", atLeast: 1))
        let claims = await router.requests(for: "mobile.terminal.size_policy.set")
        #expect(claims.map(\.policyMode) == ["priority"])
        #expect(claims.map(\.policyPriority) == [[phonePriorityKey]])
        let overrideSent = try await pollUntil { await countsOverrideReports(router) == [true] }
        #expect(overrideSent, "the phone must count itself toward size")

        store.handleTerminalSizeStateEvent(try sizeStateEnvelope())
        #expect(!(await claimed(router, atLeast: 2)), "a repeated push must not claim again")
        #expect(await countsOverrideReports(router) == [true])
        output.unmount()
    }

    @Test func disabledPreferenceNeverClaims() async throws {
        let router = LivenessHostRouter()
        let (store, output) = try await makeStore(router: router, fillScreen: false)

        store.handleTerminalSizeStateEvent(try sizeStateEnvelope())

        #expect(!(await claimed(router)))
        #expect(await countsOverrideReports(router).isEmpty)
        output.unmount()
    }

    @Test func followLatestClaimFromBuildSevenMovesToPriority() async throws {
        let router = LivenessHostRouter()
        let (store, output) = try await makeStore(router: router)

        store.handleTerminalSizeStateEvent(
            try sizeStateEnvelope(grid: phoneViewport, policy: .latest, phoneCountsOverride: true)
        )

        #expect(await router.waitForCount(of: "mobile.terminal.size_policy.set", atLeast: 1))
        let claims = await router.requests(for: "mobile.terminal.size_policy.set")
        #expect(claims.map(\.policyMode) == ["priority"])
        #expect(claims.map(\.policyPriority) == [[phonePriorityKey]])
        output.unmount()
    }

    @Test(arguments: [
        TerminalSizingPolicy.latest,
        TerminalSizingPolicy(mode: .priority, priority: ["u_maya/mac"]),
        TerminalSizingPolicy(mode: .priority, priority: [phonePriorityKey]),
        TerminalSizingPolicy(mode: .smallest, priority: ["u_maya/mac"]),
    ])
    func userChosenPolicyIsLeftAlone(policy: TerminalSizingPolicy) async throws {
        let router = LivenessHostRouter()
        let (store, output) = try await makeStore(router: router)

        store.handleTerminalSizeStateEvent(try sizeStateEnvelope(policy: policy))

        #expect(!(await claimed(router)))
        #expect(await countsOverrideReports(router).isEmpty)
        output.unmount()
    }

    @Test(arguments: [true, false])
    func userChosenCountsOverrideIsLeftAlone(countsOverride: Bool) async throws {
        let router = LivenessHostRouter()
        let (store, output) = try await makeStore(router: router)

        store.handleTerminalSizeStateEvent(try sizeStateEnvelope(phoneCountsOverride: countsOverride))

        #expect(!(await claimed(router)))
        #expect(await countsOverrideReports(router).isEmpty)
        output.unmount()
    }

    @Test func phoneThatAlreadyFillsNeverClaims() async throws {
        let router = LivenessHostRouter()
        let (store, output) = try await makeStore(router: router)

        store.handleTerminalSizeStateEvent(try sizeStateEnvelope(grid: phoneViewport))

        #expect(!(await claimed(router)))
        #expect(await countsOverrideReports(router).isEmpty)
        output.unmount()
    }
}
