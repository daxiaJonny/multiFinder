import Combine
import AppKit
import Foundation
import SwiftUI

@MainActor
final class BrowserPane: ObservableObject, Identifiable {
    let id: UUID
    @Published var tabs: [FileBrowserViewModel]
    @Published var selectedTabIndex: Int

    init(id: UUID = UUID(), tabs: [FileBrowserViewModel] = [], selectedTabIndex: Int = 0) {
        let resolvedTabs = tabs.isEmpty ? [FileBrowserViewModel()] : tabs
        self.id = id
        self.tabs = resolvedTabs
        self.selectedTabIndex = min(max(selectedTabIndex, 0), resolvedTabs.count - 1)
    }

    convenience init(tab: FileBrowserViewModel) {
        self.init(tabs: [tab])
    }

    var selectedTab: FileBrowserViewModel {
        tabs[min(max(selectedTabIndex, 0), tabs.count - 1)]
    }
}

struct PaneRow: Identifiable {
    let id: UUID
    var panes: [BrowserPane]
    var paneWeights: [Double]
    var heightWeight: Double

    init(
        id: UUID = UUID(),
        panes: [BrowserPane] = [],
        paneWeights: [Double] = [],
        heightWeight: Double = 1
    ) {
        self.id = id
        self.panes = panes
        self.paneWeights = Self.normalizedWeights(paneWeights, count: panes.count)
        self.heightWeight = max(heightWeight, 0.05)
    }

    private static func normalizedWeights(_ weights: [Double], count: Int) -> [Double] {
        guard count > 0 else { return [] }
        let valid = weights.count == count ? weights.map { max($0, 0.01) } : Array(repeating: 1, count: count)
        let sum = valid.reduce(0, +)
        return valid.map { $0 / sum }
    }
}

struct TabState: Codable, Equatable, Sendable {
    let location: BrowserLocation
    let sortField: SortField
    let sortAscending: Bool
    let viewMode: BrowserViewMode
    let showHiddenFiles: Bool
    let backHistory: [BrowserLocation]
    let forwardHistory: [BrowserLocation]

    init(
        location: BrowserLocation,
        sortField: SortField,
        sortAscending: Bool,
        viewMode: BrowserViewMode = .list,
        showHiddenFiles: Bool,
        backHistory: [BrowserLocation],
        forwardHistory: [BrowserLocation]
    ) {
        self.location = location
        self.sortField = sortField
        self.sortAscending = sortAscending
        self.viewMode = viewMode
        self.showHiddenFiles = showHiddenFiles
        self.backHistory = backHistory
        self.forwardHistory = forwardHistory
    }

    private enum CodingKeys: String, CodingKey {
        case location, sortField, sortAscending, viewMode, showHiddenFiles, backHistory, forwardHistory
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        location = try container.decode(BrowserLocation.self, forKey: .location)
        sortField = try container.decode(SortField.self, forKey: .sortField)
        sortAscending = try container.decode(Bool.self, forKey: .sortAscending)
        viewMode = try container.decodeIfPresent(BrowserViewMode.self, forKey: .viewMode) ?? .list
        showHiddenFiles = try container.decode(Bool.self, forKey: .showHiddenFiles)
        backHistory = try container.decodeIfPresent([BrowserLocation].self, forKey: .backHistory) ?? []
        forwardHistory = try container.decodeIfPresent([BrowserLocation].self, forKey: .forwardHistory) ?? []
    }
}

struct PaneState: Codable, Equatable, Sendable {
    let tabs: [TabState]
    let selectedTabIndex: Int

    init(tabs: [TabState], selectedTabIndex: Int = 0) {
        self.tabs = tabs
        self.selectedTabIndex = selectedTabIndex
    }

    private enum CodingKeys: String, CodingKey {
        case tabs, selectedTabIndex
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let tabs = try container.decodeIfPresent([TabState].self, forKey: .tabs) {
            self.tabs = tabs
            selectedTabIndex = try container.decodeIfPresent(Int.self, forKey: .selectedTabIndex) ?? 0
        } else {
            tabs = [try TabState(from: decoder)]
            selectedTabIndex = 0
        }
    }
}

struct RowState: Codable, Equatable, Sendable {
    let panes: [PaneState]
    let paneWeights: [Double]
    let heightWeight: Double

    init(panes: [PaneState], paneWeights: [Double] = [], heightWeight: Double = 1) {
        self.panes = panes
        self.paneWeights = paneWeights
        self.heightWeight = heightWeight
    }

