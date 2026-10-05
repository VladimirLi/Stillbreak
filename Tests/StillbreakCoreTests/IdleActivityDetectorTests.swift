import Foundation
import Testing
@testable import StillbreakCore

@Test func appHIDGraceMatchesPollingCadence() {
    #expect(PermissionlessHIDPolicy.pollInterval == 1)
    #expect(PermissionlessHIDPolicy.conservativeGrace == PermissionlessHIDPolicy.pollInterval)

    let start = Date(timeIntervalSince1970: 1_700_000_000)
    var detector = IdleActivityDetector()
    var reducer = TimerReducer()
    let settings = BreakSettings(workThreshold: 1_000, deadTime: 300)

    _ = PermissionlessHIDPolicy.processSample(
        now: start,
        idleSeconds: 0,
        detector: &detector,
        reducer: &reducer,
        settings: settings
    )
    _ = PermissionlessHIDPolicy.processSample(
        now: start.addingTimeInterval(300.1),
        idleSeconds: 0.05,
        detector: &detector,
        reducer: &reducer,
        settings: settings
    )

    #expect(reducer.state.mode == .active)
    #expect(abs(reducer.state.interval!.validatedActive - 300.05) < 0.001)
}

@Test func repeatedIdleSamplesFromOneEventEmitActivityOnce() {
    let start = Date(timeIntervalSince1970: 1_700_000_000)
    var detector = IdleActivityDetector()

    #expect(detector.activityDate(now: start, idleSeconds: 0.2) == start.addingTimeInterval(-0.2))
    #expect(detector.activityDate(now: start.addingTimeInterval(1), idleSeconds: 1.2) == nil)
    #expect(detector.activityDate(now: start.addingTimeInterval(2), idleSeconds: 2.2) == nil)
}

@Test func realActivityFiftyMillisecondsLaterIsEmitted() {
    let start = Date(timeIntervalSince1970: 1_700_000_000)
    var detector = IdleActivityDetector()

    #expect(detector.activityDate(now: start, idleSeconds: 0) == start)
    #expect(detector.activityDate(
        now: start.addingTimeInterval(1),
        idleSeconds: 0.95
    ) == start.addingTimeInterval(0.05))
}

@Test func realActivityFiveMillisecondsLaterIsEmitted() {
    let start = Date(timeIntervalSince1970: 1_700_000_000)
    var detector = IdleActivityDetector()

    #expect(detector.activityDate(now: start, idleSeconds: 0) == start)
    #expect(detector.activityDate(
        now: start.addingTimeInterval(1),
        idleSeconds: 0.995
    ) == start.addingTimeInterval(0.005))
}

@Test func realActivityExactlyTenMillisecondsLaterIsEmitted() {
    let start = Date(timeIntervalSince1970: 1_700_000_000)
    var detector = IdleActivityDetector()

    #expect(detector.activityDate(now: start, idleSeconds: 0) == start)
    #expect(detector.activityDate(
        now: start.addingTimeInterval(1),
        idleSeconds: 0.99
    ) == start.addingTimeInterval(0.01))
}

@Test func reconstructionJitterDoesNotDuplicateAnEvent() {
    let start = Date(timeIntervalSince1970: 1_700_000_000)
    var detector = IdleActivityDetector()

    #expect(detector.activityDate(now: start, idleSeconds: 0) == start)
    #expect(detector.activityDate(
        now: start.addingTimeInterval(1),
        idleSeconds: 1
    ) == nil)
}

@Test func reconstructionJitterDoesNotAccumulateIntoFalseActivity() {
    let start = Date(timeIntervalSince1970: 1_700_000_000)
    var detector = IdleActivityDetector()

    #expect(detector.activityDate(
        now: start.addingTimeInterval(120),
        idleSeconds: 120
    ) == nil)
    for sample in 1...10 {
        let now = start.addingTimeInterval(120 + Double(sample))
        let staleEvent = start.addingTimeInterval(Double(sample) * 0.005)
        #expect(detector.activityDate(
            now: now,
            idleSeconds: now.timeIntervalSince(staleEvent)
        ) == nil)
    }
}

