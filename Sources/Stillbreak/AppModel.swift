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
    @Published private(set) var notificationAuthorization: NotificationAuthorization = .notDetermined
    @Published private(set) var notificationDeliveryFailed = false
    @Published private(set) var notificationAlertsDisabled = false
    let status: StatusBarModel

    private let store: HistoryStore
    private var reducer: TimerReducer
    private var timer: Timer?
    private var activityDetector = IdleActivityDetector()
    private var persistenceBlocked: Bool
    private var persistenceController: PersistenceController
    private var now: Date
    private var loggedThresholdIntervalID: UUID?
    private let notifications = NotificationService { event in
        Logs.notification.log(
            level: NotificationDiagnosticBuilder.level(for: event).osLogType,
            "\(event.message, privacy: .public)"
        )
    }

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

        loggedThresholdIntervalID = loaded.timer.interval?.notificationSent == true
            ? loaded.timer.interval?.id
            : nil
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
        notifications.onChange = { [weak self] in self?.syncNotificationState() }
        syncNotificationState()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appDidBecomeActive),
            name: NSApplication.didBecomeActiveNotification,
            object: nil
        )
        Task { [weak self] in
            guard let self else { return }
            await notifications.refresh(context: "launch")
        }
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

    @objc private func appDidBecomeActive() {
        refreshNotificationStatus()
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

    var notificationStatus: NotificationStatusPresentation {
        NotificationStatusPresentation.make(
            authorization: notificationAuthorization,
            notificationsEnabled: data.settings.notificationsEnabled,
            lastDeliveryFailed: notificationDeliveryFailed,
            alertsDisabled: notificationAlertsDisabled
        )
    }

    func refreshNotificationStatus() {
        Task { await notifications.refresh(context: "refresh") }
    }

    func settingsDidAppear() {
        if data.settings.notificationsEnabled {
            Task { await notifications.requestAuthorizationIfNeeded(context: "settings-open") }
        } else {
            refreshNotificationStatus()
        }
    }

    func performNotificationAction() {
        switch notificationStatus.action {
        case .none:
            break
        case .requestPermission:
            Task { _ = await notifications.requestAuthorization() }
        case .openSystemSettings:
            notifications.openSystemSettings()
        }
    }

    func updateSettings(_ settings: BreakSettings) {
        let loginChanged = settings.launchAtLogin != data.settings.launchAtLogin
        let notificationsTurnedOn = settings.notificationsEnabled && !data.settings.notificationsEnabled
        data.settings = settings
        if notificationsTurnedOn {
            Task { await notifications.requestAuthorizationIfNeeded(context: "settings") }
        }
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
                deliverNotification(sound: sound)
            case .playSound:
                NSSound.beep()
            case .log:
                break
            }
        }
        if result.data != data {
            data = result.data
        }
        logThresholdIfReached(effects: effects)
        return result.historyChanged || result.stateChanged
    }

    private func logThresholdIfReached(effects: [TimerEffect]) {
        guard reducer.state.mode == .active,
              let interval = reducer.state.interval,
              interval.notificationSent,
              loggedThresholdIntervalID != interval.id
        else { return }
        loggedThresholdIntervalID = interval.id
        log(
            NotificationDiagnosticBuilder.thresholdReached(
                threshold: interval.settings.workThreshold,
                provisional: interval.provisionalActive(at: now),
                notificationsEnabled: interval.settings.notificationsEnabled,
                soundEnabled: interval.settings.soundEnabled,
                effects: effects
            ),
            with: Logs.notification
        )
    }

    private func syncNotificationState() {
        notificationAuthorization = notifications.authorization
        notificationDeliveryFailed = notifications.lastDeliveryFailed
        notificationAlertsDisabled = notifications.alertsDisabled
    }

    private func deliverNotification(sound: Bool) {
        guard let intervalID = reducer.state.interval?.id else { return }
        let runner = NotificationDeliveryRunner(
            refresh: { [notifications] in await notifications.refresh(context: $0) },
            requestAuthorization: { [notifications] in await notifications.requestAuthorization() },
            deliver: { [notifications] in await notifications.deliver(sound: $0, attempt: $1) },
            sleep: { try? await Task.sleep(for: .seconds($0)) },
            isCurrent: { [weak self] in
                guard let self else { return false }
                return reducer.state.mode == .active && reducer.state.interval?.id == intervalID
            },
            cue: { [weak self] in self?.fallbackCue($0, playSound: $1) },
            cancelled: { [weak self] stage in
                self?.log(
                    NotificationDiagnosticBuilder.cancelled(stage: stage),
                    with: Logs.notification
                )
            }
        )
        Task { await runner.run(sound: sound) }
    }

    private func fallbackCue(_ reason: NotificationFallbackReason, playSound: Bool) {
        if playSound { NSSound.beep() }
        log(
            NotificationDiagnosticBuilder.fallback(reason: reason, soundPlayed: playSound),
            with: Logs.notification,
            level: .error
        )
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

extension DiagnosticLevel {
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
    static let notification = Logger(subsystem: subsystem, category: "notification")
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
