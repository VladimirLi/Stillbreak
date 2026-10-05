import Foundation

/// Funnels every notification-permission prompt through one request so overlapping callers
/// share a single macOS prompt and the same result.
@MainActor
public final class NotificationPermissionRequester {
    public typealias Result = (granted: Bool, failed: Bool)

    private let refresh: @MainActor (_ context: String) async -> NotificationAuthorization
    private let perform: @MainActor () async -> Result
    private var inFlight: Task<Result, Never>?

    public init(
        refresh: @escaping @MainActor (_ context: String) async -> NotificationAuthorization,
        perform: @escaping @MainActor () async -> Result
    ) {
        self.refresh = refresh
        self.perform = perform
    }

    public func request() async -> Result {
        if let inFlight { return await inFlight.value }
        let task = Task { [perform] in
            let result = await perform()
            self.inFlight = nil
            return result
        }
        inFlight = task
        return await task.value
    }

    public func requestIfNeeded(context: String) async {
        if let inFlight {
            _ = await inFlight.value
            return
        }
        if await refresh(context) == .notDetermined {
            _ = await request()
        }
    }
}
