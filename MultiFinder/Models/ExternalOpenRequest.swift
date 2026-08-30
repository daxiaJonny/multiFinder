import AppKit
import Foundation

struct ExternalOpenRequest: Equatable, Sendable {
    static let scheme = "multifinder"
    static let host = "open"

    let targetURL: URL

    init?(url: URL) {
        guard let targetURL = Self.targetURL(from: url) else { return nil }
        self.targetURL = targetURL
    }

    static func url(for targetURL: URL) -> URL? {
        guard let localURL = Self.localFileURL(from: targetURL) else { return nil }

        var components = URLComponents()
        components.scheme = scheme
        components.host = host
        components.queryItems = [URLQueryItem(name: "path", value: localURL.path)]
        return components.url
    }

    private static func targetURL(from url: URL) -> URL? {
        guard let scheme = url.scheme?.lowercased() else { return nil }

        switch scheme {
        case "file":
            return Self.localFileURL(from: url)
        case Self.scheme:
            guard url.host?.lowercased() == Self.host,
                  let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
                  let path = components.queryItems?.first(where: {
                      $0.name.caseInsensitiveCompare("path") == .orderedSame
                  })?.value,
                  Self.isAbsolutePath(path) else { return nil }
            return URL(fileURLWithPath: path).standardizedFileURL
        default:
            return nil
        }
    }

    private static func localFileURL(from url: URL) -> URL? {
        guard url.isFileURL,
              !url.path.isEmpty,
              Self.isAbsolutePath(url.path) else { return nil }

        if let host = url.host,
           !host.isEmpty,
           host.caseInsensitiveCompare("localhost") != .orderedSame {
            return nil
        }

        // Construct from the path so localhost cannot leak into the internal URL.
        return URL(fileURLWithPath: url.path).standardizedFileURL
    }

    private static func isAbsolutePath(_ path: String) -> Bool {
        path.hasPrefix("/")
    }
}

enum ExternalOpenEventSource: Equatable, Sendable {
    case appKit
    case swiftUI
}

@MainActor
final class ExternalOpenRouter {
    typealias Delivery = @MainActor (ExternalOpenRequest) -> Void
    typealias BatchDelivery = @MainActor ([ExternalOpenRequest]) -> Void
    typealias WorkspaceOpenAction = @MainActor () -> Void

    static let shared = ExternalOpenRouter()

    private final class WorkspaceRegistration {
        let id: UUID
        let isManagerBacked: Bool
        let deliver: Delivery
        let deliverBatch: BatchDelivery?
        weak var layoutManager: LayoutManager?
        weak var window: NSWindow?

        init(
            id: UUID,
            layoutManager: LayoutManager?,
            window: NSWindow?,
            isManagerBacked: Bool,
            deliver: @escaping Delivery,
            deliverBatch: BatchDelivery? = nil
        ) {
            self.id = id
            self.layoutManager = layoutManager
            self.window = window
            self.isManagerBacked = isManagerBacked
            self.deliver = deliver
            self.deliverBatch = deliverBatch
        }
    }

    private struct RecentRequest {
        let date: Date
    }

    private let duplicateDeliveryWindow: TimeInterval
    private let now: () -> Date
    private var registrations: [UUID: WorkspaceRegistration] = [:]
    private var managerRegistrationIDs: [ObjectIdentifier: UUID] = [:]
    private var activeRegistrationID: UUID?
    private var pendingEvents: [[ExternalOpenRequest]] = []
    private var recentRequests: [String: RecentRequest] = [:]
    private var workspaceOpenAction: WorkspaceOpenAction?
    private var workspaceOpenRequestInFlight = false

    var pendingRequestCount: Int {
        pendingEvents.reduce(0) { $0 + $1.count }
    }

    init(
        duplicateDeliveryWindow: TimeInterval = 2,
        now: @escaping () -> Date = { Date() }
    ) {
        self.duplicateDeliveryWindow = max(0, duplicateDeliveryWindow)
        self.now = now
    }

