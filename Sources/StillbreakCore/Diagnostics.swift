import Foundation

public enum DiagnosticCategory: String, Codable, Sendable {
    case timer
    case lifecycle
    case persistence
    case loginItem
}

public enum DiagnosticLevel: String, Equatable, Sendable {
    case debug
    case info
    case error
}

public struct DiagnosticEvent: Codable, Equatable, Sendable {
    public var category: DiagnosticCategory
    public var event: String
    public var reason: String?
    public var stateBefore: TimerMode?
    public var stateAfter: TimerMode?
    public var idleSeconds: TimeInterval?
    public var inferredEventAt: Date?
    public var threshold: TimeInterval?
    public var deadTime: TimeInterval?
    public var validated: TimeInterval?
    public var provisional: TimeInterval?
    public var overtime: TimeInterval?
    public var effectKinds: [String]?
    public var recordID: UUID?
    public var outcome: String?
    public var failureType: String?

    public init(
        category: DiagnosticCategory,
        event: String,
        reason: String? = nil,
        stateBefore: TimerMode? = nil,
        stateAfter: TimerMode? = nil,
        idleSeconds: TimeInterval? = nil,
        inferredEventAt: Date? = nil,
        threshold: TimeInterval? = nil,
        deadTime: TimeInterval? = nil,
        validated: TimeInterval? = nil,
        provisional: TimeInterval? = nil,
        overtime: TimeInterval? = nil,
        effectKinds: [String]? = nil,
        recordID: UUID? = nil,
        outcome: String? = nil,
        failureType: String? = nil
    ) {
        self.category = category
        self.event = event
        self.reason = reason
        self.stateBefore = stateBefore
        self.stateAfter = stateAfter
        self.idleSeconds = idleSeconds
        self.inferredEventAt = inferredEventAt
        self.threshold = threshold
        self.deadTime = deadTime
        self.validated = validated
        self.provisional = provisional
        self.overtime = overtime
        self.effectKinds = effectKinds
        self.recordID = recordID
        self.outcome = outcome
        self.failureType = failureType
    }

    public var message: String {
        (try? String(data: JSONEncoder.stillbreak.encode(self), encoding: .utf8)) ?? "{}"
    }
}

public extension TimerEffect {
    var diagnosticKind: String {
        switch self {
        case .notify:
            return "notification"
        case .playSound:
            return "sound"
        case .log:
            return "history"
        }
    }
}

public enum TimerDiagnosticBuilder {
    public static func sample(
        _ sample: HIDSampleResult,
        now: Date,
        idleSeconds: TimeInterval,
        defaultSettings: BreakSettings,
        context: String
    ) -> DiagnosticEvent {
        let record = sample.effects.compactMap { effect -> HistoryRecord? in
            if case let .log(record) = effect { return record }
            return nil
        }.first
        let interval = record == nil
            ? sample.stateAfter.interval ?? sample.stateBefore.interval
            : sample.stateBefore.interval
        let decisionAt = sample.inferredEventAt ?? now
        let reason: String
        if record != nil {
            reason = sample.inferredEventAt == nil
                ? "dead-time"
                : "activity-after-dead-time"
        } else {
            reason = context
        }
        return DiagnosticEvent(
            category: .timer,
            event: "sample",
            reason: reason,
            stateBefore: sample.stateBefore.mode,
            stateAfter: sample.stateAfter.mode,
            idleSeconds: idleSeconds,
            inferredEventAt: sample.inferredEventAt,
            threshold: interval?.settings.workThreshold ?? defaultSettings.workThreshold,
            deadTime: interval?.settings.deadTime ?? defaultSettings.deadTime,
            validated: record?.activeDuration ?? interval?.validatedActive ?? 0,
            provisional: interval?.provisionalActive(at: decisionAt) ?? 0,
            overtime: record?.overtimeDuration ?? interval?.overtime ?? 0,
            effectKinds: sample.effects.map(\.diagnosticKind),
            recordID: record?.id,
            outcome: record == nil ? "sampled" : "closed"
        )
    }
}

public enum LifecycleDiagnosticBuilder {
    public static func event(
        _ event: String,
        reason: String? = nil,
        stateBefore: TimerMode? = nil,
        stateAfter: TimerMode? = nil,
        effects: [TimerEffect] = [],
        persistence: PersistenceResult
    ) -> DiagnosticEvent {
        DiagnosticEvent(
            category: .lifecycle,
            event: event,
            reason: reason,
            stateBefore: stateBefore,
            stateAfter: stateAfter,
            effectKinds: effects.map(\.diagnosticKind),
            recordID: effects.compactMap { effect in
                if case let .log(record) = effect { return record.id }
                return nil
            }.first,
            outcome: persistence.outcome,
            failureType: persistence.failureType
        )
    }
}

public enum LifecycleDiagnosticReason {
    public static func wake(stateBefore: TimerMode, effects: [TimerEffect]) -> String {
        if effects.contains(where: {
            if case .log = $0 { return true }
            return false
        }) {
            return "wake-closes-active"
        }
        return stateBefore == .paused ? "wake-preserves-paused" : "wake-no-op"
    }
}

public enum LoginItemDiagnosticBuilder {
    public static func configure(
        enabled: Bool,
        status: LaunchAtLoginStatus
    ) -> DiagnosticEvent {
        let reason: String?
        let outcome: String
        switch (enabled, status) {
        case (true, .enabled), (false, .notRegistered):
            reason = nil
            outcome = "success"
        case (_, .requiresApproval):
            reason = "requiresApproval"
            outcome = "requires-user-action"
        case (_, .notFound):
            reason = "notFound"
            outcome = "failure"
        case (true, .notRegistered):
            reason = "notRegistered"
            outcome = "failure"
        case (false, .enabled):
            reason = "enabled"
            outcome = "failure"
        }
        return DiagnosticEvent(
            category: .loginItem,
            event: "configure",
            reason: reason,
            outcome: outcome,
            failureType: reason
        )
    }
}

public enum DiagnosticLevelClassifier {
    public static func timer(_ sample: HIDSampleResult) -> DiagnosticLevel {
        sample.stateBefore != sample.stateAfter || !sample.effects.isEmpty ? .info : .debug
    }

    public static func persistence(_ result: PersistenceResult) -> DiagnosticLevel {
        switch result {
        case .persisted:
            return .info
        case .skipped:
            return .debug
        case .blocked, .failed:
            return .error
        }
    }
}
