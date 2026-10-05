import Foundation

public enum NotificationAuthorization: String, Equatable, Sendable {
    case notDetermined
    case denied
    case authorized
    case provisional
    case ephemeral
    case unavailable

    public var canDeliver: Bool {
        switch self {
        case .authorized, .provisional, .ephemeral:
            return true
        case .notDetermined, .denied, .unavailable:
            return false
        }
    }
}

public enum NotificationFallbackReason: String, Equatable, Sendable {
    case denied
    case unavailable
    case awaitingPermission = "awaiting-permission"
    case authorizationDeclined = "authorization-declined"
    case authorizationFailed = "authorization-failed"
    case deliveryFailed = "delivery-failed"
}

public enum NotificationDeliveryStep: Equatable, Sendable {
    case deliver
    /// The cue must not wait for the answer: the prompt may be missed or still open.
    case requestAuthorization
    case fallback(NotificationFallbackReason)
}

public enum NotificationRetryDecision: Equatable, Sendable {
    case retry(after: TimeInterval)
    case fallback(NotificationFallbackReason)
}

public enum NotificationDeliveryPolicy {
    public static let retryDelays: [TimeInterval] = [5, 15]

    public static func step(for authorization: NotificationAuthorization) -> NotificationDeliveryStep {
        switch authorization {
        case .authorized, .provisional, .ephemeral:
            return .deliver
        case .notDetermined:
            return .requestAuthorization
        case .denied:
            return .fallback(.denied)
        case .unavailable:
            return .fallback(.unavailable)
        }
    }

    public static func stepAfterAuthorizationRequest(
        granted: Bool,
        failed: Bool
    ) -> NotificationDeliveryStep {
        if granted { return .deliver }
        return .fallback(failed ? .authorizationFailed : .authorizationDeclined)
    }

    /// `attempt` is the 1-based number of the delivery attempt that just failed.
    public static func decisionAfterDeliveryFailure(attempt: Int) -> NotificationRetryDecision {
        guard attempt >= 1, attempt <= retryDelays.count else {
            return .fallback(.deliveryFailed)
        }
        return .retry(after: retryDelays[attempt - 1])
    }
}

public enum NotificationStatusAction: Equatable, Sendable {
    case none
    case requestPermission
    case openSystemSettings
}

public struct NotificationStatusPresentation: Equatable, Sendable {
    public var message: String?
    public var action: NotificationStatusAction

    public var actionTitle: String? {
        switch action {
        case .none:
            return nil
        case .requestPermission:
            return "Allow Notifications"
        case .openSystemSettings:
            return "Open Notification Settings"
        }
    }

    public static func make(
        authorization: NotificationAuthorization,
        notificationsEnabled: Bool,
        lastDeliveryFailed: Bool,
        alertsDisabled: Bool = false
    ) -> NotificationStatusPresentation {
        guard notificationsEnabled else {
            return NotificationStatusPresentation(message: nil, action: .none)
        }
        switch authorization {
        case .denied:
            return NotificationStatusPresentation(
                message: "Notifications are turned off for Stillbreak in System Settings, so no banner will appear. The alert sound (if Sound is on) and the menu bar countdown past zero still work.",
                action: .openSystemSettings
            )
        case .notDetermined:
            return NotificationStatusPresentation(
                message: "Stillbreak has not been allowed to send notifications yet. Answer the macOS prompt while you are at the screen: it disappears after about 45 seconds and counts as Don't Allow.",
                action: .requestPermission
            )
        case .unavailable:
            return NotificationStatusPresentation(
                message: "Notifications are unavailable because Stillbreak is not running as an app bundle. The menu bar countdown still runs past zero.",
                action: .none
            )
        case .authorized, .provisional, .ephemeral:
            if lastDeliveryFailed {
                return NotificationStatusPresentation(
                    message: "The last notification could not be delivered. Check Stillbreak in System Settings > Notifications.",
                    action: .openSystemSettings
                )
            }
            if alertsDisabled {
                return NotificationStatusPresentation(
                    message: "Stillbreak is allowed to send notifications, but its alert style is set to None in System Settings, so no banner will pop up. The alert sound (if Sound is on) and the menu bar countdown past zero still work.",
                    action: .openSystemSettings
                )
            }
            return NotificationStatusPresentation(message: nil, action: .none)
        }
    }
}

public enum NotificationDiagnosticBuilder {
    public static func thresholdReached(
        threshold: TimeInterval,
        provisional: TimeInterval,
        notificationsEnabled: Bool,
        soundEnabled: Bool,
        effects: [TimerEffect]
    ) -> DiagnosticEvent {
        DiagnosticEvent(
            category: .notification,
            event: "threshold-reached",
            reason: "notifications=\(notificationsEnabled) sound=\(soundEnabled)",
            threshold: threshold,
            provisional: provisional,
            effectKinds: effects.map(\.diagnosticKind),
            outcome: "reached"
        )
    }

    public static func cancelled(stage: String) -> DiagnosticEvent {
        DiagnosticEvent(
            category: .notification,
            event: "delivery-cancelled",
            reason: stage,
            outcome: "cancelled"
        )
    }

    public static func authorizationStatus(
        _ authorization: NotificationAuthorization,
        context: String,
        alertsDisabled: Bool = false
    ) -> DiagnosticEvent {
        DiagnosticEvent(
            category: .notification,
            event: "authorization-status",
            reason: alertsDisabled ? "\(context) alerts=disabled" : context,
            outcome: authorization.rawValue
        )
    }

    public static func authorizationRequest(
        granted: Bool,
        failure: String?
    ) -> DiagnosticEvent {
        DiagnosticEvent(
            category: .notification,
            event: "authorization-request",
            outcome: failure != nil ? "failure" : granted ? "granted" : "declined",
            failureType: failure
        )
    }

    public static func add(attempt: Int, failure: String?) -> DiagnosticEvent {
        DiagnosticEvent(
            category: .notification,
            event: "add",
            reason: "attempt-\(attempt)",
            outcome: failure == nil ? "success" : "failure",
            failureType: failure
        )
    }

    public static func fallback(
        reason: NotificationFallbackReason,
        soundPlayed: Bool
    ) -> DiagnosticEvent {
        DiagnosticEvent(
            category: .notification,
            event: "fallback",
            reason: reason.rawValue,
            effectKinds: soundPlayed ? ["sound"] : [],
            outcome: "fallback"
        )
    }

    public static func failureType(domain: String, code: Int) -> String {
        "\(domain)#\(code)"
    }

    public static func level(for event: DiagnosticEvent) -> DiagnosticLevel {
        switch event.outcome {
        case "failure", "fallback":
            return .error
        default:
            return .info
        }
    }
}
