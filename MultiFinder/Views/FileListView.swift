import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct FileListView: View {
    @ObservedObject var viewModel: FileBrowserViewModel
    @ObservedObject private var clipboard = FileClipboard.shared
    let onQuickLook: () -> Void
    let onRename: (FileItem) -> Void

    var body: some View {
        Table(
            of: FileItem.self,
            selection: $viewModel.selectedItems,
            sortOrder: $viewModel.sortOrder
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
            ForEach(viewModel.items) { item in
                TableRow(item)
                    .itemProvider {
                        NSItemProvider(contentsOf: item.url)
                    }
            }
        }
        .contextMenu(forSelectionType: FileItem.ID.self) { selection in
            fileContextMenu(selection: selection)
        } primaryAction: { selection in
            open(selection: selection)
        }
        .onKeyPress(.space) {
            onQuickLook()
            return .handled
        }
        .onKeyPress(.return) {
            open(selection: viewModel.selectedItems)
            return .handled
        }
        .onKeyPress(.delete) {
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

        Button("Reveal in Finder") {
            viewModel.selectForContextMenu(selection)
            NSWorkspace.shared.activateFileViewerSelecting(selectedItems.map(\.url))
        }
        .disabled(selectedItems.isEmpty)

        Divider()

        Button("Copy") {
            viewModel.selectForContextMenu(selection)
            clipboard.copy(urls: selectedItems.map(\.url))
        }
        .disabled(selectedItems.isEmpty)

        Button("Cut") {
            viewModel.selectForContextMenu(selection)
            clipboard.cut(urls: selectedItems.map(\.url))
        }
        .disabled(selectedItems.isEmpty)

        Button("Paste") {
            pasteFromClipboard()
        }
        .disabled(!clipboard.hasContent || !viewModel.canCreateItems)

        Divider()

        Button("Rename…") {
            guard let item = selectedItems.first else { return }
            viewModel.selectForContextMenu(selection)
            onRename(item)
        }
        .disabled(selectedItems.count != 1)

        Button("Move to Trash", role: .destructive) {
            viewModel.selectForContextMenu(selection)
            viewModel.deleteSelected()
        }
        .disabled(selectedItems.isEmpty)
    }

    private func items(for ids: Set<FileItem.ID>) -> [FileItem] {
        viewModel.items.filter { ids.contains($0.id) }
    }

    private func open(selection: Set<FileItem.ID>) {
        let selectedItems = items(for: selection)
        if selectedItems.count == 1, let item = selectedItems.first {
            viewModel.openItem(item)
        } else {
            selectedItems.forEach(viewModel.openItem)
        }
    }

    private func pasteFromClipboard() {
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
}
