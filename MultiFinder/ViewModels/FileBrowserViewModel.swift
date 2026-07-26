import AppKit
import Combine
import Foundation
import SwiftUI

enum SortField: String, CaseIterable, Codable, Sendable {
    case name = "Name"
    case date = "Date Modified"
    case size = "Size"
    case kind = "Kind"
}

@MainActor
final class FileBrowserViewModel: ObservableObject, Identifiable {
    let id = UUID()

    @Published private(set) var location: BrowserLocation
    @Published private(set) var items: [FileItem] = []
    @Published var selectedItems: Set<FileItem.ID> = []
    @Published var sortOrder: [FileItemComparator] {
        didSet {
            guard let comparator = sortOrder.first else { return }
            items = Self.sort(items: items, using: comparator)
        }
    }
    @Published var showHiddenFiles: Bool {
        didSet {
            if oldValue != showHiddenFiles {
                reload()
            }
        }
    }
    @Published private(set) var isLoading = false
    @Published var errorMessage: String?

    private(set) var backHistory: [BrowserLocation]
    private(set) var forwardHistory: [BrowserLocation]

    var currentURL: URL? { location.directoryURL }
    var title: String { location.title }
    var pathDescription: String { location.pathDescription }
    var canGoBack: Bool { !backHistory.isEmpty }
    var canGoForward: Bool { !forwardHistory.isEmpty }
    var canGoUp: Bool {
        guard let url = currentURL else { return false }
        return url.deletingLastPathComponent() != url
    }
    var canCreateItems: Bool { location.supportsCreatingItems }
    var sortField: SortField { sortOrder.first?.field ?? .name }
    var sortAscending: Bool { sortOrder.first?.order != .reverse }

    var selectedItemURLs: [URL] {
        items.filter { selectedItems.contains($0.id) }.map(\.url)
    }

    var selectedItem: FileItem? {
        guard selectedItems.count == 1, let id = selectedItems.first else { return nil }
        return items.first { $0.id == id }
    }

    private let operationService: FileOperationService
    private let directoryMonitor = DirectoryMonitor()
    private var loadTask: Task<Void, Never>?
    private var monitorRefreshTask: Task<Void, Never>?
    private var loadGeneration: UInt64 = 0
    private var pendingSelectionURL: URL?

    init(
        location: BrowserLocation = .directory(FileManager.default.homeDirectoryForCurrentUser),
        sortField: SortField = .name,
        sortAscending: Bool = true,
        showHiddenFiles: Bool = false,
        backHistory: [BrowserLocation] = [],
        forwardHistory: [BrowserLocation] = [],
        operationService: FileOperationService = .shared
    ) {
        self.location = Self.normalized(location)
        self.sortOrder = [FileItemComparator(field: sortField, order: sortAscending ? .forward : .reverse)]
        self.showHiddenFiles = showHiddenFiles
        self.backHistory = backHistory.map(Self.normalized)
        self.forwardHistory = forwardHistory.map(Self.normalized)
        self.operationService = operationService
        configureDirectoryMonitor()
        reload()
    }

    convenience init(startURL: URL?) {
        self.init(location: .directory(startURL ?? FileManager.default.homeDirectoryForCurrentUser))
    }

    deinit {
        loadTask?.cancel()
        monitorRefreshTask?.cancel()
    }

    // MARK: - Loading

    func reload(preservingError: Bool = false) {
        loadTask?.cancel()
        loadGeneration &+= 1
        let requestGeneration = loadGeneration
        let requestedLocation = location
        let includeHidden = showHiddenFiles

        isLoading = true
        if !preservingError {
            errorMessage = nil
        }

        loadTask = Task { [weak self] in
            guard let self else { return }
            do {
                let loadedItems: [FileItem]
                switch requestedLocation {
                case .directory(let url):
                    loadedItems = try await Self.loadDirectory(at: url, includeHidden: includeHidden)
                case .recents, .search:
                    let urls = try await metadataURLs(for: requestedLocation, includeHidden: includeHidden)
                    loadedItems = try await Self.makeItems(from: urls, includeHidden: includeHidden)
                }

                try Task.checkCancellation()
                guard loadGeneration == requestGeneration, location == requestedLocation else { return }

                let currentComparator = sortOrder.first ?? FileItemComparator(field: .name)
                let sortedItems = Self.sort(items: loadedItems, using: currentComparator)
                items = sortedItems
                isLoading = false

                if let pendingSelectionURL {
                    self.pendingSelectionURL = nil
                    let normalized = pendingSelectionURL.standardizedFileURL
                    selectedItems = sortedItems.contains(where: { $0.id == normalized }) ? [normalized] : []
                } else {
                    let availableIDs = Set(sortedItems.map(\.id))
                    selectedItems.formIntersection(availableIDs)
                }
            } catch is CancellationError {
                // A newer request owns the loading state.
            } catch {
                guard loadGeneration == requestGeneration, location == requestedLocation else { return }
                errorMessage = "Cannot load \(requestedLocation.title): \(error.localizedDescription)"
                items = []
                selectedItems.removeAll()
                isLoading = false
            }
        }
    }

