import Foundation

public struct TimerEffectApplicationResult: Sendable {
    public var data: PersistedData
    public var forwardedEffects: [TimerEffect]
    public var historyChanged: Bool
    public var stateChanged: Bool
    /// True when the timer state changed in a way that must be persisted at
    /// once, as opposed to a sample that only advanced the running interval.
    public var materialStateChanged: Bool
}

public enum TimerEffectProcessor {
    public static func apply(
        _ effects: [TimerEffect],
        state: TimerState,
        to data: PersistedData
    ) -> TimerEffectApplicationResult {
        var updated = data
        var forwarded: [TimerEffect] = []
        var historyChanged = false
        for effect in effects {
            if case let .log(record) = effect {
                guard !updated.history.contains(where: { $0.id == record.id }) else { continue }
                updated.history.append(record)
                historyChanged = true
            } else {
                forwarded.append(effect)
            }
        }
        let stateChanged = updated.timer != state
        let materialStateChanged = updated.timer.differsMaterially(from: state)
        updated.timer = state
        return TimerEffectApplicationResult(
            data: updated,
            forwardedEffects: forwarded,
            historyChanged: historyChanged,
            stateChanged: stateChanged,
            materialStateChanged: materialStateChanged
        )
    }
}

extension TimerState {
    /// Advancing `lastActivityAt` and the work segments of the same interval is
    /// not material: the 60-second checkpoint and lifecycle flushes cover it.
    func differsMaterially(from other: TimerState) -> Bool {
        mode != other.mode
            || interval?.id != other.interval?.id
            || interval?.notificationSent != other.interval?.notificationSent
            || interval?.settings != other.interval?.settings
    }
}

public struct PersistenceCadence: Sendable {
    public let checkpointInterval: TimeInterval
    private var lastSavedAt: Date?

    public init(checkpointInterval: TimeInterval = 60, lastSavedAt: Date? = nil) {
        self.checkpointInterval = checkpointInterval
        self.lastSavedAt = lastSavedAt
    }

    public mutating func shouldSave(
        at date: Date,
        changed: Bool,
        force: Bool = false
    ) -> Bool {
        let checkpointDue = lastSavedAt.map {
            date.timeIntervalSince($0) >= checkpointInterval
        } ?? true
        guard force || changed || checkpointDue else { return false }
        lastSavedAt = date
        return true
    }

    public mutating func markSaveFailed() {
        lastSavedAt = nil
    }
}

public enum PersistenceResult: Equatable, Sendable {
    case persisted
    case skipped
    case blocked
    case failed(type: String, message: String)

    public var outcome: String {
        switch self {
        case .persisted:
            return "persisted"
        case .skipped:
            return "skipped"
        case .blocked:
            return "blocked"
        case .failed:
            return "failed"
        }
    }

    public var failureType: String? {
        if case let .failed(type, _) = self { return type }
        return nil
    }

    public var failureMessage: String? {
        if case let .failed(_, message) = self { return message }
        return nil
    }
}

public struct PersistenceController: Sendable {
    private var cadence: PersistenceCadence

    public init(checkpointInterval: TimeInterval = 60, lastSavedAt: Date? = nil) {
        cadence = PersistenceCadence(
            checkpointInterval: checkpointInterval,
            lastSavedAt: lastSavedAt
        )
    }

    public mutating func save(
        at date: Date,
        changed: Bool,
        force: Bool = false,
        blocked: Bool,
        operation: () throws -> Void
    ) -> PersistenceResult {
        guard !blocked else { return .blocked }
        guard cadence.shouldSave(at: date, changed: changed, force: force) else {
            return .skipped
        }
        do {
            try operation()
            return .persisted
        } catch {
            cadence.markSaveFailed()
            return .failed(
                type: String(reflecting: type(of: error)),
                message: error.localizedDescription
            )
        }
    }
}