    @discardableResult
    func receive(
        urls: [URL],
        source: ExternalOpenEventSource = .appKit
    ) -> Int {
        let requests = Self.uniqueRequests(urls.compactMap(ExternalOpenRequest.init(url:)))
        guard !requests.isEmpty else { return 0 }

        let timestamp = now()
        pruneRecentEntries(at: timestamp)

        var acceptedRequests: [ExternalOpenRequest] = []
        acceptedRequests.reserveCapacity(requests.count)
        for request in requests {
            let requestKey = Self.requestKey(for: request)
            if let recentRequest = recentRequests[requestKey],
               isRecent(recentRequest.date, at: timestamp) {
                continue
            }

            recentRequests[requestKey] = RecentRequest(date: timestamp)
            acceptedRequests.append(request)
        }

        guard !acceptedRequests.isEmpty else { return 0 }
        // Keep one incoming open event together until it reaches the workspace.
        pendingEvents.append(acceptedRequests)
        drainPendingRequests()
        return acceptedRequests.count
    }

    func setWorkspaceOpenAction(_ action: WorkspaceOpenAction?) {
        workspaceOpenAction = action
        guard action != nil else { return }
        drainPendingRequests()
    }

    @discardableResult
    func register(
        layoutManager: LayoutManager,
        window: NSWindow? = nil
    ) -> UUID {
        let managerID = ObjectIdentifier(layoutManager)
        if let registrationID = managerRegistrationIDs[managerID],
           let registration = registrations[registrationID] {
            registration.layoutManager = layoutManager
            workspaceOpenRequestInFlight = false
            if let window {
                registration.window = window
                if isCurrentWindow(window) {
                    activeRegistrationID = registrationID
                }
            }
            drainPendingRequests()
            return registrationID
        }

        let registrationID = UUID()
        let registration = WorkspaceRegistration(
            id: registrationID,
            layoutManager: layoutManager,
            window: window,
            isManagerBacked: true
        ) { [weak layoutManager] request in
            _ = layoutManager?.openExternalPath(request.targetURL)
        } deliverBatch: { [weak layoutManager] requests in
            _ = layoutManager?.openExternalPaths(requests.map(\.targetURL))
        }
        registrations[registrationID] = registration
        managerRegistrationIDs[managerID] = registrationID
        workspaceOpenRequestInFlight = false

        if let window, isCurrentWindow(window) {
            activeRegistrationID = registrationID
        }
        drainPendingRequests()
        return registrationID
    }

    @discardableResult
    func register(
        workspaceID: UUID = UUID(),
        window: NSWindow? = nil,
        handler: @escaping Delivery
    ) -> UUID {
        let registration = WorkspaceRegistration(
            id: workspaceID,
            layoutManager: nil,
            window: window,
            isManagerBacked: false,
            deliver: handler
        )
        registrations[workspaceID] = registration
        workspaceOpenRequestInFlight = false
        if let window, isCurrentWindow(window) {
            activeRegistrationID = workspaceID
        }
        drainPendingRequests()
        return workspaceID
    }

    @discardableResult
    func registerBatch(
        workspaceID: UUID = UUID(),
        window: NSWindow? = nil,
        handler: @escaping BatchDelivery
    ) -> UUID {
        let registration = WorkspaceRegistration(
            id: workspaceID,
            layoutManager: nil,
            window: window,
            isManagerBacked: false,
            deliver: { _ in },
            deliverBatch: handler
        )
        registrations[workspaceID] = registration
        workspaceOpenRequestInFlight = false
        if let window, isCurrentWindow(window) {
            activeRegistrationID = workspaceID
        }
        drainPendingRequests()
        return workspaceID
    }

    func unregister(layoutManager: LayoutManager) {
        let managerID = ObjectIdentifier(layoutManager)
        guard let registrationID = managerRegistrationIDs.removeValue(forKey: managerID) else {
            return
        }
        removeRegistration(withID: registrationID)
        drainPendingRequests()
    }

    func unregister(workspaceID: UUID) {
        removeRegistration(withID: workspaceID)
        drainPendingRequests()
    }

