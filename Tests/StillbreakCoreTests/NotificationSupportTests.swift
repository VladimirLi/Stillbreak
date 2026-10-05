import Foundation
import Testing
@testable import StillbreakCore

private let start = Date(timeIntervalSince1970: 1_700_000_000)

@Test func deliveryStepFollowsAuthorization() {
    #expect(NotificationDeliveryPolicy.step(for: .authorized) == .deliver)
    #expect(NotificationDeliveryPolicy.step(for: .provisional) == .deliver)
    #expect(NotificationDeliveryPolicy.step(for: .ephemeral) == .deliver)
    #expect(NotificationDeliveryPolicy.step(for: .notDetermined) == .requestAuthorization)
    #expect(NotificationDeliveryPolicy.step(for: .denied) == .fallback(.denied))
    #expect(NotificationDeliveryPolicy.step(for: .unavailable) == .fallback(.unavailable))
}

@Test func authorizationAnswerEitherDeliversOrFallsBack() {
    #expect(NotificationDeliveryPolicy.stepAfterAuthorizationRequest(granted: true, failed: false) == .deliver)
    #expect(
        NotificationDeliveryPolicy.stepAfterAuthorizationRequest(granted: false, failed: false)
            == .fallback(.authorizationDeclined)
    )
    #expect(
        NotificationDeliveryPolicy.stepAfterAuthorizationRequest(granted: false, failed: true)
            == .fallback(.authorizationFailed)
    )
}

@Test func failedDeliveryRetriesBoundedTimesThenFallsBack() {
    #expect(NotificationDeliveryPolicy.decisionAfterDeliveryFailure(attempt: 1) == .retry(after: 5))
    #expect(NotificationDeliveryPolicy.decisionAfterDeliveryFailure(attempt: 2) == .retry(after: 15))
    #expect(NotificationDeliveryPolicy.decisionAfterDeliveryFailure(attempt: 3) == .fallback(.deliveryFailed))
    #expect(NotificationDeliveryPolicy.decisionAfterDeliveryFailure(attempt: 99) == .fallback(.deliveryFailed))
    #expect(NotificationDeliveryPolicy.decisionAfterDeliveryFailure(attempt: 0) == .fallback(.deliveryFailed))
}

@Test func onlyGrantedStatesCanDeliver() {
    let deliverable: Set<NotificationAuthorization> = [.authorized, .provisional, .ephemeral]
    for state in [NotificationAuthorization.notDetermined, .denied, .authorized, .provisional, .ephemeral, .unavailable] {
        #expect(state.canDeliver == deliverable.contains(state))
    }
}

@Test func statusPresentationExplainsEachBlockedState() throws {
    let denied = NotificationStatusPresentation.make(
        authorization: .denied, notificationsEnabled: true, lastDeliveryFailed: false
    )
    #expect(denied.action == .openSystemSettings)
    #expect(denied.actionTitle == "Open Notification Settings")
    #expect(try #require(denied.message).contains("System Settings"))

    let undecided = NotificationStatusPresentation.make(
        authorization: .notDetermined, notificationsEnabled: true, lastDeliveryFailed: false
    )
    #expect(undecided.action == .requestPermission)
    #expect(undecided.actionTitle == "Allow Notifications")

    let unavailable = NotificationStatusPresentation.make(
        authorization: .unavailable, notificationsEnabled: true, lastDeliveryFailed: false
    )
    #expect(unavailable.action == .none)
    #expect(unavailable.message != nil)
    #expect(unavailable.actionTitle == nil)

    let failed = NotificationStatusPresentation.make(
        authorization: .authorized, notificationsEnabled: true, lastDeliveryFailed: true
    )
    #expect(failed.action == .openSystemSettings)
    #expect(failed.message != nil)
}

@Test func statusPresentationIsSilentWhenHealthyOrDisabled() {
    let healthy = NotificationStatusPresentation.make(
        authorization: .authorized, notificationsEnabled: true, lastDeliveryFailed: false
    )
    #expect(healthy.message == nil)
    #expect(healthy.action == .none)

    for state in [NotificationAuthorization.denied, .notDetermined, .unavailable, .authorized] {
        let disabled = NotificationStatusPresentation.make(
            authorization: state, notificationsEnabled: false, lastDeliveryFailed: true
        )
        #expect(disabled.message == nil)
        #expect(disabled.action == .none)
    }
}