@Test func staleIdleJitterCannotRestartAndRecloseAfterDeadTime() {
    let start = Date(timeIntervalSince1970: 1_700_000_000)
    let settings = BreakSettings(workThreshold: 600, deadTime: 120)
    var detector = IdleActivityDetector()
    var reducer = TimerReducer()
    var data = PersistedData(settings: settings)

    func process(now: Date, idleSeconds: TimeInterval) -> HIDSampleResult {
        PermissionlessHIDPolicy.processSample(
            now: now,
            idleSeconds: idleSeconds,
            detector: &detector,
            reducer: &reducer,
            settings: settings
        )
    }

    _ = process(now: start, idleSeconds: 0)
    _ = process(now: start.addingTimeInterval(10), idleSeconds: 0)
    let closure = process(now: start.addingTimeInterval(130), idleSeconds: 120)
    data = TimerEffectProcessor.apply(closure.effects, state: reducer.state, to: data).data

    #expect(data.history.count == 1)
    #expect(reducer.state.mode == .idle)

    for sample in 1...20 {
        let now = start.addingTimeInterval(130 + Double(sample))
        let staleEvent = start.addingTimeInterval(10 + Double(sample) * 0.005)
        let result = process(now: now, idleSeconds: now.timeIntervalSince(staleEvent))
        data = TimerEffectProcessor.apply(result.effects, state: reducer.state, to: data).data
        #expect(result.effects.isEmpty)
        #expect(reducer.state.mode == .idle)
    }

    #expect(data.history.count == 1)

    let realActivity = process(now: start.addingTimeInterval(200), idleSeconds: 0.2)
    #expect(realActivity.effects.isEmpty)
    #expect(reducer.state.mode == .active)
    #expect(reducer.state.interval?.startedAt == start.addingTimeInterval(199.8))
}

@Test func fiftyMillisecondEventPreventsPrematureDeadTimeClosure() {
    let start = Date(timeIntervalSince1970: 1_700_000_000)
    var detector = IdleActivityDetector()
    var reducer = TimerReducer()
    let settings = BreakSettings(workThreshold: 600, deadTime: 300)

    reducer.activity(
        at: detector.activityDate(now: start, idleSeconds: 0)!,
        settings: settings
    )
    reducer.activity(
        at: detector.activityDate(
            now: start.addingTimeInterval(1),
            idleSeconds: 0.95
        )!,
        settings: settings
    )

    let boundaryPoll = start.addingTimeInterval(300.02)
    #expect(detector.activityDate(
        now: boundaryPoll,
        idleSeconds: 299.97
    ) == nil)
    #expect(reducer.sample(at: boundaryPoll).isEmpty)
    #expect(reducer.state.mode == .active)
    #expect(abs(reducer.state.interval!.validatedActive - 0.05) < 0.001)
}

@Test func latePollUsesActualEventTimeBeforeDeadTimeBoundary() {
    let start = Date(timeIntervalSince1970: 1_700_000_000)
    var detector = IdleActivityDetector()
    var reducer = TimerReducer()
    let settings = BreakSettings(workThreshold: 600, deadTime: 300)

    let initialEvent = detector.activityDate(now: start, idleSeconds: 0)
    reducer.activity(at: initialEvent!, settings: settings)

    let pollAt = start.addingTimeInterval(300.2)
    let eventAt = detector.activityDate(now: pollAt, idleSeconds: 0.3)
    #expect(abs(eventAt!.timeIntervalSince(start) - 299.9) < 0.001)
    reducer.activity(at: eventAt!, settings: settings)
    reducer.sample(at: pollAt)

    #expect(reducer.state.mode == .active)
    #expect(abs(reducer.state.interval!.validatedActive - 299.9) < 0.001)
}

