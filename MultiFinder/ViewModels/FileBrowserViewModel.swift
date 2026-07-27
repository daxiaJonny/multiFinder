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

enum FileDropOperation: Sendable, Equatable {
    case move
    case copy
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
    @Published var batchRenameItems: [FileItem]?
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
        return url.deletingLastPathComponent() != url
    }
    var canCreateItems: Bool { location.supportsCreatingItems }
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

    private let operationService: FileOperationService
    private let aiPlanner: any AIPlanner
    private let aiQuestionAnswerer: any AIQuestionAnswering
    let isAIAssistantAvailable: Bool
    private let directoryMonitor = DirectoryMonitor()
    private var loadTask: Task<Void, Never>?
    private var monitorRefreshTask: Task<Void, Never>?
    private var aiPlanTask: Task<Void, Never>?
    private var aiAnswerTask: Task<Void, Never>?
    private var loadGeneration: UInt64 = 0
    private var pendingSelectionURL: URL?

    init(
        location: BrowserLocation = .directory(FileManager.default.homeDirectoryForCurrentUser),
        sortField: SortField = .name,
        sortAscending: Bool = true,
        showHiddenFiles: Bool = false,
        backHistory: [BrowserLocation] = [],
        forwardHistory: [BrowserLocation] = [],
        operationService: FileOperationService = .shared,
        aiPlanner: any AIPlanner = CursorCLIPlanner.shared,
        aiQuestionAnswerer: any AIQuestionAnswering = CursorCLIPlanner.shared,
        aiPlannerAvailable: Bool = CursorCLIPlanner.shared.isAvailable
    ) {
        self.location = Self.normalized(location)
        self.sortOrder = [FileItemComparator(field: sortField, order: sortAscending ? .forward : .reverse)]
        self.showHiddenFiles = showHiddenFiles
        self.backHistory = backHistory.map(Self.normalized)
        self.forwardHistory = forwardHistory.map(Self.normalized)
        self.operationService = operationService
        self.aiPlanner = aiPlanner
        self.aiQuestionAnswerer = aiQuestionAnswerer
        self.isAIAssistantAvailable = aiPlannerAvailable
        configureDirectoryMonitor()
        reload()
    }

    convenience init(startURL: URL?) {
        self.init(location: .directory(startURL ?? FileManager.default.homeDirectoryForCurrentUser))
    }

    deinit {
        loadTask?.cancel()
        monitorRefreshTask?.cancel()
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
                case .aiSearch(let root, let criteria, _):
                    loadedItems = try await Self.loadAISearch(
                        root: root,
                        criteria: criteria,
                        includeHidden: includeHidden
                    )
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
            throw FileOperationError(message: "The folder “\(root.lastPathComponent)” could not be searched.")
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
        cancelAIAnswering()
        cancelAIPlanning()
        aiConversation.removeAll()
        aiAssistantErrorMessage = nil
        aiOrganizeErrorMessage = nil
        aiPlanPreview = nil
        isAIOrganizePresented = false
        if newLocation.directoryURL == nil {
            isAIAssistantVisible = false
        }
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
        case .aiSearch(let root, let criteria, let title):
            return .aiSearch(root: root.standardizedFileURL, criteria: criteria, title: title)
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

    func requestBatchRename() {
        let selection = selectedFileItems
        guard selection.count >= 2 else { return }
        guard let parent = selection.first?.url.deletingLastPathComponent(),
              selection.allSatisfy({ $0.url.deletingLastPathComponent() == parent }) else {
            errorMessage = "Items can only be renamed together when they are in the same folder."
            return
        }
        batchRenameItems = selection
    }

    func batchRename(_ pairs: [BatchRenamePair]) {
        guard !pairs.isEmpty else { return }
        operationService.batchRenameDetailed(pairs) { [weak self] result in
            self?.finishOperation(result)
        }
    }

    func compressItems(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        operationService.compressDetailed(urls) { [weak self] result in
            if result.status == .completed {
                self?.pendingSelectionURL = result.completedOutcomes.first?.destination
            }
            self?.finishOperation(result)
        }
    }

    func extractItems(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        operationService.extractDetailed(urls) { [weak self] result in
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

    @discardableResult
    func transferDroppedItems(
        _ urls: [URL],
        into destination: URL,
        operation: FileDropOperation
    ) -> Bool {
        let destination = destination.standardizedFileURL
        guard Self.isDirectory(destination) else { return false }

        let sources = Self.validDropSources(urls, into: destination, operation: operation)
        guard !sources.isEmpty else { return false }

        let completion: (FileOperationResult) -> Void = { [weak self] result in
            self?.finishOperation(result)
        }
        switch operation {
        case .move:
            operationService.moveDetailed(sources, to: destination, completion: completion)
        case .copy:
            operationService.copyDetailed(sources, to: destination, completion: completion)
        }
        return true
    }

    static func validDropSources(
        _ urls: [URL],
        into destination: URL,
        operation: FileDropOperation
    ) -> [URL] {
        let destination = destination.standardizedFileURL
        var seen: Set<URL> = []

        return urls.compactMap { url in
            let source = url.standardizedFileURL
            guard seen.insert(source).inserted,
                  source != destination,
                  !FileDropSafety.isProtectedSource(source) else { return nil }

            if operation == .move,
               source.deletingLastPathComponent().standardizedFileURL == destination {
                return nil
            }

            if Self.isRealDirectory(source),
               Self.isDescendant(destination, of: source) {
                return nil
            }
            return source
        }
    }

    private static func isDirectory(_ url: URL) -> Bool {
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
            aiAssistantErrorMessage = "请先打开一个文件夹再提问。"
            return
        }

        aiAnswerTask?.cancel()
        isAIAnswering = true
        aiPendingQuestion = trimmed
        aiAssistantErrorMessage = nil
        let answerer = aiQuestionAnswerer
        let previousExchanges = Array(aiConversation.suffix(6))

        aiAnswerTask = Task { [weak self] in
            defer {
                self?.isAIAnswering = false
                self?.aiPendingQuestion = nil
            }
            do {
                let answer = try await answerer.answer(AIAssistantRequest(
                    question: trimmed,
                    scopeRoot: scopeRoot,
                    previousExchanges: previousExchanges
                ))
                try Task.checkCancellation()
                self?.aiConversation.append(AIAssistantExchange(question: trimmed, answer: answer))
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                self?.aiAssistantErrorMessage = error.localizedDescription
            }
        }
    }

    func cancelAIAnswering() {
        aiAnswerTask?.cancel()
        aiAnswerTask = nil
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
            aiOrganizeErrorMessage = "请先打开一个文件夹再使用 AI 整理。"
            return
        }

        aiPlanTask?.cancel()
        isAIPlanning = true
        aiOrganizeErrorMessage = nil
        aiPlanPreview = nil
        let planner = aiPlanner

        aiPlanTask = Task { [weak self] in
            defer { self?.isAIPlanning = false }
            do {
                let plan = try await planner.plan(AIPlanRequest(instruction: trimmed, scopeRoot: scopeRoot))
                try Task.checkCancellation()
                self?.handleAIOrganizePlan(plan, scopeRoot: scopeRoot)
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                self?.aiOrganizeErrorMessage = error.localizedDescription
            }
        }
    }

    func cancelAIPlanning() {
        aiPlanTask?.cancel()
        aiPlanTask = nil
        isAIPlanning = false
    }

    func executeAIPlan(_ operations: [AIPlanOperation], scopeRoot: URL) {
        guard !operations.isEmpty else { return }
        operationService.aiOrganizeDetailed(operations, scopeRoot: scopeRoot) { [weak self] result in
            self?.finishOperation(result)
        }
    }

    private func handleAIOrganizePlan(_ plan: AIPlan, scopeRoot: URL) {
        guard plan.kind == .organize else {
            aiOrganizeErrorMessage = "AI 返回了搜索结果，而不是文件整理方案。"
            return
        }
        do {
            let validation = try PlanValidator.validate(plan, scopeRoot: scopeRoot)
            aiPlanPreview = AIPlanPreview(plan: plan, validation: validation, scopeRoot: scopeRoot)
        } catch {
            aiOrganizeErrorMessage = error.localizedDescription
        }
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