    @discardableResult
    func drainPendingRequests() -> Int {
        removeStaleRegistrations()
        guard !pendingEvents.isEmpty else { return 0 }

        guard let registration = activeRegistration() else {
            requestWorkspaceIfNeeded()
            return 0
        }

        let events = pendingEvents
        pendingEvents.removeAll(keepingCapacity: true)
        workspaceOpenRequestInFlight = false
        activate(registration)
        var deliveredCount = 0
        for requests in events {
            if let deliverBatch = registration.deliverBatch {
                deliverBatch(requests)
            } else {
                for request in requests {
                    registration.deliver(request)
                }
            }
            deliveredCount += requests.count
        }
        return deliveredCount
    }

    private func activeRegistration() -> WorkspaceRegistration? {
        removeStaleRegistrations()

        if let keyWindow = NSApp.keyWindow,
           let registration = registrations.values.first(where: { $0.window === keyWindow }) {
            activeRegistrationID = registration.id
            return registration
        }

        if let mainWindow = NSApp.mainWindow,
           let registration = registrations.values.first(where: { $0.window === mainWindow }) {
            activeRegistrationID = registration.id
            return registration
        }

        if let activeRegistrationID,
           let registration = registrations[activeRegistrationID],
           !registration.isManagerBacked || registration.window != nil {
            return registration
        }

        guard registrations.count == 1,
              let registration = registrations.values.first,
              !registration.isManagerBacked || registration.window != nil else {
            return nil
        }
        return registration
    }

    func windowDidBecomeKey(_ window: NSWindow) {
        guard let registration = registrations.values.first(where: { $0.window === window }) else {
            return
        }
        activeRegistrationID = registration.id
        drainPendingRequests()
    }

    func windowWillClose(_ window: NSWindow) {
        guard let registration = registrations.values.first(where: { $0.window === window }) else {
            return
        }
        if let layoutManager = registration.layoutManager {
            managerRegistrationIDs.removeValue(forKey: ObjectIdentifier(layoutManager))
        }
        removeRegistration(withID: registration.id)
        drainPendingRequests()
    }

    private func removeRegistration(withID id: UUID) {
        registrations.removeValue(forKey: id)
        managerRegistrationIDs = managerRegistrationIDs.filter { $0.value != id }
        if activeRegistrationID == id {
            activeRegistrationID = nil
        }
    }

    private func removeStaleRegistrations() {
        let staleIDs = registrations.values
            .filter { $0.isManagerBacked && $0.layoutManager == nil }
            .map(\.id)
        for id in staleIDs {
            removeRegistration(withID: id)
        }
    }

    private func isCurrentWindow(_ window: NSWindow) -> Bool {
        NSApp.keyWindow === window || NSApp.mainWindow === window
    }

    private func pruneRecentEntries(at timestamp: Date) {
        recentRequests = recentRequests.filter { isRecent($0.value.date, at: timestamp) }
    }

    private func isRecent(_ date: Date, at timestamp: Date) -> Bool {
        guard duplicateDeliveryWindow > 0 else { return false }
        let elapsed = timestamp.timeIntervalSince(date)
        return elapsed >= 0 && elapsed <= duplicateDeliveryWindow
    }

    private func requestWorkspaceIfNeeded() {
        guard !pendingEvents.isEmpty,
              !workspaceOpenRequestInFlight,
              !hasRegisteredWorkspaceScene,
              let action = workspaceOpenAction else { return }

        workspaceOpenRequestInFlight = true
        action()
    }

    private var hasRegisteredWorkspaceScene: Bool {
        registrations.values.contains { registration in
            registration.layoutManager != nil || registration.window != nil
        }
    }

    private func activate(_ registration: WorkspaceRegistration) {
        guard let window = registration.window else { return }
        if window.isMiniaturized {
            window.deminiaturize(nil)
        }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    private static func uniqueRequests(_ requests: [ExternalOpenRequest]) -> [ExternalOpenRequest] {
        var seenKeys = Set<String>()
        return requests.filter { request in
            seenKeys.insert(requestKey(for: request)).inserted
        }
    }

    private static func requestKey(for request: ExternalOpenRequest) -> String {
        request.targetURL.standardizedFileURL.absoluteString
    }
}
