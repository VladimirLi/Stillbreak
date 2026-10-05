import Foundation

public enum PermissionlessHIDPolicy {
    public static let pollInterval: TimeInterval = 1
    public static let conservativeGrace: TimeInterval = pollInterval

    public static func processSample(
        now: Date,
        idleSeconds: TimeInterval,
        detector: inout IdleActivityDetector,
        reducer: inout TimerReducer,
        settings: BreakSettings
    ) -> HIDSampleResult {
        let stateBefore = reducer.state
        var effects: [TimerEffect] = []
        let eventAt = detector.activityDate(now: now, idleSeconds: idleSeconds)
        if let eventAt {
            effects += reducer.activity(
                at: eventAt,
                settings: settings,
                conservativeGrace: conservativeGrace
            )
        }
        effects += reducer.sample(at: now)
        return HIDSampleResult(
            effects: effects,
            inferredEventAt: eventAt,
            stateBefore: stateBefore,
            stateAfter: reducer.state
        )
    }
}

public struct HIDSampleResult: Sendable {
    public var effects: [TimerEffect]
    public var inferredEventAt: Date?
    public var stateBefore: TimerState
    public var stateAfter: TimerState
}

public struct IdleActivityDetector: Sendable {
    public let initialActivityWindow: TimeInterval
    public private(set) var lastEventAt: Date?
    private var lastSampleAt: Date?
    private var lastIdleSeconds: TimeInterval?

    public init(initialActivityWindow: TimeInterval = 1.5) {
        self.initialActivityWindow = initialActivityWindow
    }

    public mutating func baseline(at date: Date) {
        lastEventAt = date
        lastSampleAt = date
        lastIdleSeconds = 0
    }

    public mutating func activityDate(now: Date, idleSeconds: TimeInterval) -> Date? {
        let idle = max(0, idleSeconds)
        let eventAt = now.addingTimeInterval(-idle)
        guard let previousEvent = lastEventAt,
              let previousSample = lastSampleAt,
              let previousIdle = lastIdleSeconds
        else {
            lastEventAt = eventAt
            lastSampleAt = now
            lastIdleSeconds = idle
            return idle <= initialActivityWindow ? eventAt : nil
        }
        let observationAdvance = now.timeIntervalSince(previousSample) - (idle - previousIdle)
        lastEventAt = max(previousEvent, eventAt)
        lastSampleAt = now
        lastIdleSeconds = idle
        guard observationAdvance > 0,
              eventAt > previousEvent,
              idle <= initialActivityWindow
        else { return nil }
        return eventAt
    }
}

public enum LaunchAtLoginStatus: Sendable {
    case notRegistered
    case enabled
    case requiresApproval
    case notFound
}

public enum LaunchAtLoginAction: Equatable, Sendable {
    case none
    case register
    case unregister
}

public enum LaunchAtLoginPolicy {
    public static func action(
        enabled: Bool,
        status: LaunchAtLoginStatus
    ) -> LaunchAtLoginAction {
        switch (enabled, status) {
        case (true, .notRegistered):
            return .register
        case (false, .enabled), (false, .requiresApproval):
            return .unregister
        default:
            return .none
        }
    }

    public static func errorMessage(
        enabled: Bool,
        status: LaunchAtLoginStatus
    ) -> String? {
        switch status {
        case .notFound:
            return "Stillbreak could not be found by macOS Login Items."
        case .requiresApproval where enabled:
            return "Open System Settings to approve Stillbreak as a login item."
        default:
            return nil
        }
    }
}

public enum StateFileLocator {
    public static let overrideVariable = "STILLBREAK_STATE_FILE"

    public static func url(
        environment: [String: String],
        applicationSupport: URL
    ) -> URL {
        environment[overrideVariable].map {
            URL(fileURLWithPath: $0).standardizedFileURL
        } ?? applicationSupport
            .appendingPathComponent("Stillbreak", isDirectory: true)
            .appendingPathComponent("state.json")
    }
}