    private enum CodingKeys: String, CodingKey {
        case panes, paneWeights, heightWeight
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        panes = try container.decode([PaneState].self, forKey: .panes)
        paneWeights = try container.decodeIfPresent([Double].self, forKey: .paneWeights) ?? []
        heightWeight = try container.decodeIfPresent(Double.self, forKey: .heightWeight) ?? 1
    }
}

struct LayoutState: Codable, Equatable, Sendable {
    static let currentVersion = 6

    let version: Int
    let rows: [RowState]
    let focusedIndex: Int
    let sidebarWidth: Double
    let showSidebar: Bool

    init(
        version: Int,
        rows: [RowState],
        focusedIndex: Int,
        sidebarWidth: Double = 160,
        showSidebar: Bool = true
    ) {
        self.version = version
        self.rows = rows
        self.focusedIndex = focusedIndex
        self.sidebarWidth = sidebarWidth
        self.showSidebar = showSidebar
    }

    private enum CodingKeys: String, CodingKey {
        case version, rows, focusedIndex, sidebarWidth, showSidebar
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decode(Int.self, forKey: .version)
        rows = try container.decode([RowState].self, forKey: .rows)
        focusedIndex = try container.decode(Int.self, forKey: .focusedIndex)
        sidebarWidth = try container.decodeIfPresent(Double.self, forKey: .sidebarWidth) ?? 160
        showSidebar = try container.decodeIfPresent(Bool.self, forKey: .showSidebar) ?? true
    }
}

@MainActor
final class LayoutManager: ObservableObject {
    @Published var rows: [PaneRow]
    @Published var focusedPaneID: UUID? {
        didSet {
            if oldValue != focusedPaneID { save() }
        }
    }
    @Published private(set) var serializedState: String
    @Published var sidebarWidth: Double
    @Published var isSidebarVisible: Bool {
        didSet {
            if oldValue != isSidebarVisible { save() }
        }
    }
    @Published var isGoToFolderPresented = false
    @Published var isCommandPalettePresented = false
    @Published private(set) var highlightedPaneID: UUID? = nil
    weak var workspaceWindow: NSWindow?

    private let packageOpener: (URL) -> Bool
    private var highlightTask: Task<Void, Never>?

    init(
        serializedState: String = "",
        packageOpener: @escaping (URL) -> Bool = { NSWorkspace.shared.open($0) }
    ) {
        self.serializedState = serializedState
        self.packageOpener = packageOpener

        if let state = Self.decode(serializedState), let restored = Self.restore(state) {
            rows = restored.rows
            focusedPaneID = restored.focusedPaneID
            sidebarWidth = restored.sidebarWidth
            isSidebarVisible = restored.isSidebarVisible
        } else {
            let firstPane = BrowserPane(tab: FileBrowserViewModel())
            let secondPane = BrowserPane(tab: FileBrowserViewModel())
            rows = [PaneRow(panes: [firstPane, secondPane])]
            focusedPaneID = firstPane.id
            sidebarWidth = 160
            isSidebarVisible = true
        }

        save()
    }

    var focusedPane: FileBrowserViewModel? {
        focusedBrowserPane?.selectedTab
    }

    var focusedBrowserPane: BrowserPane? {
        guard let focusedPaneID else { return nil }
        return findPane(id: focusedPaneID)
    }

    var totalPaneCount: Int {
        rows.reduce(0) { $0 + $1.panes.count }
    }

    var canGoBack: Bool {
        focusedPane?.canGoBack == true
    }

    var canGoForward: Bool {
        focusedPane?.canGoForward == true
    }

    var canGoUp: Bool {
        focusedPane?.canGoUp == true
    }

    func toggleSidebar() {
        isSidebarVisible.toggle()
    }

    func presentGoToFolder() {
        isGoToFolderPresented = true
    }

    func dismissGoToFolder() {
        isGoToFolderPresented = false
    }

    func toggleCommandPalette() {
        isCommandPalettePresented.toggle()
    }

    func presentCommandPalette() {
        isCommandPalettePresented = true
    }

    func dismissCommandPalette() {
        isCommandPalettePresented = false
    }

    @discardableResult
    func goToFolder(_ input: String) -> Bool {
        guard let pane = focusedPane else { return false }
        let trimmedInput = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedInput.isEmpty else {
            pane.errorMessage = L10n.string("Enter a folder path.")
            return false
        }

        let expandedPath = (trimmedInput as NSString).expandingTildeInPath
        let pathURL: URL
        if expandedPath.hasPrefix("/") {
            pathURL = URL(fileURLWithPath: expandedPath).standardizedFileURL
        } else if let currentURL = pane.currentURL {
            pathURL = currentURL.appendingPathComponent(expandedPath).standardizedFileURL
        } else {
            pathURL = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(expandedPath)
                .standardizedFileURL
        }

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: pathURL.path, isDirectory: &isDirectory) else {
            pane.errorMessage = L10n.format("“%@” does not exist.", pathURL.path)
            return false
        }

