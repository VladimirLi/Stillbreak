import AppKit
import Foundation
import StillbreakCore
@preconcurrency import UserNotifications

@MainActor
final class NotificationService: NSObject, UNUserNotificationCenterDelegate {
    private let center: UNUserNotificationCenter?
    private let log: (DiagnosticEvent) -> Void
    private(set) var authorization: NotificationAuthorization = .notDetermined
    private(set) var lastDeliveryFailed = false
    var onChange: (() -> Void)?

    init(log: @escaping (DiagnosticEvent) -> Void) {
        // UNUserNotificationCenter.current() traps outside an .app bundle (e.g. `swift run`).
        center = Bundle.main.bundleURL.pathExtension == "app" ? UNUserNotificationCenter.current() : nil
        self.log = log
        super.init()
        center?.delegate = self
        if center == nil { authorization = .unavailable }
    }

    @discardableResult
    func refresh(context: String) async -> NotificationAuthorization {
        let status: NotificationAuthorization
        if let center {
            status = await center.notificationSettings().authorizationStatus.stillbreak
        } else {
            status = .unavailable
        }
        setAuthorization(status)
        log(NotificationDiagnosticBuilder.authorizationStatus(status, context: context))
        return status
    }

    func requestAuthorization() async -> (granted: Bool, failed: Bool) {
        guard let center else { return (false, true) }
        var granted = false
        var failure: String?
        do {
            granted = try await center.requestAuthorization(options: [.alert, .sound])
        } catch {
            let nsError = error as NSError
            failure = NotificationDiagnosticBuilder.failureType(
                domain: nsError.domain,
                code: nsError.code
            )
        }
        log(NotificationDiagnosticBuilder.authorizationRequest(granted: granted, failure: failure))
        await refresh(context: "after-request")
        return (granted, failure != nil)
    }

    func requestAuthorizationIfNeeded(context: String) async {
        if await refresh(context: context) == .notDetermined {
            _ = await requestAuthorization()
        }
    }

    func deliver(sound: Bool, attempt: Int) async -> Bool {
        guard let center else { return false }
        let content = UNMutableNotificationContent()
        content.title = "Time for a break"
        content.body = "You reached your Stillbreak work threshold."
        content.sound = sound ? .default : nil
        var failure: String?
        do {
            try await center.add(UNNotificationRequest(
                identifier: UUID().uuidString,
                content: content,
                trigger: nil
            ))
        } catch {
            let nsError = error as NSError
            failure = NotificationDiagnosticBuilder.failureType(
                domain: nsError.domain,
                code: nsError.code
            )
        }
        log(NotificationDiagnosticBuilder.add(attempt: attempt, failure: failure))
        lastDeliveryFailed = failure != nil
        onChange?()
        return failure == nil
    }

    func openSystemSettings() {
        let urls = [
            "x-apple.systempreferences:com.apple.Notifications-Settings.extension",
            "x-apple.systempreferences:",
        ]
        for string in urls {
            if let url = URL(string: string), NSWorkspace.shared.open(url) { return }
        }
    }

    private func setAuthorization(_ value: NotificationAuthorization) {
        guard authorization != value else { return }
        authorization = value
        onChange?()
    }

    // Without this, macOS drops notifications while Stillbreak is frontmost (e.g. Settings is open).
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }
}

private extension UNAuthorizationStatus {
    var stillbreak: NotificationAuthorization {
        switch self {
        case .notDetermined:
            return .notDetermined
        case .denied:
            return .denied
        case .authorized:
            return .authorized
        case .provisional:
            return .provisional
        case .ephemeral:
            return .ephemeral
        @unknown default:
            return .unavailable
        }
    }
}
