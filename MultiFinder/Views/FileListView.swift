import AppKit
import CoreTransferable
import SwiftUI
import UniformTypeIdentifiers

struct FileListView: View {
    @ObservedObject var viewModel: FileBrowserViewModel
    @ObservedObject private var clipboard = FileClipboard.shared
    let canTransferToAdjacentPane: ([URL], FileDropOperation) -> Bool
    let onFocus: () -> Void
    let onBeginFiltering: () -> Void
    let onQuickLook: () -> Void
    let onRename: (FileItem) -> Void
    let onCopyToAdjacentPane: ([URL]) -> Void
    let onMoveToAdjacentPane: ([URL]) -> Void

    var body: some View {
        Table(
            of: FileItem.self,
            selection: focusedSelection,
            sortOrder: focusedSortOrder
        ) {
            TableColumn("Name", sortUsing: FileItemComparator(field: .name)) { item in
                HStack(spacing: 6) {
                    Image(nsImage: IconCache.shared.icon(for: item.url.path))
                        .resizable()
                        .interpolation(.high)
                        .frame(width: 16, height: 16)
                    Text(item.name)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if item.isSymlink {
                        Image(systemName: "arrowshape.turn.up.right")
                            .font(.system(size: 8))
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            .width(min: 140, ideal: 280)

            TableColumn("Date Modified", sortUsing: FileItemComparator(field: .date)) { item in
                Text(item.modificationDate, format: .dateTime.year().month(.twoDigits).day().hour().minute())
                    .foregroundStyle(.secondary)
            }
            .width(min: 125, ideal: 160, max: 220)

            TableColumn("Size", sortUsing: FileItemComparator(field: .size)) { item in
                Text(item.isDirectory ? "--" : ByteCountFormatter.string(fromByteCount: item.size, countStyle: .file))
                    .foregroundStyle(.secondary)
            }
            .width(min: 65, ideal: 85, max: 130)

            TableColumn("Kind", sortUsing: FileItemComparator(field: .kind)) { item in
                Text(item.kind)
                    .foregroundStyle(.secondary)
            }
            .width(min: 90, ideal: 130, max: 220)
        } rows: {
            ForEach(viewModel.visibleItems) { item in
                // Table drop targets must be attached to TableRowContent, not hosted cell views.
                if item.isDirectory && !item.isPackage {
                    if FileDropSafety.canStartDragging(item) {
                        TableRow(item)
                            .draggable(DroppedFileURL(url: item.url))
                            .dropDestination(for: DroppedFileURL.self) { items in
                                transferDroppedItems(items, into: item.url)
                            }
                    } else {
                        TableRow(item)
                            .dropDestination(for: DroppedFileURL.self) { items in
                                transferDroppedItems(items, into: item.url)
                            }
                    }
                } else {
                    TableRow(item)
                        .draggable(DroppedFileURL(url: item.url))
                }
            }
        }
        .contextMenu(forSelectionType: FileItem.ID.self) { selection in
            fileContextMenu(selection: selection)
        } primaryAction: { selection in
            open(selection: selection)
        }
        .onKeyPress(KeyEquivalent("/")) {
            onBeginFiltering()
            return .handled
        }
        .onKeyPress(.space) {
            onFocus()
            onQuickLook()
            return .handled
        }
        .onKeyPress(.return) {
            open(selection: viewModel.selectedItems)
            return .handled
        }
        .onKeyPress(.delete) {
            onFocus()
            viewModel.deleteSelected()
            return .handled
        }
    }

    @ViewBuilder
    private func fileContextMenu(selection: Set<FileItem.ID>) -> some View {
        let selectedItems = items(for: selection)

        Button("Open") {
            viewModel.selectForContextMenu(selection)
            open(selection: selection)
        }
        .disabled(selectedItems.isEmpty)

        if canChooseApplication(for: selectedItems) {
            let applications = FileOpeningService.shared.applications(for: selectedItems.map(\.url))
            Menu("Open With") {
                if applications.isEmpty {
                    Button("No Applications Available") {}
                        .disabled(true)
                } else {
                    ForEach(applications) { application in
                        Button {
                            onFocus()
                            viewModel.selectForContextMenu(selection)
                            viewModel.openItems(
                                selectedItems.map(\.url),
                                withApplicationAt: application.url
                            )
                        } label: {
                            Label {
                                Text(
                                    application.isDefault
                                        ? L10n.format("%@ (default)", application.name)
                                        : application.name
                                )
                            } icon: {
                                Image(nsImage: NSWorkspace.shared.icon(forFile: application.url.path))
                            }
                        }
                    }
                }

                Divider()

                Button("Other…") {
                    chooseApplication(for: selectedItems, selection: selection)
                }
            }
        }

        Button("Show in Finder") {
            onFocus()
            viewModel.selectForContextMenu(selection)
            NSWorkspace.shared.activateFileViewerSelecting(selectedItems.map(\.url))
        }
        .disabled(selectedItems.isEmpty)

        Divider()

        Button("Copy") {
            onFocus()
            viewModel.selectForContextMenu(selection)
            clipboard.copy(urls: selectedItems.map(\.url))
        }
        .disabled(selectedItems.isEmpty)

        Button("Cut") {
            onFocus()
            viewModel.selectForContextMenu(selection)
            clipboard.cut(urls: selectedItems.map(\.url))
        }
        .disabled(selectedItems.isEmpty)

        Button("Paste") {
            pasteFromClipboard()
        }
        .disabled(!clipboard.hasContent || !viewModel.canCreateItems)

        Divider()

        Button("Copy to Adjacent Pane") {
            onFocus()
            viewModel.selectForContextMenu(selection)
            onCopyToAdjacentPane(selectedItems.map(\.url))
        }
        .disabled(!canTransferToAdjacentPane(selectedItems.map(\.url), .copy))

        Button("Move to Adjacent Pane") {
            onFocus()
            viewModel.selectForContextMenu(selection)
            onMoveToAdjacentPane(selectedItems.map(\.url))
        }
        .disabled(!canTransferToAdjacentPane(selectedItems.map(\.url), .move))

        Divider()

        Button("Rename…") {
            guard let item = selectedItems.first else { return }
            onFocus()
            viewModel.selectForContextMenu(selection)
            onRename(item)
        }
        .disabled(selectedItems.count != 1)

        if selectedItems.count >= 2 {
            Button(L10n.format("Rename %lld Items…", Int64(selectedItems.count))) {
                onFocus()
                viewModel.selectForContextMenu(selection)
                viewModel.requestBatchRename()
            }
        }

        Divider()

        Button(compressTitle(for: selectedItems)) {
            onFocus()
            viewModel.selectForContextMenu(selection)
            viewModel.compressItems(selectedItems.map(\.url))
        }
        .disabled(selectedItems.isEmpty || !haveSameParent(selectedItems))

        if !selectedItems.isEmpty,
           selectedItems.allSatisfy({ FileOperationService.isExtractableArchive($0.url) && !$0.isDirectory }) {
            Button(extractTitle(for: selectedItems)) {
                onFocus()
                viewModel.selectForContextMenu(selection)
                viewModel.extractItems(selectedItems.map(\.url))
            }
        }

        Button("Move to Trash", role: .destructive) {
            onFocus()
            viewModel.selectForContextMenu(selection)
            viewModel.deleteSelected()
        }
        .disabled(selectedItems.isEmpty)
    }

    private func items(for ids: Set<FileItem.ID>) -> [FileItem] {
        viewModel.items.filter { ids.contains($0.id) }
    }

    private func compressTitle(for items: [FileItem]) -> String {
        items.count == 1
            ? L10n.format("Compress “%@”", items[0].name)
            : L10n.format("Compress %lld Items", Int64(items.count))
    }

    private func extractTitle(for items: [FileItem]) -> String {
        items.count == 1
            ? L10n.format("Extract “%@”", items[0].name)
            : L10n.format("Extract %lld Archives", Int64(items.count))
    }

    private func canChooseApplication(for items: [FileItem]) -> Bool {
        !items.isEmpty && items.allSatisfy { !$0.isDirectory }
    }

    private func chooseApplication(for items: [FileItem], selection: Set<FileItem.ID>) {
        let panel = NSOpenPanel()
        panel.title = L10n.string("Choose Application")
        panel.message = items.count == 1
            ? L10n.format("Choose an application to open “%@”.", items[0].name)
            : L10n.format("Choose an application to open these %lld files.", Int64(items.count))
        panel.prompt = L10n.string("Open")
        panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        panel.allowedContentTypes = [.applicationBundle]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.treatsFilePackagesAsDirectories = false

        panel.begin { response in
            guard response == .OK, let applicationURL = panel.url else { return }
            onFocus()
            viewModel.selectForContextMenu(selection)
            viewModel.openItems(items.map(\.url), withApplicationAt: applicationURL)
        }
    }

    private func haveSameParent(_ items: [FileItem]) -> Bool {
        guard let parent = items.first?.url.deletingLastPathComponent() else { return false }
        return items.allSatisfy { $0.url.deletingLastPathComponent() == parent }
    }

    private func open(selection: Set<FileItem.ID>) {
        onFocus()
        let selectedItems = items(for: selection)
        if selectedItems.count == 1, let item = selectedItems.first {
            viewModel.openItem(item)
        } else {
            selectedItems.forEach(viewModel.openItem)
        }
    }

    private func transferDroppedItems(_ items: [DroppedFileURL], into destination: URL) {
        onFocus()
        viewModel.transferDroppedItems(
            items.map(\.url),
            into: destination,
            operation: FileDropModifierKeys.currentOperation
        )
    }

    private func pasteFromClipboard() {
        onFocus()
        guard let payload = clipboard.payload else { return }
        if payload.isCut {
            viewModel.moveItems(from: payload.urls) { result in
                consumeMovedItems(from: payload, result: result)
            }
        } else {
            viewModel.copyItems(from: payload.urls)
        }
    }

    private func consumeMovedItems(from payload: FileClipboardPayload, result: FileOperationResult) {
        let completedSources = Set(result.completedOutcomes.map { $0.source.standardizedFileURL })
        guard !completedSources.isEmpty else { return }
        let remainingURLs = payload.urls.filter { !completedSources.contains($0.standardizedFileURL) }
        clipboard.consumeIfUnchanged(payload, remainingURLs: remainingURLs)
    }

    private var focusedSelection: Binding<Set<FileItem.ID>> {
        Binding(
            get: { viewModel.selectedItems },
            set: { selection in
                onFocus()
                viewModel.selectedItems = selection
            }
        )
    }

    private var focusedSortOrder: Binding<[FileItemComparator]> {
        Binding(
            get: { viewModel.sortOrder },
            set: { sortOrder in
                onFocus()
                viewModel.sortOrder = sortOrder
            }
        )
    }
}

enum FileDropModifierKeys {
    static var currentOperation: FileDropOperation {
        NSEvent.modifierFlags.contains(.option) ? .copy : .move
    }
}

struct DroppedFileURL: Transferable, Equatable, Sendable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(
            contentType: .multiFinderFileURL,
            exporting: { $0.url.dataRepresentation },
            importing: { data in try decode(data) }
        )
        DataRepresentation(
            contentType: .fileURL,
            exporting: { $0.url.dataRepresentation },
            importing: { data in try decode(data) }
        )
    }

    private static func decode(_ data: Data) throws -> DroppedFileURL {
        guard let url = URL(dataRepresentation: data, relativeTo: nil), url.isFileURL else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return DroppedFileURL(url: url)
    }
}

private extension UTType {
    static let multiFinderFileURL = UTType(
        exportedAs: "com.multifinder.dragged-file-url",
        conformingTo: .data
    )
}

enum DroppedFileURLLoader {
    static func load(_ providers: [NSItemProvider], completion: @escaping ([URL]) -> Void) {
        let collector = DroppedFileURLCollector()
        let group = DispatchGroup()

        for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            group.enter()
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                defer { group.leave() }
                if let url = fileURL(from: item) {
                    collector.append(url)
                }
            }
        }

        group.notify(queue: .main) {
            completion(collector.urls)
        }
    }

    static func fileURL(from item: Any?) -> URL? {
        if let url = item as? URL {
            return url
        }
        if let data = item as? Data {
            return URL(dataRepresentation: data, relativeTo: nil)
        }
        return nil
    }
}

private final class DroppedFileURLCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [URL] = []

    func append(_ url: URL) {
        lock.lock()
        storage.append(url)
        lock.unlock()
    }

    var urls: [URL] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}