        pane.errorMessage = nil
        if isDirectory.boolValue {
            pane.navigate(to: .directory(pathURL))
        } else {
            pane.navigateToFile(pathURL)
        }
        return true
    }

    @discardableResult
    func openExternalPath(_ url: URL) -> Bool {
        openExternalPaths([url])
    }

    @discardableResult
    func openExternalPaths(_ urls: [URL], inNewTab: Bool = false) -> Bool {
        enum ExternalOpenAction {
            case package(URL)
            case directory(URL)
            case files(parent: URL, urls: [URL])
        }

        var actions: [ExternalOpenAction] = []
        var fileActionIndexes: [URL: Int] = [:]
        var seenURLs = Set<URL>()

        for url in urls {
            let targetURL = url.standardizedFileURL
            guard seenURLs.insert(targetURL).inserted else { continue }

            var isDirectory: ObjCBool = false
            guard targetURL.isFileURL,
                  FileManager.default.fileExists(atPath: targetURL.path, isDirectory: &isDirectory) else {
                focusedPane?.errorMessage = L10n.string("The requested path does not exist.")
                continue
            }

            let isPackage = isDirectory.boolValue && (try? targetURL.resourceValues(
                forKeys: [.isPackageKey]
            ).isPackage) == true
            if isPackage && !inNewTab {
                actions.append(.package(targetURL))
            } else if isDirectory.boolValue && !isPackage {
                actions.append(.directory(targetURL))
            } else {
                let parentURL = targetURL.deletingLastPathComponent().standardizedFileURL
                if let actionIndex = fileActionIndexes[parentURL],
                   case .files(let parent, var fileURLs) = actions[actionIndex] {
                    fileURLs.append(targetURL)
                    actions[actionIndex] = .files(parent: parent, urls: fileURLs)
                } else {
                    fileActionIndexes[parentURL] = actions.count
                    actions.append(.files(parent: parentURL, urls: [targetURL]))
                }
            }
        }

        var didOpenAny = false
        for action in actions {
            switch action {
            case .package(let targetURL):
                if packageOpener(targetURL) {
                    didOpenAny = true
                } else {
                    focusedPane?.errorMessage = L10n.format(
                        "Could not open “%@”.",
                        targetURL.lastPathComponent
                    )
                }
            case .directory(let targetURL):
                didOpenAny = (inNewTab
                    ? openExternalTab(at: targetURL)
                    : openExternalDirectory(targetURL)) || didOpenAny
            case .files(let parentURL, let fileURLs):
                didOpenAny = (inNewTab
                    ? openExternalTab(at: parentURL, selecting: fileURLs)
                    : openExternalFiles(fileURLs, in: parentURL)) || didOpenAny
            }
        }

        return didOpenAny
    }

    private func openExternalTab(at directory: URL, selecting files: [URL] = []) -> Bool {
        guard let pane = focusedPaneID.flatMap({ findPane(id: $0) }) ?? allPanes.first else { return false }
        let source = pane.selectedTab
        let tab = FileBrowserViewModel(
            location: .directory(directory),
            sortField: source.sortField,
            sortAscending: source.sortAscending,
            viewMode: source.viewMode,
            showHiddenFiles: source.showHiddenFiles
        )
        if !files.isEmpty { _ = tab.revealFiles(files) }
        pane.tabs.insert(tab, at: pane.selectedTabIndex + 1)
        pane.selectedTabIndex += 1
        focusAndHighlight(pane)
        save()
        return true
    }

    @discardableResult
    private func openExternalDirectory(_ targetURL: URL) -> Bool {
        var isDirectory: ObjCBool = false
        guard targetURL.isFileURL,
              FileManager.default.fileExists(atPath: targetURL.path, isDirectory: &isDirectory) else {
            focusedPane?.errorMessage = L10n.string("The requested path does not exist.")
            return false
        }

        let isPackage = isDirectory.boolValue && (try? targetURL.resourceValues(
            forKeys: [.isPackageKey]
        ).isPackage) == true
        if isPackage {
            guard packageOpener(targetURL) else {
                focusedPane?.errorMessage = L10n.format("Could not open “%@”.", targetURL.lastPathComponent)
                return false
            }
            return true
        }

        if isDirectory.boolValue,
           let match = firstTab(where: { $0.currentURL == targetURL }) {
            match.pane.selectedTabIndex = match.tabIndex
            focusAndHighlight(match.pane)
            save()
            return true
        }

        let parentURL = targetURL.deletingLastPathComponent()
        if let match = firstTab(where: { $0.currentURL == parentURL }) {
            let tab = match.pane.tabs[match.tabIndex]
            if isDirectory.boolValue {
                tab.navigate(to: targetURL)
            } else {
                tab.navigateToFile(targetURL)
            }
            match.pane.selectedTabIndex = match.tabIndex
            focusAndHighlight(match.pane)
            save()
            return true
        }

        guard let sourcePaneID = focusedPaneID ?? allPanes.first?.id else { return false }
        addPaneRight(of: sourcePaneID)
        guard let newPane = focusedPane else { return false }
        if isDirectory.boolValue {
            newPane.navigate(to: targetURL)
        } else {
            newPane.navigateToFile(targetURL)
        }
        save()
        return true
    }

    @discardableResult
    private func openExternalFiles(_ fileURLs: [URL], in parentURL: URL) -> Bool {
        guard !fileURLs.isEmpty else { return false }

        if let match = firstTab(where: { $0.currentURL == parentURL }) {
            let tab = match.pane.tabs[match.tabIndex]
            guard tab.revealFiles(fileURLs) else { return false }
            match.pane.selectedTabIndex = match.tabIndex
            focusAndHighlight(match.pane)
            save()
            return true
        }

        guard let sourcePaneID = focusedPaneID ?? allPanes.first?.id else { return false }
        addPaneRight(of: sourcePaneID)
        guard let newPane = focusedPane else { return false }
        guard newPane.revealFiles(fileURLs) else { return false }
        save()
        return true
    }

    func findPane(id: UUID) -> BrowserPane? {
        rows.lazy.flatMap(\.panes).first { $0.id == id }
    }

    private var allPanes: [BrowserPane] {
        rows.flatMap(\.panes)
    }

    private func firstTab(where predicate: (FileBrowserViewModel) -> Bool) -> (pane: BrowserPane, tabIndex: Int)? {
        if let pane = allPanes.first(where: { predicate($0.selectedTab) }) {
            return (pane, pane.selectedTabIndex)
        }
        for pane in allPanes {
            if let tabIndex = pane.tabs.firstIndex(where: predicate) {
                return (pane, tabIndex)
            }
        }
        return nil
    }

    func addPaneRight(of paneID: UUID) {
        guard let location = findPaneLocation(id: paneID) else { return }
        let newPane = clonedPane(from: findPane(id: paneID))
        splitPaneWeight(rowIndex: location.rowIndex, paneIndex: location.paneIndex, insertAfter: true)
        rows[location.rowIndex].panes.insert(newPane, at: location.paneIndex + 1)
        focusedPaneID = newPane.id
        save()
    }

    func addPaneLeft(of paneID: UUID) {
        guard let location = findPaneLocation(id: paneID) else { return }
        let newPane = clonedPane(from: findPane(id: paneID))
        splitPaneWeight(rowIndex: location.rowIndex, paneIndex: location.paneIndex, insertAfter: false)
        rows[location.rowIndex].panes.insert(newPane, at: location.paneIndex)
        focusedPaneID = newPane.id
        save()
    }

    func addRowBelow(of paneID: UUID) {
        guard let location = findPaneLocation(id: paneID) else { return }
        let newPane = clonedPane(from: findPane(id: paneID))
        let newWeight = rows[location.rowIndex].heightWeight / 2
        rows[location.rowIndex].heightWeight = newWeight
        rows.insert(PaneRow(panes: [newPane], heightWeight: newWeight), at: location.rowIndex + 1)
        focusedPaneID = newPane.id
        save()
    }

    func addRowAbove(of paneID: UUID) {
        guard let location = findPaneLocation(id: paneID) else { return }
        let newPane = clonedPane(from: findPane(id: paneID))
        let newWeight = rows[location.rowIndex].heightWeight / 2
        rows[location.rowIndex].heightWeight = newWeight
        rows.insert(PaneRow(panes: [newPane], heightWeight: newWeight), at: location.rowIndex)
        focusedPaneID = newPane.id
        save()
    }

    func removePane(_ paneID: UUID) {
        guard totalPaneCount > 1, let location = findPaneLocation(id: paneID) else { return }
        let nextFocusedPaneID = focusedPaneID == paneID
            ? focusCandidateAfterRemovingPane(at: location)
            : nil
        let removedWeight = rows[location.rowIndex].paneWeights.remove(at: location.paneIndex)
        rows[location.rowIndex].panes.remove(at: location.paneIndex)
        if rows[location.rowIndex].panes.isEmpty {
            let removedHeight = rows[location.rowIndex].heightWeight
            rows.remove(at: location.rowIndex)
            if !rows.isEmpty {
                rows[min(location.rowIndex, rows.count - 1)].heightWeight += removedHeight
            }
        } else {
            let recipient = min(location.paneIndex, rows[location.rowIndex].paneWeights.count - 1)
            rows[location.rowIndex].paneWeights[recipient] += removedWeight
            normalizePaneWeights(rowIndex: location.rowIndex)
        }
        if focusedPaneID == paneID {
            focusedPaneID = nextFocusedPaneID ?? rows.lazy.flatMap(\.panes).first?.id
        }
        save()
    }

    var closeTarget: WorkspaceCloseTarget {
        guard let pane = focusedBrowserPane else { return .window }
        if pane.tabs.count > 1 { return .tab }
        return totalPaneCount > 1 ? .pane : .window
    }

    var canCloseTab: Bool {
        closeTarget == .tab
    }

    func newTab(in paneID: UUID) {
        guard let pane = findPane(id: paneID) else { return }
        pane.selectedTab.clearFilter()
        let newTab = clonedTab(from: pane.selectedTab)
        pane.tabs.insert(newTab, at: pane.selectedTabIndex + 1)
        pane.selectedTabIndex += 1
        focusedPaneID = paneID
        save()
    }

    func closeTab(in paneID: UUID) {
        guard let pane = findPane(id: paneID) else { return }
        closeTab(at: pane.selectedTabIndex, in: paneID)
    }

    func closeTab(at index: Int, in paneID: UUID) {
        guard let pane = findPane(id: paneID), pane.tabs.indices.contains(index) else { return }
        if pane.tabs.count == 1 {
            removePane(paneID)
            return
        }
        pane.tabs.remove(at: index)
        if index < pane.selectedTabIndex {
            pane.selectedTabIndex -= 1
        } else if index == pane.selectedTabIndex {
            pane.selectedTabIndex = min(index, pane.tabs.count - 1)
        }
        save()
    }

    func selectTab(at index: Int, in paneID: UUID) {
        guard let pane = findPane(id: paneID), pane.tabs.indices.contains(index) else { return }
        if index != pane.selectedTabIndex {
            pane.selectedTab.clearFilter()
        }
        pane.selectedTabIndex = index
        focusedPaneID = paneID
        save()
    }

    func selectNextTab(in paneID: UUID) {
        guard let pane = findPane(id: paneID), pane.tabs.count > 1 else { return }
        pane.selectedTab.clearFilter()
        pane.selectedTabIndex = (pane.selectedTabIndex + 1) % pane.tabs.count
        save()
    }

    func selectPreviousTab(in paneID: UUID) {
        guard let pane = findPane(id: paneID), pane.tabs.count > 1 else { return }
        pane.selectedTab.clearFilter()
        pane.selectedTabIndex = (pane.selectedTabIndex + pane.tabs.count - 1) % pane.tabs.count
        save()
    }

    func adjacentPane(of paneID: UUID) -> BrowserPane? {
        let panes = allPanes
        guard panes.count > 1,
              let index = panes.firstIndex(where: { $0.id == paneID }) else { return nil }
        return panes[(index + 1) % panes.count]
    }

    func canTransferSelectionToAdjacentPane(
        from paneID: UUID,
        operation: FileDropOperation
    ) -> Bool {
        guard let source = findPane(id: paneID)?.selectedTab else { return false }
        return canTransferItemsToAdjacentPane(
            source.selectedItemURLs,
            from: paneID,
            operation: operation
        )
    }

    func canTransferItemsToAdjacentPane(
        _ urls: [URL],
        from paneID: UUID,
        operation: FileDropOperation
    ) -> Bool {
        guard !urls.isEmpty,
              let target = adjacentPane(of: paneID)?.selectedTab,
              case .directory(let destination) = target.location,
              Self.isOrdinaryDirectory(destination) else { return false }

        return !FileBrowserViewModel.validDropSources(
            urls,
            into: destination,
            operation: operation
        ).isEmpty
    }

    @discardableResult
    func copySelectionToAdjacentPane() -> Bool {
        guard let focusedPaneID else { return false }
        return transferSelectedItemsToAdjacentPane(from: focusedPaneID, operation: .copy)
    }

    @discardableResult
    func moveSelectionToAdjacentPane() -> Bool {
        guard let focusedPaneID else { return false }
        return transferSelectedItemsToAdjacentPane(from: focusedPaneID, operation: .move)
    }

    @discardableResult
    func transferSelectedItemsToAdjacentPane(
        from paneID: UUID,
        operation: FileDropOperation
    ) -> Bool {
        guard let sourcePane = findPane(id: paneID) else { return false }
        let urls = sourcePane.selectedTab.selectedItemURLs
        guard !urls.isEmpty else {
            sourcePane.selectedTab.errorMessage = L10n.string("Please select at least one file or folder.")
            return false
        }
        return transferItemsToAdjacentPane(urls, from: paneID, operation: operation)
    }

    @discardableResult
    func transferItemsToAdjacentPane(
        _ urls: [URL],
        from paneID: UUID,
        operation: FileDropOperation
    ) -> Bool {
        guard let sourcePane = findPane(id: paneID),
              let targetPane = adjacentPane(of: paneID) else {
            findPane(id: paneID)?.selectedTab.errorMessage = L10n.string(
                "At least two panes are required for this operation."
            )
            return false
        }

        let source = sourcePane.selectedTab
        let target = targetPane.selectedTab
        guard case .directory(let destination) = target.location,
              Self.isOrdinaryDirectory(destination) else {
            source.errorMessage = L10n.string("The adjacent pane must show a regular folder.")
            return false
        }

        let validSources = FileBrowserViewModel.validDropSources(
            urls,
            into: destination,
            operation: operation
        )
        guard !validSources.isEmpty else {
            source.errorMessage = operation == .copy
                ? L10n.string("The selected items cannot be copied to the adjacent pane.")
                : L10n.string("The selected items cannot be moved to the adjacent pane.")
            return false
        }

        highlightPane(targetPane)
        switch operation {
        case .copy:
            target.copyItems(from: validSources)
        case .move:
            target.moveItems(from: validSources) { [weak source] result in
                if !result.completedOutcomes.isEmpty {
                    source?.reload(preservingError: true)
                }
            }
        }
        return true
    }

    func focusPane(direction: FocusDirection) {
        guard let focusedPaneID, let location = findPaneLocation(id: focusedPaneID) else { return }

        switch direction {
        case .left where location.paneIndex > 0:
            self.focusedPaneID = rows[location.rowIndex].panes[location.paneIndex - 1].id
        case .right where location.paneIndex < rows[location.rowIndex].panes.count - 1:
            self.focusedPaneID = rows[location.rowIndex].panes[location.paneIndex + 1].id
        case .up where location.rowIndex > 0:
            let targetRow = rows[location.rowIndex - 1]
            self.focusedPaneID = targetRow.panes[min(location.paneIndex, targetRow.panes.count - 1)].id
        case .down where location.rowIndex < rows.count - 1:
            let targetRow = rows[location.rowIndex + 1]
            self.focusedPaneID = targetRow.panes[min(location.paneIndex, targetRow.panes.count - 1)].id
        default:
            break
        }
    }

    func save() {
        serializedState = Self.encode(makeState()) ?? serializedState
    }

    @discardableResult
    func applyTemplate(_ state: LayoutState) -> Bool {
        guard let restored = Self.restore(state) else { return false }
        rows = restored.rows
        sidebarWidth = restored.sidebarWidth
        isSidebarVisible = restored.isSidebarVisible
        focusedPaneID = restored.focusedPaneID
        save()
        return true
    }

    func makeState() -> LayoutState {
        var focusedIndex = 0
        var flatIndex = 0

        let rowStates = rows.map { row in
            RowState(panes: row.panes.map { pane in
                defer { flatIndex += 1 }
                if pane.id == focusedPaneID { focusedIndex = flatIndex }
                return PaneState(
                    tabs: pane.tabs.map { tab in
                        TabState(
                            location: tab.location,
                            sortField: tab.sortField,
                            sortAscending: tab.sortAscending,
                            viewMode: tab.viewMode,
                            showHiddenFiles: tab.showHiddenFiles,
                            backHistory: tab.backHistory,
                            forwardHistory: tab.forwardHistory
                        )
                    },
                    selectedTabIndex: pane.selectedTabIndex
                )
            }, paneWeights: row.paneWeights, heightWeight: row.heightWeight)
        }

        return LayoutState(
            version: LayoutState.currentVersion,
            rows: rowStates,
            focusedIndex: focusedIndex,
            sidebarWidth: sidebarWidth,
            showSidebar: isSidebarVisible
        )
    }

    func makeTemplateState() -> LayoutState {
        let currentState = makeState()
        let rows = currentState.rows.map { row in
            RowState(
                panes: row.panes.map { pane in
                    PaneState(
                        tabs: pane.tabs.map { tab in
                            TabState(
                                location: tab.location,
                                sortField: tab.sortField,
                                sortAscending: tab.sortAscending,
                                viewMode: tab.viewMode,
                                showHiddenFiles: tab.showHiddenFiles,
                                backHistory: [],
                                forwardHistory: []
                            )
                        },
                        selectedTabIndex: pane.selectedTabIndex
                    )
                },
                paneWeights: row.paneWeights,
                heightWeight: row.heightWeight
            )
        }
        return LayoutState(
            version: LayoutState.currentVersion,
            rows: rows,
            focusedIndex: currentState.focusedIndex,
            sidebarWidth: currentState.sidebarWidth,
            showSidebar: currentState.showSidebar
        )
    }

    nonisolated static func encode(_ state: LayoutState) -> String? {
        guard let data = try? JSONEncoder().encode(state) else { return nil }
        return data.base64EncodedString()
    }

    nonisolated static func decode(_ encoded: String) -> LayoutState? {
        guard !encoded.isEmpty,
              let data = Data(base64Encoded: encoded),
              let state = try? JSONDecoder().decode(LayoutState.self, from: data),
              isUsable(state) else { return nil }
        return state
    }

    nonisolated static func isUsable(_ state: LayoutState) -> Bool {
        (2...LayoutState.currentVersion).contains(state.version)
            && !state.rows.isEmpty
            && state.rows.allSatisfy { !$0.panes.isEmpty && $0.panes.allSatisfy { !$0.tabs.isEmpty } }
    }

    private func clonedPane(from pane: BrowserPane?) -> BrowserPane {
        BrowserPane(tab: clonedTab(from: pane?.selectedTab))
    }

    private func clonedTab(from tab: FileBrowserViewModel?) -> FileBrowserViewModel {
        FileBrowserViewModel(
            location: tab?.location ?? .directory(FileManager.default.homeDirectoryForCurrentUser),
            sortField: tab?.sortField ?? .name,
            sortAscending: tab?.sortAscending ?? true,
            viewMode: tab?.viewMode ?? .list,
            showHiddenFiles: tab?.showHiddenFiles ?? AppSettings.shared.showHiddenFilesByDefault
        )
    }

    private func focusAndHighlight(_ pane: BrowserPane) {
        focusedPaneID = pane.id
        highlightPane(pane)
    }

    private func highlightPane(_ pane: BrowserPane) {
        highlightedPaneID = pane.id
        highlightTask?.cancel()
        highlightTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled, self?.highlightedPaneID == pane.id else { return }
            self?.highlightedPaneID = nil
        }
    }

    private nonisolated static func isOrdinaryDirectory(_ url: URL) -> Bool {
        guard let values = try? url.standardizedFileURL.resourceValues(
            forKeys: [.isDirectoryKey, .isPackageKey]
        ) else { return false }
        return values.isDirectory == true && values.isPackage != true
    }

    private func findPaneLocation(id: UUID) -> (rowIndex: Int, paneIndex: Int)? {
        for (rowIndex, row) in rows.enumerated() {
            if let paneIndex = row.panes.firstIndex(where: { $0.id == id }) {
                return (rowIndex, paneIndex)
            }
        }
        return nil
    }

    func resizeSidebar(to width: Double) {
        sidebarWidth = min(max(width, 110), 360)
    }

    func resizePane(rowIndex: Int, dividerIndex: Int, delta: Double, availableWidth: Double) {
        guard rows.indices.contains(rowIndex),
              dividerIndex >= 0,
              dividerIndex + 1 < rows[rowIndex].paneWeights.count,
              availableWidth > 0 else { return }
        let minimumWeight = min(170 / availableWidth, 0.45)
        adjustPair(
            &rows[rowIndex].paneWeights,
            firstIndex: dividerIndex,
            deltaWeight: delta / availableWidth,
            minimumWeight: minimumWeight
        )
    }

    func resizeRow(dividerIndex: Int, delta: Double, availableHeight: Double) {
        guard dividerIndex >= 0, dividerIndex + 1 < rows.count, availableHeight > 0 else { return }
        var weights = rows.map(\.heightWeight)
        let minimumWeight = min(150 / availableHeight, 0.45)
        adjustPair(
            &weights,
            firstIndex: dividerIndex,
            deltaWeight: delta / availableHeight,
            minimumWeight: minimumWeight
        )
        for index in weights.indices {
            rows[index].heightWeight = weights[index]
        }
    }

    private static func restore(_ state: LayoutState) -> (
        rows: [PaneRow],
        focusedPaneID: UUID?,
        sidebarWidth: Double,
        isSidebarVisible: Bool
    )? {
        var allPanes: [BrowserPane] = []
        let rows = state.rows.compactMap { rowState -> PaneRow? in
            let panes = rowState.panes.compactMap { paneState -> BrowserPane? in
                let tabs = paneState.tabs.map { tabState in
                    FileBrowserViewModel(
                        location: sanitized(tabState.location),
                        sortField: tabState.sortField,
                        sortAscending: tabState.sortAscending,
                        viewMode: tabState.viewMode,
                        showHiddenFiles: tabState.showHiddenFiles,
                        backHistory: tabState.backHistory.map(sanitized),
                        forwardHistory: tabState.forwardHistory.map(sanitized)
                    )
                }
                guard !tabs.isEmpty else { return nil }
                let pane = BrowserPane(tabs: tabs, selectedTabIndex: paneState.selectedTabIndex)
                allPanes.append(pane)
                return pane
            }
            return panes.isEmpty ? nil : PaneRow(
                panes: panes,
                paneWeights: rowState.paneWeights,
                heightWeight: rowState.heightWeight
            )
        }

        guard !rows.isEmpty else { return nil }
        let focusedPaneID = allPanes.indices.contains(state.focusedIndex)
            ? allPanes[state.focusedIndex].id
            : allPanes.first?.id
        return (
            rows,
            focusedPaneID,
            min(max(state.sidebarWidth, 110), 360),
            state.showSidebar
        )
    }

    private static func sanitized(_ location: BrowserLocation) -> BrowserLocation {
        guard case .directory(let url) = location else { return location }
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
        return exists && isDirectory.boolValue
            ? .directory(url.standardizedFileURL)
            : .directory(FileManager.default.homeDirectoryForCurrentUser)
    }

    private func splitPaneWeight(rowIndex: Int, paneIndex: Int, insertAfter: Bool) {
        let existingWeight = rows[rowIndex].paneWeights[paneIndex]
        rows[rowIndex].paneWeights[paneIndex] = existingWeight / 2
        let insertionIndex = insertAfter ? paneIndex + 1 : paneIndex
        rows[rowIndex].paneWeights.insert(existingWeight / 2, at: insertionIndex)
    }

    private func focusCandidateAfterRemovingPane(
        at location: (rowIndex: Int, paneIndex: Int)
    ) -> UUID? {
        let row = rows[location.rowIndex]
        if row.panes.count > 1 {
            let candidateIndex = location.paneIndex < row.panes.count - 1
                ? location.paneIndex + 1
                : location.paneIndex - 1
            return row.panes[candidateIndex].id
        }

        if location.rowIndex < rows.count - 1 {
            let nextRow = rows[location.rowIndex + 1]
            return nextRow.panes[min(location.paneIndex, nextRow.panes.count - 1)].id
        }
        if location.rowIndex > 0 {
            let previousRow = rows[location.rowIndex - 1]
            return previousRow.panes[min(location.paneIndex, previousRow.panes.count - 1)].id
        }
        return nil
    }

    private func normalizePaneWeights(rowIndex: Int) {
        let sum = rows[rowIndex].paneWeights.reduce(0, +)
        guard sum > 0 else { return }
        rows[rowIndex].paneWeights = rows[rowIndex].paneWeights.map { $0 / sum }
    }

    private func adjustPair(
        _ weights: inout [Double],
        firstIndex: Int,
        deltaWeight: Double,
        minimumWeight: Double
    ) {
        let secondIndex = firstIndex + 1
        let pairTotal = weights[firstIndex] + weights[secondIndex]
        let effectiveMinimum = min(minimumWeight, pairTotal / 2 - 0.001)
        let newFirst = min(max(weights[firstIndex] + deltaWeight, effectiveMinimum), pairTotal - effectiveMinimum)
        weights[firstIndex] = newFirst
        weights[secondIndex] = pairTotal - newFirst
    }
}

enum FocusDirection {
    case left, right, up, down
}

enum WorkspaceCloseTarget: Equatable {
    case tab
    case pane
    case window
}

struct LayoutManagerKey: FocusedValueKey {
    typealias Value = LayoutManager
}

extension FocusedValues {
    var layoutManager: LayoutManager? {
        get { self[LayoutManagerKey.self] }
        set { self[LayoutManagerKey.self] = newValue }
    }
}
