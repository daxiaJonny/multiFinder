import AppKit
import Combine
import Darwin
import Foundation
import SwiftUI

enum SortField: String, CaseIterable, Codable, Sendable {
    case name = "Name"
    case date = "Date Modified"
    case size = "Size"
    case kind = "Kind"

    var localizedName: String {
        switch self {
        case .name: L10n.string("Name")
        case .date: L10n.string("Date Modified")
        case .size: L10n.string("Size")
        case .kind: L10n.string("Kind")
        }
    }
}

enum FileDropOperation: Sendable, Equatable {
    case move
    case copy
}

@MainActor
final class FileBrowserViewModel: ObservableObject, Identifiable {
    let id = UUID()

    @Published private(set) var location: BrowserLocation
    @Published private(set) var items: [FileItem] = [] {
        didSet {
            visibleItemsCacheValid = false
            itemsRevision &+= 1
        }
    }
    /// Bumps only when `items` is replaced. Selection updates must not.
    @Published private(set) var itemsRevision: UInt64 = 0
    @Published private(set) var tableRevision: UInt64 = 0
    @Published var selectedItems: Set<FileItem.ID> = []
    @Published var filterText = "" {
        didSet {
            visibleItemsCacheValid = false
            let previousVisibleIDs = visibleItemIDs(in: items, filterText: oldValue)
            let currentVisibleIDs = visibleItemIDs(in: items, filterText: filterText)
            selectedItems.formIntersection(currentVisibleIDs)
            if previousVisibleIDs != currentVisibleIDs {
                tableRevision &+= 1
            }
        }
    }
    @Published var showsOnlyGitChanges = false {
        didSet {
            guard oldValue != showsOnlyGitChanges else { return }
            applyGitChangeFilter()
        }
    }
    @Published var sortOrder: [FileItemComparator] {
        didSet {
            guard let comparator = sortOrder.first else { return }
            items = Self.sort(items: items, using: comparator)
        }
    }
    @Published var viewMode: BrowserViewMode
    @Published var showHiddenFiles: Bool {
        didSet {
            if oldValue != showHiddenFiles {
                reload()
            }
        }
    }
    @Published private(set) var isLoading = false
    @Published var errorMessage: String?
    @Published var batchRenameItems: [FileItem]?
    @Published var isInfoPresented = false
    @Published var isSearchPresented = false
    @Published var isAIAssistantVisible = false
    @Published private(set) var isAIAnswering = false
    @Published private(set) var aiConversation: [AIAssistantExchange] = []
    @Published private(set) var aiPendingQuestion: String?
    @Published var aiAssistantErrorMessage: String?
    @Published var isAIOrganizePresented = false
    @Published private(set) var isAIPlanning = false
    @Published var aiOrganizeErrorMessage: String?
    @Published var aiPlanPreview: AIPlanPreview?

    private(set) var backHistory: [BrowserLocation]
    private(set) var forwardHistory: [BrowserLocation]

    var currentURL: URL? { location.directoryURL }
    var title: String { location.title }
    var pathDescription: String { location.pathDescription }
    var canGoBack: Bool { !backHistory.isEmpty }
    var canGoForward: Bool { !forwardHistory.isEmpty }
    var canGoUp: Bool {
        guard let url = currentURL else { return false }
        return url.deletingLastPathComponent().standardizedFileURL != url.standardizedFileURL
    }
    var canCreateItems: Bool {
        guard let currentURL else { return false }
        return Self.isWritableOrdinaryDirectory(currentURL)
    }
    var sortField: SortField { sortOrder.first?.field ?? .name }
    var sortAscending: Bool { sortOrder.first?.order != .reverse }

    var selectedItemURLs: [URL] {
        selectedFileItems.map(\.url)
    }

    var selectedFileItems: [FileItem] {
        items.filter { selectedItems.contains($0.id) }
    }

    var selectedItem: FileItem? {
        guard selectedItems.count == 1, let id = selectedItems.first else { return nil }
        return items.first { $0.id == id }
    }

    var visibleItems: [FileItem] {
        if !visibleItemsCacheValid {
            cachedVisibleItems = Self.visibleItems(
                in: items,
                filterText: filterText,
                restrictingTo: gitRestrictionIDs
            )
            visibleItemsCacheValid = true
        }
        return cachedVisibleItems
    }

    private var gitRestrictionIDs: Set<FileItem.ID>? {
        guard showsOnlyGitChanges, let currentURL else { return nil }
        guard let index = GitPulseStore.shared.cachedChangeIndex(for: currentURL) else { return nil }
        return Set(items.compactMap { item in
            index.changeType(for: item.url) == nil ? nil : item.id
        })
    }

