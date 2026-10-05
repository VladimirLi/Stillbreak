import Foundation
import Testing
@testable import StillbreakCore

@MainActor
private final class Harness {
    var events: [String] = []
    var authorization: NotificationAuthorization = .authorized
    var addResults: [Bool]
    var requestResult: (granted: Bool, failed: Bool) = (true, false)
    var current = true
    var endCurrentOn: String?

    init(addResults: [Bool]) { self.addResults = addResults }

    func record(_ event: String) {
        events.append(event)
        if event == endCurrentOn { current = false }
    }

    var runner: NotificationDeliveryRunner {
        NotificationDeliveryRunner(
            refresh: { [self] context in record("refresh:\(context)"); return authorization },
            requestAuthorization: { [self] in record("request"); return requestResult },
            deliver: { [self] sound, attempt in
                record("add#\(attempt) sound=\(sound)")
                return addResults.isEmpty ? false : addResults.removeFirst()
            },
            sleep: { [self] seconds in record("sleep:\(Int(seconds))") },
            isCurrent: { [self] in current },
            cue: { [self] reason, play in record("cue:\(reason.rawValue) sound=\(play)") },
            cancelled: { [self] stage in record("cancelled:\(stage)") }
        )
    }
}

@MainActor
@Test func firstFailedAddCuesBeforeAnyRetryDelay() async {
    let h = Harness(addResults: [false, false, false])
    let outcome = await h.runner.run(sound: true)
    #expect(outcome == .cued(.deliveryFailed))
    #expect(h.events == [
        "refresh:threshold",
        "add#1 sound=true",
        "cue:delivery-failed sound=true",
        "sleep:5",
        "refresh:retry",
        "add#2 sound=false",
        "sleep:15",
        "refresh:retry",
        "add#3 sound=false",
        "cue:delivery-failed sound=false",
    ])
}

@MainActor
@Test func retrySuccessAfterCueDeliversWithoutRepeatingSound() async {
    let h = Harness(addResults: [false, true])
    let outcome = await h.runner.run(sound: true)
    #expect(outcome == .delivered)
    #expect(h.events == [
        "refresh:threshold",
        "add#1 sound=true",
        "cue:delivery-failed sound=true",
        "sleep:5",
        "refresh:retry",
        "add#2 sound=false",
    ])
}

@MainActor
@Test func successfulFirstAddNeverCues() async {
    let h = Harness(addResults: [true])
    #expect(await h.runner.run(sound: true) == .delivered)
    #expect(h.events == ["refresh:threshold", "add#1 sound=true"])
}

@MainActor
@Test func soundOffFailureCuesSilently() async {
    let h = Harness(addResults: [false, true])
    await h.runner.run(sound: false)
    #expect(h.events.contains("cue:delivery-failed sound=false"))
    #expect(!h.events.contains { $0.hasSuffix("sound=true") })
}

@MainActor
@Test func closingTheIntervalDuringRetryDelayStopsFurtherAttempts() async {
    let h = Harness(addResults: [false, true])
    h.endCurrentOn = "sleep:5"
    let outcome = await h.runner.run(sound: true)
    #expect(outcome == .cancelled(stage: "before-retry"))
    #expect(h.events == [
        "refresh:threshold",
        "add#1 sound=true",
        "cue:delivery-failed sound=true",
        "sleep:5",
        "cancelled:before-retry",
    ])
}

@MainActor
@Test func pauseDuringTheFirstAddSuppressesTheCue() async {
    let h = Harness(addResults: [false])
    h.endCurrentOn = "add#1 sound=true"
    let outcome = await h.runner.run(sound: true)
    #expect(outcome == .cancelled(stage: "after-failure"))
    #expect(h.events == ["refresh:threshold", "add#1 sound=true", "cancelled:after-failure"])
}

@MainActor
@Test func intervalClosedBeforeFirstAddSendsNothing() async {
    let h = Harness(addResults: [true])
    h.endCurrentOn = "refresh:threshold"
    #expect(await h.runner.run(sound: true) == .cancelled(stage: "before-add"))
    #expect(h.events == ["refresh:threshold", "cancelled:before-add"])
}

@MainActor
@Test func lateAnswerToPermissionPromptAfterIntervalClosedDoesNotDeliver() async {
    let h = Harness(addResults: [true])
    h.authorization = .notDetermined
    h.endCurrentOn = "request"
    let outcome = await h.runner.run(sound: true)
    #expect(h.events == [
        "refresh:threshold",
        "cue:awaiting-permission sound=true",
        "request",
        "cancelled:before-add",
    ])
    #expect(outcome == .cancelled(stage: "before-add"))
}

@MainActor
@Test func grantedPermissionDeliversWithoutRepeatingTheCueSound() async {
    let h = Harness(addResults: [true])
    h.authorization = .notDetermined
    #expect(await h.runner.run(sound: true) == .delivered)
    #expect(h.events == [
        "refresh:threshold",
        "cue:awaiting-permission sound=true",
        "request",
        "add#1 sound=false",
    ])
}

@MainActor
@Test func declinedPermissionFallsBackWithoutASecondSound() async {
    let h = Harness(addResults: [])
    h.authorization = .notDetermined
    h.requestResult = (false, false)
    #expect(await h.runner.run(sound: true) == .cued(.authorizationDeclined))
    #expect(h.events.last == "cue:authorization-declined sound=false")
}

@MainActor
@Test func deniedCuesOnceImmediately() async {
    let h = Harness(addResults: [])
    h.authorization = .denied
    #expect(await h.runner.run(sound: true) == .cued(.denied))
    #expect(h.events == ["refresh:threshold", "cue:denied sound=true"])
}

@MainActor
@Test func alertsDisabledStatusExplainsMissingBannerWithoutHidingFailures() throws {
    let off = NotificationStatusPresentation.make(
        authorization: .authorized, notificationsEnabled: true,
        lastDeliveryFailed: false, alertsDisabled: true
    )
    #expect(off.action == .openSystemSettings)
    #expect(try #require(off.message).contains("no banner"))

    let failed = NotificationStatusPresentation.make(
        authorization: .authorized, notificationsEnabled: true,
        lastDeliveryFailed: true, alertsDisabled: true
    )
    #expect(try #require(failed.message).contains("could not be delivered"))

    let normal = NotificationStatusPresentation.make(
        authorization: .authorized, notificationsEnabled: true,
        lastDeliveryFailed: false, alertsDisabled: false
    )
    #expect(normal.message == nil)

    let disabledSetting = NotificationStatusPresentation.make(
        authorization: .authorized, notificationsEnabled: false,
        lastDeliveryFailed: false, alertsDisabled: true
    )
    #expect(disabledSetting.message == nil)
}