@Test func notificationDiagnosticsCoverThresholdAuthorizationAndDelivery() throws {
    let threshold = NotificationDiagnosticBuilder.thresholdReached(
        threshold: 1_500,
        provisional: 1_500.4,
        notificationsEnabled: true,
        soundEnabled: false,
        effects: [.notify(sound: false)]
    )
    #expect(threshold.category == .notification)
    #expect(threshold.event == "threshold-reached")
    #expect(threshold.effectKinds == ["notification"])
    #expect(threshold.threshold == 1_500)

    let status = NotificationDiagnosticBuilder.authorizationStatus(.denied, context: "threshold")
    #expect(status.event == "authorization-status")
    #expect(status.outcome == "denied")
    #expect(status.reason == "threshold")

    #expect(NotificationDiagnosticBuilder.authorizationRequest(granted: true, failure: nil).outcome == "granted")
    #expect(NotificationDiagnosticBuilder.authorizationRequest(granted: false, failure: nil).outcome == "declined")
    let failedRequest = NotificationDiagnosticBuilder.authorizationRequest(
        granted: false,
        failure: NotificationDiagnosticBuilder.failureType(domain: "UNErrorDomain", code: 1)
    )
    #expect(failedRequest.outcome == "failure")
    #expect(failedRequest.failureType == "UNErrorDomain#1")

    let added = NotificationDiagnosticBuilder.add(attempt: 2, failure: nil)
    #expect(added.outcome == "success")
    #expect(added.reason == "attempt-2")
    let failedAdd = NotificationDiagnosticBuilder.add(attempt: 1, failure: "UNErrorDomain#1")
    #expect(failedAdd.outcome == "failure")
    #expect(NotificationDiagnosticBuilder.level(for: failedAdd) == .error)
    #expect(NotificationDiagnosticBuilder.level(for: added) == .info)

    let fallback = NotificationDiagnosticBuilder.fallback(reason: .denied, soundPlayed: true)
    #expect(fallback.reason == "denied")
    #expect(fallback.effectKinds == ["sound"])
    #expect(NotificationDiagnosticBuilder.level(for: fallback) == .error)

    let fields = try #require(
        JSONSerialization.jsonObject(with: JSONEncoder.stillbreak.encode(fallback)) as? [String: Any]
    )
    #expect(Set(fields.keys) == ["category", "event", "reason", "effectKinds", "outcome"])
    #expect(fields["category"] as? String == "notification")
}

@Test func overtimeKeepsAccruingAndCountsUpAfterThreshold() throws {
    let settings = BreakSettings(workThreshold: 10, deadTime: 300)
    var reducer = TimerReducer()
    reducer.activity(at: start, settings: settings)
    #expect(reducer.sample(at: start.addingTimeInterval(10)) == [.notify(sound: true)])

    reducer.activity(at: start.addingTimeInterval(40), settings: settings)
    let interval = try #require(reducer.state.interval)
    #expect(interval.overtime == 30)
    #expect(interval.validatedActive == 40)
    #expect(reducer.remaining(at: start.addingTimeInterval(45), defaultSettings: settings) == -35)
    #expect(CountdownFormatter.string(seconds: -35) == "-00:35")
    #expect(reducer.activity(at: start.addingTimeInterval(41), settings: settings) == [])
}

@Test func thresholdNotificationIsNotRepeatedAfterStateRoundTrip() throws {
    let settings = BreakSettings(workThreshold: 10, deadTime: 300)
    var reducer = TimerReducer()
    reducer.activity(at: start, settings: settings)
    #expect(reducer.sample(at: start.addingTimeInterval(10)) == [.notify(sound: true)])

    let data = try JSONEncoder.stillbreak.encode(reducer.state)
    let restored = try JSONDecoder.stillbreak.decode(TimerState.self, from: data)
    var relaunched = TimerReducer(state: restored)
    #expect(relaunched.sample(at: start.addingTimeInterval(30)) == [])
    #expect(relaunched.activity(at: start.addingTimeInterval(31), settings: settings) == [])
}
