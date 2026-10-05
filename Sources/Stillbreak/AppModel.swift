import StillbreakCore
import AppKit
import CoreGraphics
import Foundation
import OSLog
import ServiceManagement
@preconcurrency import UserNotifications

@MainActor
final class StatusBarModel: ObservableObject {
    @Published private(set) var text: String
    @Published private(set) var isOverdue: Bool

    init(text: String, isOverdue: Bool) {
        self.text = text
        self.isOverdue = isOverdue
    }

    func update(text: String, isOverdue: Bool) {
        guard self.text != text || self.isOverdue != isOverdue else { return }
        self.text = text
        self.isOverdue = isOverdue
    }
}

@MainActor
final class AppModel: NSObject, ObservableObject {
    @Published private(set) var data: PersistedData
    @Published private(set) var launchAtLoginError: String?
    @Published private(set) var persistenceError: String?
    let status: StatusBarModel

    private let store: HistoryStore
    private var reducer: TimerReducer
    private var timer: Timer?
    private var activityDetector = IdleActivityDetector()
    private var persistenceBlocked: Bool
    private var persistenceController: PersistenceController
    private var now: Date

    override init() {
        let launchNow = Date()
        let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!
        let environment = ProcessInfo.processInfo.environment
        let stateURL = StateFileLocator.url(
            environment: environment,
            applicationSupport: applicationSupport
        )
        let store = HistoryStore(url: stateURL)
        let loaded: PersistedData
        let loadError: String?
        do {
            loaded = try store.load()
            loadError = nil
        } catch {
            loaded = PersistedData()
            loadError = error.localizedDescription
        }
        self.store = store
        self.data = loaded
        self.reducer = TimerReducer(state: loaded.timer)
        self.persistenceError = loadError
        self.persistenceBlocked = loadError != nil
        self.persistenceController = PersistenceController(lastSavedAt: loaded.savedAt)
        self.now = launchNow
        let remaining = self.reducer.remaining(at: launchNow, defaultSettings: loaded.settings)
        self.status = StatusBarModel(
            text: self.reducer.state.mode == .paused
                ? "Paused"
                : CountdownFormatter.string(seconds: remaining),
            isOverdue: self.reducer.state.mode == .active && remaining <= 0
        )
        super.init()

        log(
            DiagnosticEvent(
                category: .persistence,
                event: "load",
                reason: loadError == nil ? nil : "decode-or-read",
                outcome: loadError == nil ? "success" : "failure"
            ),
            with: Logs.persistence,
            level: loadError == nil ? .info : .error
        )
        let before = reducer.state.mode
        let systemUptime = ProcessInfo.processInfo.systemUptime
        let relaunchReason = TimerReducer.relaunchReason(
            state: reducer.state,
            savedAt: loaded.savedAt,
            savedSystemUptime: loaded.savedSystemUptime,
            now: now,
            systemUptime: systemUptime
        )
        let effects = reducer.restore(
            savedAt: loaded.savedAt,
            savedSystemUptime: loaded.savedSystemUptime,
            now: now,
            systemUptime: systemUptime
        )
        let changed = apply(effects)
        updateStatus()
        let saveResult = save(changed: changed, force: true)
        log(
            LifecycleDiagnosticBuilder.event(
                "relaunch",
                reason: relaunchReason.rawValue,
                stateBefore: before,
                stateAfter: reducer.state.mode,
                effects: effects,
                persistence: saveResult
            ),
            with: Logs.lifecycle
        )
        configureLaunchAtLogin(enabled: data.settings.launchAtLogin)
        timer = Timer.scheduledTimer(
            timeInterval: PermissionlessHIDPolicy.pollInterval,
            target: self,
            selector: #selector(poll),
            userInfo: nil,
            repeats: true
        )
        RunLoop.main.add(timer!, forMode: .common)
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(didWake),
            name: NSWorkspace.didWakeNotification,
            object: nil
        )
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(willSleep),
            name: NSWorkspace.willSleepNotification,
            object: nil
        )
    }

    var settings: BreakSettings { data.settings }
    var history: [HistoryRecord] { data.history }
    var currentInterval: ActiveInterval? {
        reducer.state.mode == .active ? reducer.state.interval : nil
    }
    var isPaused: Bool { reducer.state.mode == .paused }
    var remaining: TimeInterval { reducer.remaining(at: now, defaultSettings: data.settings) }
    var isOverdue: Bool { reducer.state.mode == .active && remaining <= 0 }
    var statusText: String {
        isPaused ? "Paused" : CountdownFormatter.string(seconds: remaining)
    }

    @objc private func poll() {
        now = Date()
        let changed = processHIDActivity(context: "poll")
        updateStatus()
        save(changed: changed)
    }

    @objc private func willSleep() {
        now = Date()
        let before = reducer.state.mode
        let changed = processHIDActivity(context: "sleep")
        let saveResult = save(changed: changed, force: true)
        log(
            LifecycleDiagnosticBuilder.event(
                "sleep",
                stateBefore: before,
                stateAfter: reducer.state.mode,
                persistence: saveResult
            ),
            with: Logs.lifecycle
        )
    }

    @objc private func didWake() {
        now = Date()
        activityDetector = IdleActivityDetector()
        let before = reducer.state.mode
        let effects = reducer.wake(at: now)
        let changed = apply(effects)
        updateStatus()
        let saveResult = save(changed: changed, force: true)
        log(
            LifecycleDiagnosticBuilder.event(
                "wake",
                reason: LifecycleDiagnosticReason.wake(
                    stateBefore: before,
                    effects: effects
                ),
                stateBefore: before,
                stateAfter: reducer.state.mode,
                effects: effects,
                persistence: saveResult
            ),
            with: Logs.lifecycle
        )
    }

    func togglePause() {
        now = Date()
        let before = reducer.state.mode
        let effects: [TimerEffect]
        if isPaused {
            reducer.resume()
            activityDetector.baseline(at: now)
            effects = []
        } else {
            effects = reducer.pause(at: now)
        }
        let changed = apply(effects)
        updateStatus()
        let saveResult = save(changed: changed, force: true)
        log(
            LifecycleDiagnosticBuilder.event(
                isPaused ? "pause" : "resume",
                stateBefore: before,
                stateAfter: reducer.state.mode,
                effects: effects,
                persistence: saveResult
            ),
            with: Logs.lifecycle
        )
    }

    func updateSettings(_ settings: BreakSettings) {
        let loginChanged = settings.launchAtLogin != data.settings.launchAtLogin
        data.settings = settings
        if loginChanged {
            configureLaunchAtLogin(enabled: settings.launchAtLogin)
        }
        save(changed: true, force: true)
    }

    func deleteAllHistory() {
        data.history.removeAll()
        save(changed: true, force: true)
    }

    func export(format: ExportFormat, from start: Date, before end: Date) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [format.contentType]
        panel.nameFieldStringValue = "Stillbreak-\(format.rawValue).\(format.fileExtension)"
        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            let bytes = try format == .json
                ? HistoryExporter.json(data.history, from: start, before: end)
                : HistoryExporter.csv(data.history, from: start, before: end)
            try bytes.write(to: url, options: .atomic)
        } catch {
            let alert = NSAlert(error: error)
            alert.runModal()
        }
    }

    func prepareToQuit() {
        now = Date()
        let before = reducer.state.mode
        let changed = processHIDActivity(context: "quit")
        let saveResult = save(changed: changed, force: true)
        log(
            LifecycleDiagnosticBuilder.event(
                "quit",
                stateBefore: before,
                stateAfter: reducer.state.mode,
                persistence: saveResult
            ),
            with: Logs.lifecycle
        )
    }

    @discardableResult
    private func apply(_ effects: [TimerEffect]) -> Bool {
        let result = TimerEffectProcessor.apply(effects, state: reducer.state, to: data)
        for effect in result.forwardedEffects {
            switch effect {
            case let .notify(sound):
                sendNotification(sound: sound)
            case .playSound:
                NSSound.beep()
            case .log:
                break
            }
        }
        if result.data != data {
            data = result.data
        }
        return result.historyChanged || result.stateChanged
    }

    private func sendNotification(sound: Bool) {
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = "Time for a break"
            content.body = "You reached your Stillbreak work threshold."
            content.sound = sound ? .default : nil
            center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
        }
    }

    private func configureLaunchAtLogin(enabled: Bool) {
        guard ProcessInfo.processInfo.environment["STILLBREAK_DISABLE_LOGIN_ITEM_MUTATION"] != "1" else {
            log(
                DiagnosticEvent(
                    category: .loginItem,
                    event: "configure",
                    outcome: "disabled-by-environment"
                ),
                with: Logs.loginItem
            )
            return
        }
        let service = SMAppService.mainApp
        do {
            switch LaunchAtLoginPolicy.action(
                enabled: enabled,
                status: service.status.stillbreak
            ) {
            case .register:
                try service.register()
            case .unregister:
                try service.unregister()
            case .none:
                break
            }
            let status = service.status.stillbreak
            launchAtLoginError = LaunchAtLoginPolicy.errorMessage(
                enabled: enabled,
                status: status
            )
            let event = LoginItemDiagnosticBuilder.configure(
                enabled: enabled,
                status: status
            )
            log(
                event,
                with: Logs.loginItem,
                level: event.outcome == "success" ? .info : .error
            )
        } catch {
            launchAtLoginError = error.localizedDescription
            log(
                DiagnosticEvent(
                    category: .loginItem,
                    event: "configure",
                    reason: String(reflecting: type(of: error)),
                    outcome: "failure",
                    failureType: String(reflecting: type(of: error))
                ),
                with: Logs.loginItem,
                level: .error
            )
        }
    }

    @discardableResult
    private func processHIDActivity(context: String) -> Bool {
        let idle = CGEventSource.secondsSinceLastEventType(
            .hidSystemState,
            eventType: CGEventType(rawValue: UInt32.max)!
        )
        let sample = PermissionlessHIDPolicy.processSample(
            now: now,
            idleSeconds: idle,
            detector: &activityDetector,
            reducer: &reducer,
            settings: data.settings
        )
        let changed = apply(sample.effects)
        log(
            TimerDiagnosticBuilder.sample(
                sample,
                now: now,
                idleSeconds: idle,
                defaultSettings: data.settings,
                context: context
            ),
            with: Logs.timer,
            level: DiagnosticLevelClassifier.timer(sample)
        )
        return changed
    }

    private func updateStatus() {
        status.update(text: statusText, isOverdue: isOverdue)
    }

    @discardableResult
    private func save(changed: Bool, force: Bool = false) -> PersistenceResult {
        var snapshot = data
        snapshot.savedAt = now
        snapshot.savedSystemUptime = ProcessInfo.processInfo.systemUptime
        let result = persistenceController.save(
            at: now,
            changed: changed,
            force: force,
            blocked: persistenceBlocked
        ) {
            try store.save(snapshot)
        }
        switch result {
        case .persisted:
            persistenceError = nil
        case .failed:
            persistenceError = result.failureMessage
        case .skipped, .blocked:
            break
        }
        log(
            DiagnosticEvent(
                category: .persistence,
                event: "save",
                reason: result.failureType,
                stateAfter: reducer.state.mode,
                outcome: result.outcome
            ),
            with: Logs.persistence,
            level: DiagnosticLevelClassifier.persistence(result)
        )
        return result
    }

    private func log(
        _ event: DiagnosticEvent,
        with logger: Logger,
        level: DiagnosticLevel = .info
    ) {
        logger.log(level: level.osLogType, "\(event.message, privacy: .public)")
    }
}

private extension DiagnosticLevel {
    var osLogType: OSLogType {
        switch self {
        case .debug:
            return .debug
        case .info:
            return .info
        case .error:
            return .error
        }
    }
}

private enum Logs {
    private static let subsystem = "com.vladimirli.Stillbreak"
    static let timer = Logger(subsystem: subsystem, category: "timer")
    static let lifecycle = Logger(subsystem: subsystem, category: "lifecycle")
    static let persistence = Logger(subsystem: subsystem, category: "persistence")
    static let loginItem = Logger(subsystem: subsystem, category: "login-item")
}

private extension TimerEffect {
    var recordID: UUID? {
        if case let .log(record) = self { return record.id }
        return nil
    }
}

private extension SMAppService.Status {
    var stillbreak: LaunchAtLoginStatus {
        switch self {
        case .notRegistered:
            return .notRegistered
        case .enabled:
            return .enabled
        case .requiresApproval:
            return .requiresApproval
        case .notFound:
            return .notFound
        @unknown default:
            return .notFound
        }
    }
}
