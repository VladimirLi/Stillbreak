import Foundation

public enum NotificationDeliveryOutcome: Equatable, Sendable {
    case delivered
    case cued(NotificationFallbackReason)
    case cancelled(stage: String)
}

/// Runs one threshold notification: cues at once when the first add fails, retries in the
/// background, and stops as soon as the interval that triggered it is no longer current.
@MainActor
public struct NotificationDeliveryRunner {
    public var refresh: (_ context: String) async -> NotificationAuthorization
    public var requestAuthorization: () async -> (granted: Bool, failed: Bool)
    public var deliver: (_ sound: Bool, _ attempt: Int) async -> Bool
    public var sleep: (_ seconds: TimeInterval) async -> Void
    public var isCurrent: () -> Bool
    public var cue: (_ reason: NotificationFallbackReason, _ playSound: Bool) -> Void
    public var cancelled: (_ stage: String) -> Void

    public init(
        refresh: @escaping (_ context: String) async -> NotificationAuthorization,
        requestAuthorization: @escaping () async -> (granted: Bool, failed: Bool),
        deliver: @escaping (_ sound: Bool, _ attempt: Int) async -> Bool,
        sleep: @escaping (_ seconds: TimeInterval) async -> Void,
        isCurrent: @escaping () -> Bool,
        cue: @escaping (_ reason: NotificationFallbackReason, _ playSound: Bool) -> Void,
        cancelled: @escaping (_ stage: String) -> Void
    ) {
        self.refresh = refresh
        self.requestAuthorization = requestAuthorization
        self.deliver = deliver
        self.sleep = sleep
        self.isCurrent = isCurrent
        self.cue = cue
        self.cancelled = cancelled
    }

    @discardableResult
    public func run(sound: Bool) async -> NotificationDeliveryOutcome {
        var step = NotificationDeliveryPolicy.step(for: await refresh("threshold"))
        var attempt = 0
        var cued = false

        func cancel(_ stage: String) -> NotificationDeliveryOutcome {
            cancelled(stage)
            return .cancelled(stage: stage)
        }

        while true {
            switch step {
            case .deliver:
                guard isCurrent() else { return cancel("before-add") }
                attempt += 1
                // The cue already made the sound; a late banner must not repeat it.
                if await deliver(sound && !cued, attempt) { return .delivered }
                guard isCurrent() else { return cancel("after-failure") }
                if !cued {
                    cue(.deliveryFailed, sound)
                    cued = true
                }
                switch NotificationDeliveryPolicy.decisionAfterDeliveryFailure(attempt: attempt) {
                case let .retry(after):
                    await sleep(after)
                    guard isCurrent() else { return cancel("before-retry") }
                    step = NotificationDeliveryPolicy.step(for: await refresh("retry"))
                case let .fallback(reason):
                    cue(reason, false)
                    return .cued(reason)
                }
            case .requestAuthorization:
                guard isCurrent() else { return cancel("before-request") }
                cue(.awaitingPermission, sound)
                cued = true
                let result = await requestAuthorization()
                step = NotificationDeliveryPolicy.stepAfterAuthorizationRequest(
                    granted: result.granted,
                    failed: result.failed
                )
            case let .fallback(reason):
                guard isCurrent() else { return cancel("before-cue") }
                cue(reason, sound && !cued)
                return .cued(reason)
            }
        }
    }
}
