import AppKit
import Foundation
import SwiftUI
import UniformTypeIdentifiers

/// Represents an item held inside the Floating Stash Shelf.
struct StashItem: Identifiable, Equatable, Sendable {
    let id: UUID
    let url: URL
    let name: String
    let size: Int64
    let isDirectory: Bool
    let dateAdded: Date

    init(url: URL) {
        self.id = UUID()
        let standardized = url.standardizedFileURL
        self.url = standardized
        self.name = standardized.lastPathComponent
        self.dateAdded = Date()

        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: standardized.path, isDirectory: &isDir) {
            self.isDirectory = isDir.boolValue
        } else {
            self.isDirectory = false
        }

        if !isDir.boolValue {
            let attrs = (try? FileManager.default.attributesOfItem(atPath: standardized.path)) ?? [:]
            self.size = (attrs[.size] as? NSNumber)?.int64Value ?? 0
        } else {
            self.size = 0
        }
    }

    var formattedSize: String {
        if isDirectory {
            return L10n.string("Folder")
        }
        return ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }

    var icon: NSImage {
        NSWorkspace.shared.icon(forFile: url.path)
    }
}

/// Global store managing the floating stash shelf items and visibility state.
@MainActor
final class StashShelfStore: ObservableObject {
    static let shared = StashShelfStore()

    @Published private(set) var items: [StashItem] = []
    @Published var isPresented: Bool = false
    @Published var isExpanded: Bool = true

    private let operationService: FileOperationService

    init(operationService: FileOperationService = .shared) {
        self.operationService = operationService
    }

    var count: Int {
        items.count
    }

    var totalSize: Int64 {
        items.reduce(0) { $0 + $1.size }
    }

    var formattedTotalSize: String {
        ByteCountFormatter.string(fromByteCount: totalSize, countStyle: .file)
    }

    func togglePresented() {
        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
            isPresented.toggle()
            if isPresented && items.isEmpty {
                isExpanded = true
            }
        }
    }

    func present() {
        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
            isPresented = true
            isExpanded = true
        }
    }

    func dismiss() {
        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
            isPresented = false
        }
    }

    func toggleExpanded() {
        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
            isExpanded.toggle()
        }
    }

    /// Appends URLs into the stash shelf, filtering duplicates.
    func add(urls: [URL]) {
        guard !urls.isEmpty else { return }
        let existingPaths = Set(items.map { $0.url.path })
        var newItems: [StashItem] = []

        for url in urls {
            let standardized = url.standardizedFileURL
            if !existingPaths.contains(standardized.path) {
                newItems.append(StashItem(url: standardized))
            }
        }

        guard !newItems.isEmpty else { return }

        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
            items.append(contentsOf: newItems)
            isPresented = true
            isExpanded = true
        }
    }

    /// Removes an item by UUID.
    func remove(id: UUID) {
        withAnimation(.easeInOut(duration: 0.2)) {
            items.removeAll { $0.id == id }
        }
    }

    /// Clears all stashed items.
    func clear() {
        withAnimation(.easeInOut(duration: 0.2)) {
            items.removeAll()
        }
    }

    /// Transfers (copies or moves) all stashed items into the given destination directory.
    @discardableResult
    func transferAll(
        into destination: URL,
        operation: FileDropOperation,
        completion: ((FileOperationResult) -> Void)? = nil
    ) -> Bool {
        let destination = destination.standardizedFileURL
        guard !items.isEmpty, FileBrowserViewModel.isDirectory(destination) else { return false }

        let sourceURLs = items.map(\.url)
        let effectiveOperation: FileDropOperation
        switch operation {
        case .copy:
            effectiveOperation = .copy
        case .move:
            effectiveOperation = FileBrowserViewModel.dropOperation(
                for: sourceURLs,
                into: destination,
                optionPressed: false
            )
        }

        let validSources = FileBrowserViewModel.validDropSources(
            sourceURLs,
            into: destination,
            operation: effectiveOperation
        )
        guard !validSources.isEmpty else { return false }

        let finishHandler: (FileOperationResult) -> Void = { [weak self] result in
            guard let self = self else { return }
            if effectiveOperation == .move {
                let successfulSources = Set(result.completedOutcomes.map { $0.source.standardizedFileURL.path })
                self.items.removeAll { successfulSources.contains($0.url.standardizedFileURL.path) }
            }
            completion?(result)
        }

        switch effectiveOperation {
        case .move:
            operationService.moveDetailed(validSources, to: destination, completion: finishHandler)
        case .copy:
            operationService.copyDetailed(validSources, to: destination, completion: finishHandler)
        }

        return true
    }
}