@Test func resumeBaselineSuppressesResumeClickButAllowsLaterActivity() {
    let start = Date(timeIntervalSince1970: 1_700_000_000)
    var detector = IdleActivityDetector()
    var reducer = TimerReducer(state: TimerState(mode: .paused))
    let settings = BreakSettings()

    reducer.resume()
    detector.baseline(at: start)
    let resumeClick = detector.activityDate(
        now: start.addingTimeInterval(1),
        idleSeconds: 1
    )
    #expect(resumeClick == nil)
    #expect(reducer.state.mode == .idle)

    let laterActivity = detector.activityDate(
        now: start.addingTimeInterval(2),
        idleSeconds: 0.25
    )
    #expect(laterActivity == start.addingTimeInterval(1.75))
    reducer.activity(at: laterActivity!, settings: settings)
    #expect(reducer.state.mode == .active)
}

@Test func launchAtLoginPolicyHandlesEveryKnownStatus() {
    #expect(LaunchAtLoginPolicy.action(enabled: true, status: .notRegistered) == .register)
    #expect(LaunchAtLoginPolicy.action(enabled: true, status: .enabled) == .none)
    #expect(LaunchAtLoginPolicy.action(enabled: true, status: .requiresApproval) == .none)
    #expect(LaunchAtLoginPolicy.action(enabled: true, status: .notFound) == .none)
    #expect(LaunchAtLoginPolicy.action(enabled: false, status: .notRegistered) == .none)
    #expect(LaunchAtLoginPolicy.action(enabled: false, status: .enabled) == .unregister)
    #expect(LaunchAtLoginPolicy.action(enabled: false, status: .requiresApproval) == .unregister)
    #expect(LaunchAtLoginPolicy.action(enabled: false, status: .notFound) == .none)
    #expect(LaunchAtLoginPolicy.errorMessage(enabled: true, status: .requiresApproval)
        == "Open System Settings to approve Stillbreak as a login item.")
    #expect(LaunchAtLoginPolicy.errorMessage(enabled: true, status: .notFound)
        == "Stillbreak could not be found by macOS Login Items.")
    #expect(LaunchAtLoginPolicy.errorMessage(enabled: false, status: .notFound)
        == "Stillbreak could not be found by macOS Login Items.")
}

@Test func quitClickAtDeadTimeBoundaryIsPersistedAsActivity() throws {
    let start = Date(timeIntervalSince1970: 1_700_000_000)
    var detector = IdleActivityDetector()
    var reducer = TimerReducer()
    let settings = BreakSettings(workThreshold: 1_000, deadTime: 300)

    reducer.activity(
        at: detector.activityDate(now: start, idleSeconds: 0)!,
        settings: settings
    )
    let quitAt = start.addingTimeInterval(299)
    reducer.activity(
        at: detector.activityDate(now: quitAt, idleSeconds: 0)!,
        settings: settings
    )
    reducer.sample(at: quitAt)

    let persisted = PersistedData(
        settings: settings,
        timer: reducer.state,
        savedAt: quitAt,
        savedSystemUptime: 1_000
    )
    let decoded = try JSONDecoder.stillbreak.decode(
        PersistedData.self,
        from: JSONEncoder.stillbreak.encode(persisted)
    )
    var restored = TimerReducer(state: decoded.timer)

    #expect(restored.restore(
        savedAt: decoded.savedAt,
        savedSystemUptime: decoded.savedSystemUptime,
        now: start.addingTimeInterval(301),
        systemUptime: 1_002
    ).isEmpty)
    #expect(restored.state.mode == .active)
    #expect(restored.state.interval?.validatedActive == 299)

    restored.activity(at: start.addingTimeInterval(302), settings: settings)
    #expect(restored.state.interval?.validatedActive == 300)
}

@Test func stateFileOverrideDoesNotUseApplicationSupport() {
    let support = URL(fileURLWithPath: "/Users/example/Library/Application Support")
    let override = "/tmp/stillbreak-test/state.json"
    #expect(StateFileLocator.url(
        environment: ["STILLBREAK_STATE_FILE": override],
        applicationSupport: support
    ).path == override)
    #expect(StateFileLocator.url(
        environment: [:],
        applicationSupport: support
    ).path == "/Users/example/Library/Application Support/Stillbreak/state.json")
}