    var isFiltering: Bool {
        !filterText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private let appSettings: AppSettings
    private let operationService: FileOperationService
    private let fileOpeningService: FileOpeningService
    private let aiPlanner: any AIPlanner
    private let aiQuestionAnswerer: any AIQuestionAnswering
    @Published private(set) var isAIAssistantAvailable: Bool
    private let directoryMonitor = DirectoryMonitor()
    private var loadTask: Task<Void, Never>?
    private var monitorRefreshTask: Task<Void, Never>?
    private var pendingMonitorURLs: [URL] = []
    private var aiPlanTask: Task<Void, Never>?
    private var aiAnswerTask: Task<Void, Never>?
    private var aiPlanRequestID: UUID?
    private var aiAnswerRequestID: UUID?
    private var settingsCancellable: AnyCancellable?
    private var loadGeneration: UInt64 = 0
    private var pendingSelectionURLs: Set<URL> = []
    private var gitStatusCancellable: AnyCancellable?
    private var gitPollingTask: Task<Void, Never>?
    private var lastGitFilteredIDs: Set<FileItem.ID> = []
    private var cachedVisibleItems: [FileItem] = []
    private var visibleItemsCacheValid = false

    init(
        location: BrowserLocation = .directory(FileManager.default.homeDirectoryForCurrentUser),
        sortField: SortField = .name,
        sortAscending: Bool = true,
        viewMode: BrowserViewMode = .list,
        showHiddenFiles: Bool? = nil,
        backHistory: [BrowserLocation] = [],
        forwardHistory: [BrowserLocation] = [],
        appSettings: AppSettings? = nil,
        operationService: FileOperationService = .shared,
        fileOpeningService: FileOpeningService = .shared,
        aiPlanner: any AIPlanner = CursorCLIPlanner.shared,
        aiQuestionAnswerer: any AIQuestionAnswering = CursorCLIPlanner.shared,
        aiPlannerAvailable: Bool? = nil
    ) {
        let appSettings = appSettings ?? .shared
        self.appSettings = appSettings
        self.location = Self.normalized(location)
        self.sortOrder = [FileItemComparator(field: sortField, order: sortAscending ? .forward : .reverse)]
        self.viewMode = viewMode
        self.showHiddenFiles = showHiddenFiles ?? appSettings.showHiddenFilesByDefault
        self.backHistory = backHistory.map(Self.normalized)
        self.forwardHistory = forwardHistory.map(Self.normalized)
        self.operationService = operationService
        self.fileOpeningService = fileOpeningService
        self.aiPlanner = aiPlanner
        self.aiQuestionAnswerer = aiQuestionAnswerer
        self.isAIAssistantAvailable = aiPlannerAvailable
            ?? Self.isExecutableCursorCLIPath(appSettings.cursorCLIExecutablePath)
        if aiPlannerAvailable == nil {
            settingsCancellable = appSettings.$cursorCLIExecutablePath
                .sink { [weak self] path in
                    self?.isAIAssistantAvailable = Self.isExecutableCursorCLIPath(path)
                }
        }
        configureDirectoryMonitor()
        gitPollingTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                guard let self else { return }
                GitPulseStore.shared.refresh(for: self.currentURL)
            }
        }
        gitStatusCancellable = GitPulseStore.shared.$cache
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.refreshGitChangeFilter()
            }
        reload()
    }

    convenience init(startURL: URL?) {
        self.init(location: .directory(startURL ?? FileManager.default.homeDirectoryForCurrentUser))
    }

    deinit {
        loadTask?.cancel()
        monitorRefreshTask?.cancel()
        gitPollingTask?.cancel()
        aiPlanTask?.cancel()
        aiAnswerTask?.cancel()
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
        GitPulseStore.shared.refresh(for: currentURL)

        loadTask = Task { [weak self] in
            guard let self else { return }
            do {
                let loadedItems: [FileItem]
                switch requestedLocation {
                case .directory(let url):
                    try await loadDirectoryProgressively(
                        at: url,
                        includeHidden: includeHidden,
                        generation: requestGeneration,
                        requestedLocation: requestedLocation
                    )
                    return
                case .recents, .search:
                    let urls = try await metadataURLs(for: requestedLocation, includeHidden: includeHidden)
                    try await publishURLsProgressively(
                        urls,
                        includeHidden: includeHidden,
                        generation: requestGeneration,
                        requestedLocation: requestedLocation
                    )
                    return
                case .aiSearch(let root, let criteria, _):
                    loadedItems = try await Self.loadAISearch(
                        root: root,
                        criteria: criteria,
                        includeHidden: includeHidden
                    )
                }

                try Task.checkCancellation()
                guard loadGeneration == requestGeneration, location == requestedLocation else { return }

                try await publishSortedItems(loadedItems, generation: requestGeneration, requestedLocation: requestedLocation)
                isLoading = false
            } catch is CancellationError {
                // A newer request owns the loading state.
            } catch {
                guard loadGeneration == requestGeneration, location == requestedLocation else { return }
                errorMessage = L10n.format(
                    "Cannot load %@: %@",
                    requestedLocation.title,
                    error.localizedDescription
                )
                selectedItems.removeAll()
                if !items.isEmpty {
                    tableRevision &+= 1
                }
                items = []
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

    /// Publishes names before reading metadata, retaining metadata already on screen.
    private func loadDirectoryProgressively(
        at url: URL,
        includeHidden: Bool,
        generation: UInt64,
        requestedLocation: BrowserLocation
    ) async throws {
        let existingItems = items
        let (visibleNames, placeholders) = try await FileBackgroundWork.run {
            let names = try FileManager.default.contentsOfDirectory(atPath: url.path)
            let visibleNames = includeHidden ? names : names.filter { !$0.hasPrefix(".") }
            let existing = Dictionary(existingItems.map { ($0.url, $0) }, uniquingKeysWith: { first, _ in first })
            var placeholders: [FileItem] = []
            placeholders.reserveCapacity(visibleNames.count)
            for (index, name) in visibleNames.enumerated() {
                if index.isMultiple(of: 64) { try Task.checkCancellation() }
                let item = existing[url.appendingPathComponent(name).standardizedFileURL]
                    ?? FileItem(named: name, in: url)
                if includeHidden || !item.isHidden { placeholders.append(item) }
            }
            return (visibleNames, placeholders)
        }
        try await publishSortedItems(placeholders, generation: generation, requestedLocation: requestedLocation, isComplete: false)
        let full = try await Self.makeFileItems(
            named: visibleNames,
            in: url,
            includeHidden: includeHidden
        )
        try await publishSortedItems(full, generation: generation, requestedLocation: requestedLocation)
        isLoading = false
    }

    private func publishURLsProgressively(
        _ urls: [URL],
        includeHidden: Bool,
        generation: UInt64,
        requestedLocation: BrowserLocation
    ) async throws {
        let firstCount = min(400, urls.count)
        let first = try await Self.makeItems(
            from: Array(urls.prefix(firstCount)),
            includeHidden: includeHidden
        )
        try await publishSortedItems(first, generation: generation, requestedLocation: requestedLocation, isComplete: firstCount == urls.count)
        guard firstCount < urls.count else {
            isLoading = false
            return
        }
        isLoading = true
        let rest = try await Self.makeItems(
            from: Array(urls.dropFirst(firstCount)),
            includeHidden: includeHidden
        )
        try await publishSortedItems(first + rest, generation: generation, requestedLocation: requestedLocation)
        isLoading = false
    }

    private func publishSortedItems(
        _ loadedItems: [FileItem],
        generation: UInt64,
        requestedLocation: BrowserLocation,
        isComplete: Bool = true
    ) async throws {
        while true {
            try Task.checkCancellation()
            guard loadGeneration == generation, location == requestedLocation else { throw CancellationError() }
            let comparator = sortOrder.first ?? FileItemComparator(field: .name)
            let sorted = try await Self.sorted(loadedItems, using: comparator)
            guard loadGeneration == generation, location == requestedLocation else { throw CancellationError() }
            // Sorting suspends the main actor; a newer sort preference wins before publication.
            guard comparator == (sortOrder.first ?? FileItemComparator(field: .name)) else { continue }
            applyLoadedItems(sorted, isComplete: isComplete)
            return
        }
    }

    private nonisolated static func sorted(
        _ items: [FileItem],
        using comparator: FileItemComparator
    ) async throws -> [FileItem] {
        try await FileBackgroundWork.run {
            var comparisons = 0
            return try items.sorted {
                comparisons += 1
                if comparisons.isMultiple(of: 256) { try Task.checkCancellation() }
                return comparator.compare($0, $1) == .orderedAscending
            }
        }
    }

    private nonisolated static func makeFileItems(
        named names: [String],
        in directory: URL,
        includeHidden: Bool
    ) async throws -> [FileItem] {
        try await FileBackgroundWork.run {
            var items: [FileItem] = []
            items.reserveCapacity(names.count)
            for (index, name) in names.enumerated() {
                if index.isMultiple(of: 64) { try Task.checkCancellation() }
                let item = FileItem(url: directory.appendingPathComponent(name))
                if includeHidden || !item.isHidden {
                    items.append(item)
                }
            }
            return items
        }
    }

    private nonisolated static func loadDirectory(at url: URL, includeHidden: Bool) async throws -> [FileItem] {
        let worker = Task.detached(priority: .userInitiated) {
            let urls = try FileManager.default.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: Array(FileItem.resourceKeys),
                options: []
            )
            return try Self.items(fromCachedResourceURLs: urls, includeHidden: includeHidden)
        }
        return try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: {
            worker.cancel()
        }
    }

    private nonisolated static func makeItems(from urls: [URL], includeHidden: Bool) async throws -> [FileItem] {
        let worker = Task.detached(priority: .userInitiated) {
            try Self.items(fromCachedResourceURLs: urls, includeHidden: includeHidden)
        }
        return try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: {
            worker.cancel()
        }
    }

    private nonisolated static func items(
        fromCachedResourceURLs urls: [URL],
        includeHidden: Bool
    ) throws -> [FileItem] {
        var items: [FileItem] = []
        items.reserveCapacity(urls.count)
        for (index, url) in urls.enumerated() {
            if index.isMultiple(of: 32) { try Task.checkCancellation() }
            let values = try? url.resourceValues(forKeys: FileItem.resourceKeys)
            let item = FileItem(url: url, resourceValues: values)
            if includeHidden || !item.isHidden {
                items.append(item)
            }
        }
        try Task.checkCancellation()
        return items
    }

    private func applyLoadedItems(_ loadedItems: [FileItem], isComplete: Bool = true) {
        if loadedItems == items, pendingSelectionURLs.isEmpty {
            return
        }
        let rowIdentityChanged = !items.elementsEqual(loadedItems) { $0.id == $1.id }
        let visibleIDs = visibleItemIDs(in: loadedItems, filterText: filterText)
        let nextSelection: Set<FileItem.ID>

        if pendingSelectionURLs.isEmpty {
            nextSelection = selectedItems.intersection(visibleIDs)
        } else {
            let pending = Set(pendingSelectionURLs.map(\.standardizedFileURL))
            if isComplete { pendingSelectionURLs.removeAll() }
            nextSelection = visibleIDs.intersection(pending)
        }

        // Keep Table's selection valid at every publication boundary. A renamed URL is a new row ID.
        // Metadata-only refreshes keep tableRevision so the SwiftUI table is not rebuilt.
        selectedItems.formIntersection(visibleIDs)
        if rowIdentityChanged {
            tableRevision &+= 1
        }
        items = loadedItems
        selectedItems = nextSelection
    }

    private func visibleItemIDs(in items: [FileItem], filterText: String) -> Set<FileItem.ID> {
        Set(Self.visibleItems(
            in: items,
            filterText: filterText,
            restrictingTo: gitRestrictionIDs
        ).map(\.id))
    }

    private func applyGitChangeFilter() {
        visibleItemsCacheValid = false
        let visible = visibleItemIDs(in: items, filterText: filterText)
        selectedItems.formIntersection(visible)
        lastGitFilteredIDs = visible
        tableRevision &+= 1
    }

    private func refreshGitChangeFilter() {
        guard showsOnlyGitChanges else { return }
        visibleItemsCacheValid = false
        let visible = visibleItemIDs(in: items, filterText: filterText)
        guard visible != lastGitFilteredIDs || !selectedItems.isSubset(of: visible) else { return }
        selectedItems.formIntersection(visible)
        lastGitFilteredIDs = visible
        tableRevision &+= 1
    }

    nonisolated static func visibleItems(
        in items: [FileItem],
        filterText: String,
        restrictingTo allowedIDs: Set<FileItem.ID>? = nil
    ) -> [FileItem] {
        let query = filterText.trimmingCharacters(in: .whitespacesAndNewlines)
        let nameFiltered: [FileItem]
        if query.isEmpty {
            nameFiltered = items
        } else {
            nameFiltered = items.filter { item in
                item.name.range(
                    of: query,
                    options: [.caseInsensitive, .diacriticInsensitive],
                    locale: .current
                ) != nil
            }
        }
        guard let allowedIDs else { return nameFiltered }
        return nameFiltered.filter { allowedIDs.contains($0.id) }
    }

    private nonisolated static func loadAISearch(
        root: URL,
        criteria: AISearchCriteria,
        includeHidden: Bool
    ) async throws -> [FileItem] {
        let matcher = AISearchMatcher(criteria: criteria)
        let worker = Task.detached(priority: .userInitiated) {
            try Self.enumerateAISearch(root: root, matcher: matcher, includeHidden: includeHidden)
        }
        return try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: {
            worker.cancel()
        }
    }

    private nonisolated static func enumerateAISearch(
        root: URL,
        matcher: AISearchMatcher,
        includeHidden: Bool
    ) throws -> [FileItem] {
        var options: FileManager.DirectoryEnumerationOptions = [.skipsPackageDescendants]
        if !includeHidden { options.insert(.skipsHiddenFiles) }
        if !matcher.isRecursive { options.insert(.skipsSubdirectoryDescendants) }

        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [
                .isDirectoryKey, .fileSizeKey, .contentModificationDateKey,
                .isHiddenKey, .isSymbolicLinkKey, .isPackageKey
            ],
            options: options
        ) else {
            throw FileOperationError(
                message: L10n.format("The folder “%@” could not be searched.", root.lastPathComponent)
            )
        }

        var items: [FileItem] = []
        var scanned = 0
        for case let url as URL in enumerator {
            if scanned.isMultiple(of: 32) { try Task.checkCancellation() }
            scanned += 1
            let item = FileItem(url: url)
            if matcher.matches(item) {
                items.append(item)
            }
        }
        try Task.checkCancellation()
        return items
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
        case .directory, .aiSearch:
            return []
        }

        query.sortDescriptors = [
            NSSortDescriptor(key: "kMDItemContentModificationDate", ascending: false)
        ]
        guard query.start() else {
            throw FileOperationError(message: L10n.string("Spotlight could not start the query."))
        }
        defer { query.stop() }

        while query.isGathering {
            try Task.checkCancellation()
            try await Task.sleep(for: .milliseconds(50))
        }

        query.disableUpdates()
        var urls: [URL] = []
        urls.reserveCapacity(query.resultCount)

        for index in 0..<query.resultCount {
            if index.isMultiple(of: 64) { try Task.checkCancellation() }
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
            errorMessage = L10n.format(
                "Cannot open “%@”: %@",
                normalizedURL.lastPathComponent,
                error.localizedDescription
            )
        }
    }

    func navigate(to newLocation: BrowserLocation) {
        let normalizedLocation = Self.normalized(newLocation)
        clearFilter()
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
        var targetIsDirectory: ObjCBool = false
        guard FileManager.default.fileExists(
            atPath: normalizedFileURL.path,
            isDirectory: &targetIsDirectory
        ) else {
            let name = normalizedFileURL.lastPathComponent.isEmpty
                ? normalizedFileURL.path
                : normalizedFileURL.lastPathComponent
            errorMessage = L10n.format("“%@” does not exist.", name)
            return
        }

        if targetIsDirectory.boolValue {
            navigate(to: normalizedFileURL)
            return
        }

        _ = revealFiles([normalizedFileURL])
    }

    @discardableResult
    func revealFiles(_ fileURLs: [URL]) -> Bool {
        let normalizedFileURLs = Self.uniqueStandardizedURLs(fileURLs)
        guard !normalizedFileURLs.isEmpty else { return false }

        var parentURL: URL?
        for normalizedFileURL in normalizedFileURLs {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(
                atPath: normalizedFileURL.path,
                isDirectory: &isDirectory
            ), !isDirectory.boolValue || (try? normalizedFileURL.resourceValues(forKeys: [.isPackageKey]).isPackage) == true else {
                return false
            }

            let candidateParentURL = normalizedFileURL.deletingLastPathComponent().standardizedFileURL
            var parentIsDirectory: ObjCBool = false
            guard FileManager.default.fileExists(
                atPath: candidateParentURL.path,
                isDirectory: &parentIsDirectory
            ), parentIsDirectory.boolValue else {
                errorMessage = L10n.string("The enclosing folder does not exist.")
                return false
            }

            if let parentURL {
                guard parentURL == candidateParentURL else { return false }
            } else {
                parentURL = candidateParentURL
            }
        }

        guard let parentURL else { return false }

        let target = BrowserLocation.directory(parentURL)
        if target != location {
            backHistory.append(location)
            forwardHistory.removeAll()
            transition(to: target, pendingSelection: Set(normalizedFileURLs))
        } else {
            clearFilter()
            pendingSelectionURLs = Set(normalizedFileURLs)
            reload()
        }
        return true
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
        let parent = currentURL.deletingLastPathComponent().standardizedFileURL
        guard parent != currentURL.standardizedFileURL else { return }
        navigate(to: .directory(parent))
    }

    func loadRecents() {
        navigate(to: .recents)
    }

    func search(for text: String, in scope: URL? = nil) {
        navigate(to: .search(SearchQuery(text: text, scope: scope)))
    }

    func openItem(_ item: FileItem) {
        let item = item.isMetadataLoaded ? item : FileItem(url: item.url)
        if Self.shouldNavigateInto(item) {
            navigate(to: .directory(item.url))
        } else if let applicationURL = fileOpeningService.preferredTextEditorURL(for: item.url) {
            openItems([item.url], withApplicationAt: applicationURL)
        } else {
            guard NSWorkspace.shared.open(item.url) else {
                errorMessage = L10n.format("Could not open “%@”.", item.name)
                return
            }
        }
    }

    func openSelectedItems() {
        selectedFileItems.forEach(openItem)
    }

    func openItems(_ urls: [URL], withApplicationAt applicationURL: URL) {
        guard !urls.isEmpty else { return }
        let configuration = NSWorkspace.OpenConfiguration()
        NSWorkspace.shared.open(
            urls,
            withApplicationAt: applicationURL,
            configuration: configuration
        ) { [weak self] _, error in
            guard let error else { return }
            Task { @MainActor [weak self] in
                let applicationName = applicationURL.deletingPathExtension().lastPathComponent
                self?.errorMessage = L10n.format(
                    "Could not open the file with “%@”: %@",
                    applicationName,
                    error.localizedDescription
                )
            }
        }
    }

    nonisolated static func shouldNavigateInto(_ item: FileItem) -> Bool {
        item.isDirectory && !item.isPackage
    }

    private func transition(to newLocation: BrowserLocation, pendingSelection: Set<URL> = []) {
        clearFilter()
        cancelAIAnswering()
        cancelAIPlanning()
        aiConversation.removeAll()
        aiAssistantErrorMessage = nil
        aiOrganizeErrorMessage = nil
        aiPlanPreview = nil
        isAIOrganizePresented = false
        isInfoPresented = false
        if newLocation.directoryURL == nil {
            isAIAssistantVisible = false
        }
        location = Self.normalized(newLocation)
        selectedItems.removeAll()
        if !items.isEmpty {
            tableRevision &+= 1
        }
        items.removeAll()
        pendingSelectionURLs = pendingSelection
        configureDirectoryMonitor()
        reload()
    }

    private nonisolated static func uniqueStandardizedURLs(_ urls: [URL]) -> [URL] {
        var seen = Set<URL>()
        return urls.map(\.standardizedFileURL).filter { seen.insert($0).inserted }
    }

    private static func normalized(_ location: BrowserLocation) -> BrowserLocation {
        switch location {
        case .directory(let url): return .directory(url.standardizedFileURL)
        case .recents: return .recents
        case .search(let query): return .search(SearchQuery(text: query.text, scope: query.scope))
        case .aiSearch(let root, let criteria, let title):
            return .aiSearch(root: root.standardizedFileURL, criteria: criteria, title: title)
        }
    }

    private static func isExecutableCursorCLIPath(_ path: String) -> Bool {
        return FileManager.default.isExecutableFile(
            atPath: AppSettings.resolvedCursorCLIExecutableURL(from: path).path
        )
    }

    // MARK: - Sorting and visibility

    func toggleSort(by field: SortField) {
        let ascending = sortField == field ? !sortAscending : true
        setSort(by: field, ascending: ascending)
    }

    func setSort(by field: SortField, ascending: Bool) {
        sortOrder = [FileItemComparator(field: field, order: ascending ? .forward : .reverse)]
    }

    func toggleHiddenFiles() {
        showHiddenFiles.toggle()
    }

    func clearFilter() {
        filterText = ""
    }

    // MARK: - Selection

    func selectForContextMenu(_ ids: Set<FileItem.ID>) {
        guard !ids.isEmpty else { return }
        selectedItems = ids
    }

    func selectAll() {
        selectedItems = Set(visibleItems.map(\.id))
    }

    func pasteDestination(for selection: Set<FileItem.ID>) -> URL? {
        let contextItems = items.filter { selection.contains($0.id) }
        if contextItems.count == 1, let contextItem = contextItems.first, contextItem.isDirectory {
            guard Self.isWritableOrdinaryDirectory(contextItem.url) else { return nil }
            return contextItem.url.standardizedFileURL
        }

        guard let currentURL, Self.isWritableOrdinaryDirectory(currentURL) else { return nil }
        return currentURL.standardizedFileURL
    }

    nonisolated static func isWritableOrdinaryDirectory(_ url: URL) -> Bool {
        let normalizedURL = url.standardizedFileURL
        guard let values = try? normalizedURL.resourceValues(
            forKeys: [.isDirectoryKey, .isPackageKey, .isSymbolicLinkKey]
        ), values.isDirectory == true,
        values.isPackage != true,
        values.isSymbolicLink != true else {
            return false
        }
        return FileManager.default.isWritableFile(atPath: normalizedURL.path)
    }

    func presentInfo() {
        guard !selectedItems.isEmpty else { return }
        isInfoPresented = true
    }

    // MARK: - File operations

    func newFolder() {
        guard let destination = currentURL else {
            errorMessage = L10n.string("New folders can only be created inside a folder.")
            return
        }
        operationService.createFolderDetailed(in: destination) { [weak self] result in
            self?.finishOperation(result, selectingCompletedDestinations: true)
        }
    }

    func createFile(_ template: NewFileTemplate) {
        guard let destination = currentURL else {
            errorMessage = L10n.string("New files can only be created inside a folder.")
            return
        }
        operationService.createFileDetailed(in: destination, template: template) { [weak self] result in
            self?.finishOperation(result, selectingCompletedDestinations: true)
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
            self?.finishOperation(result, selectingCompletedDestinations: true)
        }
    }

    func requestBatchRename() {
        let selection = selectedFileItems
        guard selection.count >= 2 else { return }
        guard let parent = selection.first?.url.deletingLastPathComponent(),
              selection.allSatisfy({ $0.url.deletingLastPathComponent() == parent }) else {
            errorMessage = L10n.string("Items can only be renamed together when they are in the same folder.")
            return
        }
        batchRenameItems = selection
    }

    func batchRename(_ pairs: [BatchRenamePair]) {
        guard !pairs.isEmpty else { return }
        operationService.batchRenameDetailed(pairs) { [weak self] result in
            self?.finishOperation(result, selectingCompletedDestinations: true)
        }
    }

    func compressItems(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        operationService.compressDetailed(urls) { [weak self] result in
            self?.finishOperation(result, selectingCompletedDestinations: true)
        }
    }

    func extractItems(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        operationService.extractDetailed(urls) { [weak self] result in
            self?.finishOperation(result, selectingCompletedDestinations: true)
        }
    }

    func duplicateSelected() {
        let urls = selectedItemURLs
        guard !urls.isEmpty else { return }
        copyItems(from: urls, conflictPolicy: .keepBoth)
    }

    func copyItems(
        from urls: [URL],
        to requestedDestination: URL? = nil,
        conflictPolicy: FileConflictPolicy = .ask,
        completion: ((FileOperationResult) -> Void)? = nil
    ) {
        guard let destination = requestedDestination ?? currentURL,
              Self.isWritableOrdinaryDirectory(destination) else {
            let message = L10n.string("Items can only be pasted inside a folder.")
            errorMessage = message
            completion?(FileOperationResult(status: .failed, outcomes: [], errorMessage: message))
            return
        }
        operationService.copyDetailed(urls, to: destination, conflictPolicy: conflictPolicy) { [weak self] result in
            self?.finishOperation(result, selectingCompletedDestinations: true)
            completion?(result)
        }
    }

    func moveItems(
        from urls: [URL],
        to requestedDestination: URL? = nil,
        conflictPolicy: FileConflictPolicy = .ask,
        completion: ((FileOperationResult) -> Void)? = nil
    ) {
        guard let destination = requestedDestination ?? currentURL,
              Self.isWritableOrdinaryDirectory(destination) else {
            let message = L10n.string("Items can only be moved inside a folder.")
            errorMessage = message
            completion?(FileOperationResult(
                status: .failed,
                outcomes: [],
                errorMessage: message
            ))
            return
        }
        operationService.moveDetailed(urls, to: destination, conflictPolicy: conflictPolicy) { [weak self] result in
            self?.finishOperation(result, selectingCompletedDestinations: true)
            completion?(result)
        }
    }

    @discardableResult
    func transferDroppedItems(
        _ urls: [URL],
        into destination: URL,
        operation: FileDropOperation
    ) -> Bool {
        let destination = destination.standardizedFileURL
        guard Self.isDirectory(destination) else { return false }

        let effectiveOperation: FileDropOperation
        switch operation {
        case .copy:
            effectiveOperation = .copy
        case .move:
            effectiveOperation = Self.dropOperation(
                for: urls,
                into: destination,
                optionPressed: false
            )
        }

        let sources = Self.validDropSources(urls, into: destination, operation: effectiveOperation)
        guard !sources.isEmpty else { return false }

        let completion: (FileOperationResult) -> Void = { [weak self] result in
            self?.finishOperation(result, selectingCompletedDestinations: true)
        }
        switch effectiveOperation {
        case .move:
            operationService.moveDetailed(sources, to: destination, completion: completion)
        case .copy:
            operationService.copyDetailed(sources, to: destination, completion: completion)
        }
        return true
    }

    nonisolated static func dropOperation(
        for sourceURLs: [URL],
        into destination: URL,
        optionPressed: Bool
    ) -> FileDropOperation {
        guard !optionPressed, !sourceURLs.isEmpty,
              let destinationVolume = volumeIdentifier(for: destination) else {
            return .copy
        }

        guard sourceURLs.allSatisfy({ volumeIdentifier(for: $0) == destinationVolume }) else {
            return .copy
        }
        return .move
    }

    static func validDropSources(
        _ urls: [URL],
        into destination: URL,
        operation: FileDropOperation
    ) -> [URL] {
        let destination = destination.standardizedFileURL
        var seen: Set<URL> = []
        let sources = urls.compactMap { url -> URL? in
            let source = url.standardizedFileURL
            return seen.insert(source).inserted ? source : nil
        }

        guard sources.allSatisfy({ source in
            guard source != destination,
                  !FileDropSafety.isProtectedSource(source) else { return false }

            if operation == .move,
               source.deletingLastPathComponent().standardizedFileURL == destination {
                return false
            }

            if Self.isRealDirectory(source),
               Self.isDescendant(destination, of: source) {
                return false
            }
            return true
        }) else { return [] }

        return sources
    }

    static func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    }

    private static func isRealDirectory(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]) else {
            return false
        }
        return values.isDirectory == true && values.isSymbolicLink != true
    }

    private static func isDescendant(_ candidate: URL, of ancestor: URL) -> Bool {
        let ancestorComponents = ancestor.standardizedFileURL.pathComponents
        let candidateComponents = candidate.standardizedFileURL.pathComponents
        guard candidateComponents.count > ancestorComponents.count else { return false }
        return candidateComponents.prefix(ancestorComponents.count).elementsEqual(ancestorComponents)
    }

    private nonisolated static func volumeIdentifier(for url: URL) -> UInt64? {
        var metadata = stat()
        let result = url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return Int32(-1) }
            return lstat(path, &metadata)
        }
        guard result == 0 else { return nil }
        return UInt64(metadata.st_dev)
    }

    func revealInFinder() {
        let urls = selectedItemURLs
        guard !urls.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    // MARK: - Search and AI

    struct AIPlanPreview: Identifiable {
        let id = UUID()
        let plan: AIPlan
        let validation: PlanValidationResult
        let scopeRoot: URL
    }

    func toggleAIAssistant() {
        guard isAIAssistantAvailable, currentURL != nil else { return }
        isAIAssistantVisible.toggle()
        if !isAIAssistantVisible {
            cancelAIAnswering()
            aiAssistantErrorMessage = nil
        }
    }

    func presentSearch() {
        isSearchPresented = true
    }

    func presentAIOrganize() {
        guard isAIAssistantAvailable, currentURL != nil else { return }
        aiPlanPreview = nil
        aiOrganizeErrorMessage = nil
        isAIOrganizePresented = true
    }

    func dismissAIOrganize() {
        cancelAIPlanning()
        aiPlanPreview = nil
        aiOrganizeErrorMessage = nil
        isAIOrganizePresented = false
    }

    func submitAIQuestion(_ question: String) {
        let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isAIAnswering else { return }
        guard let scopeRoot = currentURL else {
            aiAssistantErrorMessage = L10n.string("Open a folder before asking a question.")
            return
        }

        aiAnswerTask?.cancel()
        let requestID = UUID()
        aiAnswerRequestID = requestID
        isAIAnswering = true
        aiPendingQuestion = trimmed
        aiAssistantErrorMessage = nil
        let answerer = aiQuestionAnswerer
        let previousExchanges = Array(aiConversation.suffix(6))

        aiAnswerTask = Task { [weak self] in
            defer { self?.finishAIAnswering(requestID: requestID) }
            do {
                let answer = try await answerer.answer(AIAssistantRequest(
                    question: trimmed,
                    scopeRoot: scopeRoot,
                    previousExchanges: previousExchanges
                ))
                try Task.checkCancellation()
                guard let self, self.aiAnswerRequestID == requestID else { return }
                self.aiConversation.append(AIAssistantExchange(question: trimmed, answer: answer))
            } catch is CancellationError {
                return
            } catch {
                guard let self,
                      !Task.isCancelled,
                      self.aiAnswerRequestID == requestID else { return }
                self.aiAssistantErrorMessage = error.localizedDescription
            }
        }
    }

    func cancelAIAnswering() {
        aiAnswerTask?.cancel()
        aiAnswerTask = nil
        aiAnswerRequestID = nil
        isAIAnswering = false
        aiPendingQuestion = nil
    }

    func clearAIConversation() {
        cancelAIAnswering()
        aiConversation.removeAll()
        aiAssistantErrorMessage = nil
    }

    func submitAIOrganizeInstruction(_ instruction: String) {
        let trimmed = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isAIPlanning else { return }
        guard let scopeRoot = currentURL else {
            aiOrganizeErrorMessage = L10n.string("Open a folder before using AI Organize.")
            return
        }

        aiPlanTask?.cancel()
        let requestID = UUID()
        aiPlanRequestID = requestID
        isAIPlanning = true
        aiOrganizeErrorMessage = nil
        aiPlanPreview = nil
        let planner = aiPlanner

        aiPlanTask = Task { [weak self] in
            defer { self?.finishAIPlanning(requestID: requestID) }
            do {
                let plan = try await planner.plan(AIPlanRequest(instruction: trimmed, scopeRoot: scopeRoot))
                try Task.checkCancellation()
                guard let self, self.aiPlanRequestID == requestID else { return }
                self.handleAIOrganizePlan(plan, scopeRoot: scopeRoot)
            } catch is CancellationError {
                return
            } catch {
                guard let self,
                      !Task.isCancelled,
                      self.aiPlanRequestID == requestID else { return }
                self.aiOrganizeErrorMessage = error.localizedDescription
            }
        }
    }

    func cancelAIPlanning() {
        aiPlanTask?.cancel()
        aiPlanTask = nil
        aiPlanRequestID = nil
        isAIPlanning = false
    }

    func executeAIPlan(_ operations: [AIPlanOperation], scopeRoot: URL) {
        guard !operations.isEmpty else { return }
        operationService.aiOrganizeDetailed(operations, scopeRoot: scopeRoot) { [weak self] result in
            self?.finishOperation(result, selectingCompletedDestinations: true)
        }
    }

    private func handleAIOrganizePlan(_ plan: AIPlan, scopeRoot: URL) {
        guard plan.kind == .organize else {
            aiOrganizeErrorMessage = L10n.string(
                "AI returned search results instead of a file organization plan."
            )
            return
        }
        do {
            let validation = try PlanValidator.validate(plan, scopeRoot: scopeRoot)
            aiPlanPreview = AIPlanPreview(plan: plan, validation: validation, scopeRoot: scopeRoot)
        } catch {
            aiOrganizeErrorMessage = error.localizedDescription
        }
    }

    private func finishAIAnswering(requestID: UUID) {
        guard aiAnswerRequestID == requestID else { return }
        aiAnswerTask = nil
        aiAnswerRequestID = nil
        isAIAnswering = false
        aiPendingQuestion = nil
    }

    private func finishAIPlanning(requestID: UUID) {
        guard aiPlanRequestID == requestID else { return }
        aiPlanTask = nil
        aiPlanRequestID = nil
        isAIPlanning = false
    }

    private func finishOperation(
        _ result: FileOperationResult,
        selectingCompletedDestinations: Bool = false
    ) {
        if selectingCompletedDestinations {
            prepareCompletedSelection(from: result)
        }
        if result.status != .completed {
            errorMessage = result.errorMessage ?? L10n.string("The operation did not complete.")
            reload(preservingError: true)
        } else {
            reload()
        }
    }

    private func prepareCompletedSelection(from result: FileOperationResult) {
        guard let currentURL = currentURL?.standardizedFileURL else { return }
        let destinations = Set(result.completedOutcomes.compactMap { outcome -> URL? in
            guard let destination = outcome.destination?.standardizedFileURL,
                  destination.deletingLastPathComponent().standardizedFileURL == currentURL else {
                return nil
            }
            return destination
        })
        guard !destinations.isEmpty else { return }
        clearFilter()
        pendingSelectionURLs = destinations
    }

    // MARK: - Directory monitoring

    private func configureDirectoryMonitor() {
        monitorRefreshTask?.cancel()
        directoryMonitor.cancel()
        guard let currentURL else { return }
        directoryMonitor.watch(currentURL) { [weak self] urls in
            self?.scheduleMonitoredRefresh(urls)
        }
    }

    private func scheduleMonitoredRefresh(_ urls: [URL]) {
        pendingMonitorURLs.append(contentsOf: urls)
        monitorRefreshTask?.cancel()
        monitorRefreshTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(250))
                guard let self, !Task.isCancelled else { return }
                let batch = self.pendingMonitorURLs
                self.pendingMonitorURLs.removeAll()
                self.applyMonitoredChanges(batch)
            } catch {
                // A subsequent filesystem event replaced this debounce task.
            }
        }
    }

    /// Updates only the children named by file events. A bare directory event falls back to a name diff.
    private func applyMonitoredChanges(_ urls: [URL]) {
        guard case .directory(let current) = location else {
            reload(preservingError: true)
            return
        }
        let directory = current.standardizedFileURL
        let children = Array(Set(urls.map(\.standardizedFileURL).filter {
            $0.deletingLastPathComponent().standardizedFileURL == directory
        }))
        if children.isEmpty {
            applyNameDiff(in: directory)
            return
        }
        var next = items
        var changed = false
        for child in children {
            let exists = FileManager.default.fileExists(atPath: child.path)
            if !exists {
                let before = next.count
                next.removeAll { $0.url.standardizedFileURL == child }
                changed = changed || next.count != before
                continue
            }
            let item = FileItem(url: child)
            if !showHiddenFiles && item.isHidden {
                let before = next.count
                next.removeAll { $0.url.standardizedFileURL == child }
                changed = changed || next.count != before
                continue
            }
            if let index = next.firstIndex(where: { $0.url.standardizedFileURL == child }) {
                if next[index] != item {
                    next[index] = item
                    changed = true
                }
            } else {
                next.append(item)
                changed = true
            }
        }
        guard changed else { return }
        let comparator = sortOrder.first ?? FileItemComparator(field: .name)
        applyLoadedItems(Self.sort(items: next, using: comparator))
    }

    private func applyNameDiff(in directory: URL) {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else {
            reload(preservingError: true)
            return
        }
        let allowed = Set(showHiddenFiles ? names : names.filter { !$0.hasPrefix(".") })
        let existingNames = Set(items.map(\.name))
        guard allowed != existingNames else { return }
        var next: [FileItem] = []
        next.reserveCapacity(allowed.count)
        let existing = Dictionary(items.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        for name in allowed {
            if let item = existing[name] {
                next.append(item)
            } else {
                let item = FileItem(url: directory.appendingPathComponent(name))
                if showHiddenFiles || !item.isHidden {
                    next.append(item)
                }
            }
        }
        let comparator = sortOrder.first ?? FileItemComparator(field: .name)
        applyLoadedItems(Self.sort(items: next, using: comparator))
    }
}
