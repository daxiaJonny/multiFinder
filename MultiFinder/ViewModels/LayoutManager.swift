import Combine
import Foundation
import SwiftUI

struct PaneRow: Identifiable {
    let id: UUID
    var panes: [FileBrowserViewModel]
    var paneWeights: [Double]
    var heightWeight: Double

    init(
        id: UUID = UUID(),
        panes: [FileBrowserViewModel] = [],
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

struct PaneState: Codable, Equatable, Sendable {
    let location: BrowserLocation
    let sortField: SortField
    let sortAscending: Bool
    let showHiddenFiles: Bool
    let backHistory: [BrowserLocation]
    let forwardHistory: [BrowserLocation]
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
    static let currentVersion = 3

    let version: Int
    let rows: [RowState]
    let focusedIndex: Int
    let sidebarWidth: Double

    init(version: Int, rows: [RowState], focusedIndex: Int, sidebarWidth: Double = 160) {
        self.version = version
        self.rows = rows
        self.focusedIndex = focusedIndex
        self.sidebarWidth = sidebarWidth
    }

    private enum CodingKeys: String, CodingKey {
        case version, rows, focusedIndex, sidebarWidth
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decode(Int.self, forKey: .version)
        rows = try container.decode([RowState].self, forKey: .rows)
        focusedIndex = try container.decode(Int.self, forKey: .focusedIndex)
        sidebarWidth = try container.decodeIfPresent(Double.self, forKey: .sidebarWidth) ?? 160
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
    @Published private(set) var highlightedPaneID: UUID? = nil

    private var highlightTask: Task<Void, Never>?

    init(serializedState: String = "") {
        self.serializedState = serializedState

        if let state = Self.decode(serializedState), let restored = Self.restore(state) {
            rows = restored.rows
            focusedPaneID = restored.focusedPaneID
            sidebarWidth = restored.sidebarWidth
        } else {
            let firstPane = FileBrowserViewModel()
            let secondPane = FileBrowserViewModel()
            rows = [PaneRow(panes: [firstPane, secondPane])]
            focusedPaneID = firstPane.id
            sidebarWidth = 160
        }

        save()
    }

    var focusedPane: FileBrowserViewModel? {
        guard let focusedPaneID else { return nil }
        return findPane(id: focusedPaneID)
    }

    var totalPaneCount: Int {
        rows.reduce(0) { $0 + $1.panes.count }
    }

    @discardableResult
    func openExternalPath(_ url: URL) -> Bool {
        let targetURL = url.standardizedFileURL
        var isDirectory: ObjCBool = false
        guard targetURL.isFileURL,
              FileManager.default.fileExists(atPath: targetURL.path, isDirectory: &isDirectory) else {
            focusedPane?.errorMessage = "The requested path does not exist."
            return false
        }

        if isDirectory.boolValue,
           let pane = allPanes.first(where: { $0.currentURL == targetURL }) {
            focusAndHighlight(pane)
            return true
        }

        let parentURL = targetURL.deletingLastPathComponent()
        if let pane = allPanes.first(where: { $0.currentURL == parentURL }) {
            if isDirectory.boolValue {
                pane.navigate(to: targetURL)
            } else {
                pane.navigateToFile(targetURL)
            }
            focusAndHighlight(pane)
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

    func findPane(id: UUID) -> FileBrowserViewModel? {
        rows.lazy.flatMap(\.panes).first { $0.id == id }
    }

    private var allPanes: [FileBrowserViewModel] {
        rows.flatMap(\.panes)
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
            focusedPaneID = rows.lazy.flatMap(\.panes).first?.id
        }
        save()
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
                    location: pane.location,
                    sortField: pane.sortField,
                    sortAscending: pane.sortAscending,
                    showHiddenFiles: pane.showHiddenFiles,
                    backHistory: pane.backHistory,
                    forwardHistory: pane.forwardHistory
                )
            }, paneWeights: row.paneWeights, heightWeight: row.heightWeight)
        }

        return LayoutState(
            version: LayoutState.currentVersion,
            rows: rowStates,
            focusedIndex: focusedIndex,
            sidebarWidth: sidebarWidth
        )
    }

    func makeTemplateState() -> LayoutState {
        let currentState = makeState()
        let rows = currentState.rows.map { row in
            RowState(
                panes: row.panes.map { pane in
                    PaneState(
                        location: pane.location,
                        sortField: pane.sortField,
                        sortAscending: pane.sortAscending,
                        showHiddenFiles: pane.showHiddenFiles,
                        backHistory: [],
                        forwardHistory: []
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
            sidebarWidth: currentState.sidebarWidth
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
            && state.rows.allSatisfy { !$0.panes.isEmpty }
    }

    private func clonedPane(from pane: FileBrowserViewModel?) -> FileBrowserViewModel {
        FileBrowserViewModel(
            location: pane?.location ?? .directory(FileManager.default.homeDirectoryForCurrentUser),
            sortField: pane?.sortField ?? .name,
            sortAscending: pane?.sortAscending ?? true,
            showHiddenFiles: pane?.showHiddenFiles ?? false
        )
    }

    private func focusAndHighlight(_ pane: FileBrowserViewModel) {
        focusedPaneID = pane.id
        highlightedPaneID = pane.id
        highlightTask?.cancel()
        highlightTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled, self?.highlightedPaneID == pane.id else { return }
            self?.highlightedPaneID = nil
        }
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

    private static func restore(_ state: LayoutState) -> (rows: [PaneRow], focusedPaneID: UUID?, sidebarWidth: Double)? {
        var allPanes: [FileBrowserViewModel] = []
        let rows = state.rows.compactMap { rowState -> PaneRow? in
            let panes = rowState.panes.map { paneState in
                let pane = FileBrowserViewModel(
                    location: sanitized(paneState.location),
                    sortField: paneState.sortField,
                    sortAscending: paneState.sortAscending,
                    showHiddenFiles: paneState.showHiddenFiles,
                    backHistory: paneState.backHistory.map(sanitized),
                    forwardHistory: paneState.forwardHistory.map(sanitized)
                )
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
        return (rows, focusedPaneID, min(max(state.sidebarWidth, 110), 360))
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

struct LayoutManagerKey: FocusedValueKey {
    typealias Value = LayoutManager
}

extension FocusedValues {
    var layoutManager: LayoutManager? {
        get { self[LayoutManagerKey.self] }
        set { self[LayoutManagerKey.self] = newValue }
    }
}