    func refresh() {
        reload()
    }

    nonisolated static func sort(items: [FileItem], by field: SortField, ascending: Bool) -> [FileItem] {
        sort(items: items, using: FileItemComparator(field: field, order: ascending ? .forward : .reverse))
    }

    nonisolated static func sort(items: [FileItem], using comparator: FileItemComparator) -> [FileItem] {
        items.sorted { comparator.compare($0, $1) == .orderedAscending }
    }

    private nonisolated static func loadDirectory(at url: URL, includeHidden: Bool) async throws -> [FileItem] {
        let worker = Task.detached(priority: .userInitiated) {
            let urls = try FileManager.default.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: [
                    .isDirectoryKey, .fileSizeKey, .contentModificationDateKey,
                    .isHiddenKey, .isSymbolicLinkKey, .isPackageKey
                ],
                options: []
            )
            var items: [FileItem] = []
            items.reserveCapacity(urls.count)
            for (index, url) in urls.enumerated() {
                if index.isMultiple(of: 32) { try Task.checkCancellation() }
                let item = FileItem(url: url)
                if includeHidden || !item.isHidden {
                    items.append(item)
                }
            }
            try Task.checkCancellation()
            return items
        }
        return try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: {
            worker.cancel()
        }
    }

    private nonisolated static func makeItems(from urls: [URL], includeHidden: Bool) async throws -> [FileItem] {
        let worker = Task.detached(priority: .userInitiated) {
            var items: [FileItem] = []
            items.reserveCapacity(urls.count)
            for (index, url) in urls.enumerated() {
                if index.isMultiple(of: 32) { try Task.checkCancellation() }
                let item = FileItem(url: url)
                if includeHidden || !item.isHidden {
                    items.append(item)
                }
            }
            try Task.checkCancellation()
            return items
        }
        return try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: {
            worker.cancel()
        }
    }

    private func metadataURLs(for location: BrowserLocation, includeHidden: Bool) async throws -> [URL] {
        let query = NSMetadataQuery()

        switch location {
        case .recents:
            query.predicate = NSPredicate(
                format: "kMDItemContentModificationDate > %@",
                Date().addingTimeInterval(-7 * 24 * 60 * 60) as CVarArg
            )
        case .search(let search):
            let escaped = search.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !escaped.isEmpty else { return [] }
            query.predicate = NSPredicate(
                format: "kMDItemFSName CONTAINS[cd] %@ OR kMDItemTextContent CONTAINS[cd] %@",
                escaped,
                escaped
            )
            if let scope = search.scope {
                query.searchScopes = [scope.path]
            }
        case .directory:
            return []
        }

        query.sortDescriptors = [
            NSSortDescriptor(key: "kMDItemContentModificationDate", ascending: false)
        ]
        guard query.start() else {
            throw FileOperationError(message: "Spotlight could not start the query.")
        }
        defer { query.stop() }

        for _ in 0..<40 where query.isGathering {
            try Task.checkCancellation()
            try await Task.sleep(for: .milliseconds(50))
        }

        query.disableUpdates()
        var urls: [URL] = []
        urls.reserveCapacity(min(query.resultCount, 200))

        for index in 0..<min(query.resultCount, 200) {
            guard let item = query.result(at: index) as? NSMetadataItem,
                  let path = item.value(forAttribute: "kMDItemPath") as? String else { continue }
            let url = URL(fileURLWithPath: path).standardizedFileURL
            if !includeHidden && url.lastPathComponent.hasPrefix(".") { continue }
            if path.hasPrefix("/System/") || path.hasPrefix("/private/") { continue }
            urls.append(url)
        }
        return urls
    }

    // MARK: - Navigation

    func navigate(to url: URL) {
        let normalizedURL = url.standardizedFileURL
        do {
            let values = try normalizedURL.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
            if values.isDirectory == true && values.isPackage != true {
                navigate(to: .directory(normalizedURL))
            } else {
                NSWorkspace.shared.open(normalizedURL)
            }
        } catch {
            errorMessage = "Cannot open “\(normalizedURL.lastPathComponent)”: \(error.localizedDescription)"
        }
    }

    func navigate(to newLocation: BrowserLocation) {
        let normalizedLocation = Self.normalized(newLocation)
        guard normalizedLocation != location else {
            reload()
            return
        }
        backHistory.append(location)
        forwardHistory.removeAll()
        transition(to: normalizedLocation)
    }

    func navigateToFile(_ fileURL: URL) {
        let normalizedFileURL = fileURL.standardizedFileURL
        let parentURL = normalizedFileURL.deletingLastPathComponent()
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: parentURL.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            errorMessage = "The enclosing folder does not exist."
            return
        }

        pendingSelectionURL = normalizedFileURL
        let target = BrowserLocation.directory(parentURL)
        if target != location {
            backHistory.append(location)
            forwardHistory.removeAll()
            transition(to: target)
        } else {
            reload()
        }
    }

    func goBack() {
        guard let previous = backHistory.popLast() else { return }
        forwardHistory.append(location)
        transition(to: previous)
    }

    func goForward() {
        guard let next = forwardHistory.popLast() else { return }
        backHistory.append(location)
        transition(to: next)
    }

    func goUp() {
        guard let currentURL else { return }
        let parent = currentURL.deletingLastPathComponent()
        guard parent != currentURL else { return }
        navigate(to: .directory(parent))
    }

    func loadRecents() {
        navigate(to: .recents)
    }

    func search(for text: String, in scope: URL? = nil) {
        navigate(to: .search(SearchQuery(text: text, scope: scope)))
    }

    func openItem(_ item: FileItem) {
        if Self.shouldNavigateInto(item) {
            navigate(to: .directory(item.url))
        } else {
            NSWorkspace.shared.open(item.url)
        }
    }

    nonisolated static func shouldNavigateInto(_ item: FileItem) -> Bool {
        item.isDirectory && !item.isPackage
    }

    private func transition(to newLocation: BrowserLocation) {
        location = Self.normalized(newLocation)
        selectedItems.removeAll()
        items.removeAll()
        pendingSelectionURL = nil
        configureDirectoryMonitor()
        reload()
    }

    private static func normalized(_ location: BrowserLocation) -> BrowserLocation {
        switch location {
        case .directory(let url): return .directory(url.standardizedFileURL)
        case .recents: return .recents
        case .search(let query): return .search(SearchQuery(text: query.text, scope: query.scope))
        }
    }

    // MARK: - Sorting and visibility

    func toggleSort(by field: SortField) {
        let ascending = sortField == field ? !sortAscending : true
        sortOrder = [FileItemComparator(field: field, order: ascending ? .forward : .reverse)]
    }

    func toggleHiddenFiles() {
        showHiddenFiles.toggle()
    }

    // MARK: - Selection

    func selectForContextMenu(_ ids: Set<FileItem.ID>) {
        guard !ids.isEmpty else { return }
        selectedItems = ids
    }

    func selectAll() {
        selectedItems = Set(items.map(\.id))
    }

    // MARK: - File operations

    func newFolder() {
        guard let destination = currentURL else {
            errorMessage = "New folders can only be created inside a folder."
            return
        }
        operationService.createFolderDetailed(in: destination) { [weak self] result in
            if result.status == .completed {
                self?.pendingSelectionURL = result.completedOutcomes.first?.destination
            }
            self?.finishOperation(result)
        }
    }

    func deleteSelected() {
        let urls = selectedItemURLs
        guard !urls.isEmpty else { return }
        operationService.trashDetailed(urls) { [weak self] result in
            let completedSources = Set(result.completedOutcomes.map { $0.source.standardizedFileURL })
            self?.selectedItems.subtract(completedSources)
            self?.finishOperation(result)
        }
    }

    func rename(item: FileItem, to newName: String) {
        guard newName != item.name else { return }
        if let validationError = FileOperationService.validationError(forFileName: newName) {
            errorMessage = validationError
            return
        }

        let destination = item.url.deletingLastPathComponent().appendingPathComponent(newName)
        operationService.renameDetailed(item.url, to: destination) { [weak self] result in
            if result.status == .completed {
                self?.pendingSelectionURL = result.completedOutcomes.first?.destination
            }
            self?.finishOperation(result)
        }
    }

    func copyItems(from urls: [URL], conflictPolicy: FileConflictPolicy = .ask) {
        guard let destination = currentURL else {
            errorMessage = "Items can only be pasted inside a folder."
            return
        }
        operationService.copyDetailed(urls, to: destination, conflictPolicy: conflictPolicy) { [weak self] result in
            self?.finishOperation(result)
        }
    }

    func moveItems(
        from urls: [URL],
        conflictPolicy: FileConflictPolicy = .ask,
        completion: ((FileOperationResult) -> Void)? = nil
    ) {
        guard let destination = currentURL else {
            errorMessage = "Items can only be moved inside a folder."
            completion?(FileOperationResult(
                status: .failed,
                outcomes: [],
                errorMessage: "Items can only be moved inside a folder."
            ))
            return
        }
        operationService.moveDetailed(urls, to: destination, conflictPolicy: conflictPolicy) { [weak self] result in
            self?.finishOperation(result)
            completion?(result)
        }
    }

    func revealInFinder() {
        let urls = selectedItemURLs
        guard !urls.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    private func finishOperation(_ result: FileOperationResult) {
        if result.status != .completed {
            errorMessage = result.errorMessage ?? "The operation did not complete."
            reload(preservingError: true)
        } else {
            reload()
        }
    }

    // MARK: - Directory monitoring

    private func configureDirectoryMonitor() {
        monitorRefreshTask?.cancel()
        directoryMonitor.cancel()
        guard let currentURL else { return }
        directoryMonitor.watch(currentURL) { [weak self] in
            self?.scheduleMonitoredRefresh()
        }
    }

    private func scheduleMonitoredRefresh() {
        monitorRefreshTask?.cancel()
        monitorRefreshTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(350))
                guard !Task.isCancelled else { return }
                self?.reload(preservingError: true)
            } catch {
                // A subsequent filesystem event replaced this debounce task.
            }
        }
    }
}
