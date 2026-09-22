import AppKit
import SwiftUI

struct FileGalleryView: View {
    @ObservedObject var viewModel: FileBrowserViewModel
    @ObservedObject private var gitPulse = GitPulseStore.shared

    let canTransferToAdjacentPane: ([URL], FileDropOperation) -> Bool
    let onFocus: () -> Void
    let onBeginFiltering: () -> Void
    let onQuickLook: () -> Void
    let onRename: (FileItem) -> Void
    let onGetInfo: () -> Void
    let onCopyToAdjacentPane: ([URL]) -> Void
    let onMoveToAdjacentPane: ([URL]) -> Void

    @State private var selectionAnchor: FileItem.ID?
    @State private var selectionCursor: FileItem.ID?
    @State private var dropTargetID: FileItem.ID?
    @FocusState private var hasKeyboardFocus: Bool

    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                if geometry.size.height >= 220 {
                    FileSelectionPreview(
                        viewModel: viewModel,
                        onQuickLook: onQuickLook,
                        onGetInfo: onGetInfo
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                    Divider()
                }

                filmstrip
                    .frame(
                        height: geometry.size.height >= 220
                            ? min(max(geometry.size.height * 0.34, 122), 168)
                            : geometry.size.height
                    )
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
        .onChange(of: viewModel.location) { _, _ in
            selectionAnchor = nil
            selectionCursor = nil
            dropTargetID = nil
        }
        .onChange(of: viewModel.tableRevision) { _, _ in
            let visibleIDs = Set(viewModel.visibleItems.map(\.id))
            if let selectionAnchor, !visibleIDs.contains(selectionAnchor) {
                self.selectionAnchor = nil
            }
            if let selectionCursor, !visibleIDs.contains(selectionCursor) {
                self.selectionCursor = nil
            }
            if let dropTargetID, !visibleIDs.contains(dropTargetID) {
                self.dropTargetID = nil
            }
        }
        .onChange(of: viewModel.selectedItems) { _, selection in
            if selection.isEmpty {
                selectionAnchor = nil
                selectionCursor = nil
            }
        }
    }

    private var filmstrip: some View {
        ScrollViewReader { scrollProxy in
            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: 8) {
                    let gitIndex = gitPulse.cachedChangeIndex(for: viewModel.currentURL)
                    ForEach(viewModel.visibleItems) { item in
                        galleryCell(for: item, gitIndex: gitIndex)
                            .id(item.id)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .frame(minWidth: 1, maxHeight: .infinity, alignment: .leading)
            }
            .scrollIndicators(.visible)
            .background(Color(nsColor: .textBackgroundColor))
            .focusable()
            .focusEffectDisabled()
            .focused($hasKeyboardFocus)
            .contextMenu {
                FinderItemsContextMenu(
                    viewModel: viewModel,
                    selection: viewModel.selectedItems,
                    canTransferToAdjacentPane: canTransferToAdjacentPane,
                    onFocus: focusGallery,
                    onQuickLook: onQuickLook,
                    onRename: onRename,
                    onGetInfo: onGetInfo,
                    onCopyToAdjacentPane: onCopyToAdjacentPane,
                    onMoveToAdjacentPane: onMoveToAdjacentPane
                )
            }
            .onKeyPress(KeyEquivalent("/")) {
                onBeginFiltering()
                return .handled
            }
            .onKeyPress(.space) {
                focusGallery()
                onQuickLook()
                return .handled
            }
            .onKeyPress(.return, phases: .down) { _ in
                guard let item = viewModel.selectedItem else { return .ignored }
                focusGallery()
                onRename(item)
                return .handled
            }
            .onKeyPress(KeyEquivalent("o"), phases: .down) { keyPress in
                guard keyPress.modifiers.contains(.command) else { return .ignored }
                open(selection: viewModel.selectedItems)
                return .handled
            }
            .onKeyPress(KeyEquivalent("a"), phases: .down) { keyPress in
                guard keyPress.modifiers.contains(.command) else { return .ignored }
                focusGallery()
                viewModel.selectAll()
                selectionAnchor = viewModel.visibleItems.first?.id
                selectionCursor = viewModel.visibleItems.last?.id
                return .handled
            }
            .onKeyPress(.delete, phases: .down) { keyPress in
                guard keyPress.modifiers.contains(.command) else { return .ignored }
                focusGallery()
                viewModel.deleteSelected()
                return .handled
            }
            .onKeyPress(.leftArrow, phases: .down) { keyPress in
                moveSelection(by: -1, modifiers: keyPress.modifiers, scrollProxy: scrollProxy)
            }
            .onKeyPress(.rightArrow, phases: .down) { keyPress in
                moveSelection(by: 1, modifiers: keyPress.modifiers, scrollProxy: scrollProxy)
            }
        }
    }

    @ViewBuilder
    private func galleryCell(for item: FileItem, gitIndex: GitChangeIndex?) -> some View {
        if item.isDirectory && !item.isPackage {
            baseCell(for: item, gitIndex: gitIndex)
                .onDrag { dragProvider(for: item) }
                .dropDestination(
                    for: DroppedFileURL.self,
                    action: { droppedItems, _ in
                        transferDroppedItems(droppedItems, into: item.url)
                    },
                    isTargeted: { targeted in
                        dropTargetID = targeted ? item.id : nil
                    }
                )
        } else if FileDropSafety.canStartDragging(item) {
            baseCell(for: item, gitIndex: gitIndex).onDrag { dragProvider(for: item) }
        } else {
            baseCell(for: item, gitIndex: gitIndex)
        }
    }

    private func baseCell(for item: FileItem, gitIndex: GitChangeIndex?) -> some View {
        FileGalleryCell(
            item: item,
            gitChange: gitIndex?.changeType(for: item.url),
            isSelected: viewModel.selectedItems.contains(item.id),
            isDropTargeted: dropTargetID == item.id,
            onSelect: { select(item, modifiers: $0) },
            onDoubleClick: { open(item: item) }
        )
        .contextMenu {
            FinderItemsContextMenu(
                viewModel: viewModel,
                selection: contextSelection(for: item),
                canTransferToAdjacentPane: canTransferToAdjacentPane,
                onFocus: focusGallery,
                onQuickLook: onQuickLook,
                onRename: onRename,
                onGetInfo: onGetInfo,
                onCopyToAdjacentPane: onCopyToAdjacentPane,
                onMoveToAdjacentPane: onMoveToAdjacentPane
            )
        }
    }

    private func focusGallery() {
        onFocus()
        hasKeyboardFocus = true
    }

    private func select(_ item: FileItem, modifiers: EventModifiers) {
        focusGallery()
        let visibleItems = viewModel.visibleItems
        guard let itemIndex = visibleItems.firstIndex(where: { $0.id == item.id }) else { return }
        let isCommandDown = modifiers.contains(.command)
        let isShiftDown = modifiers.contains(.shift)

        if isShiftDown {
            let anchorIndex = selectionAnchor.flatMap { anchor in
                visibleItems.firstIndex { $0.id == anchor }
            } ?? visibleItems.firstIndex { viewModel.selectedItems.contains($0.id) } ?? itemIndex
            let range = min(anchorIndex, itemIndex)...max(anchorIndex, itemIndex)
            let rangeSelection = Set(visibleItems[range].map(\.id))
            viewModel.selectedItems = isCommandDown
                ? viewModel.selectedItems.union(rangeSelection)
                : rangeSelection
            if selectionAnchor == nil {
                selectionAnchor = visibleItems[anchorIndex].id
            }
        } else if isCommandDown {
            if viewModel.selectedItems.contains(item.id) {
                viewModel.selectedItems.remove(item.id)
            } else {
                viewModel.selectedItems.insert(item.id)
            }
            selectionAnchor = item.id
        } else {
            viewModel.selectedItems = [item.id]
            selectionAnchor = item.id
        }
        selectionCursor = item.id
    }

    private func moveSelection(
        by delta: Int,
        modifiers: EventModifiers,
        scrollProxy: ScrollViewProxy
    ) -> KeyPress.Result {
        guard !modifiers.contains(.command),
              !modifiers.contains(.option),
              !modifiers.contains(.control) else { return .ignored }

        let visibleItems = viewModel.visibleItems
        guard !visibleItems.isEmpty else { return .ignored }
        let currentIndex = selectionCursor.flatMap { cursor in
            visibleItems.firstIndex { $0.id == cursor }
        } ?? visibleItems.firstIndex { viewModel.selectedItems.contains($0.id) }
        let targetIndex = currentIndex.map { $0 + delta } ?? 0
        guard visibleItems.indices.contains(targetIndex) else { return .handled }

        let target = visibleItems[targetIndex]
        focusGallery()
        if modifiers.contains(.shift) {
            let anchorIndex = selectionAnchor.flatMap { anchor in
                visibleItems.firstIndex { $0.id == anchor }
            } ?? currentIndex ?? targetIndex
            let range = min(anchorIndex, targetIndex)...max(anchorIndex, targetIndex)
            viewModel.selectedItems = Set(visibleItems[range].map(\.id))
            if selectionAnchor == nil {
                selectionAnchor = visibleItems[anchorIndex].id
            }
        } else {
            viewModel.selectedItems = [target.id]
            selectionAnchor = target.id
        }
        selectionCursor = target.id
        scrollProxy.scrollTo(target.id, anchor: .center)
        return .handled
    }

    private func open(item: FileItem) {
        focusGallery()
        if !viewModel.selectedItems.contains(item.id) {
            viewModel.selectedItems = [item.id]
            selectionAnchor = item.id
        }
        selectionCursor = item.id
        viewModel.openItem(item)
    }

    private func open(selection: Set<FileItem.ID>) {
        focusGallery()
        let selectedItems = viewModel.items.filter { selection.contains($0.id) }
        if selectedItems.count == 1, let item = selectedItems.first {
            viewModel.openItem(item)
        } else {
            selectedItems.forEach(viewModel.openItem)
        }
    }

    private func contextSelection(for item: FileItem) -> Set<FileItem.ID> {
        viewModel.selectedItems.contains(item.id) ? viewModel.selectedItems : [item.id]
    }

    private func dragProvider(for item: FileItem) -> NSItemProvider {
        focusGallery()
        if !viewModel.selectedItems.contains(item.id) {
            viewModel.selectedItems = [item.id]
            selectionAnchor = item.id
        }
        selectionCursor = item.id
        let draggedItems = viewModel.selectedItems.contains(item.id)
            ? viewModel.selectedFileItems
            : [item]
        return FileDragProvider.provider(
            for: draggedItems.map(\.url),
            primaryIsDirectory: draggedItems.first?.isDirectory == true && draggedItems.first?.isPackage != true
        ) ?? NSItemProvider(object: item.url as NSURL)
    }

    private func transferDroppedItems(_ items: [DroppedFileURL], into destination: URL) -> Bool {
        let urls = items.flatMap(\.urls)
        guard !urls.isEmpty else { return false }
        focusGallery()
        dropTargetID = nil
        return viewModel.transferDroppedItems(
            urls,
            into: destination,
            operation: FileDropModifierKeys.operation(for: urls, into: destination)
        )
    }
}

private struct FileGalleryCell: View {
    let item: FileItem
    let gitChange: GitFileChange.ChangeType?
    let isSelected: Bool
    let isDropTargeted: Bool
    let onSelect: (EventModifiers) -> Void
    let onDoubleClick: () -> Void

    var body: some View {
        interactiveCell
            .accessibilityElement(children: .combine)
            .accessibilityLabel(item.name)
            .accessibilityValue(item.kind)
            .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var interactiveCell: some View {
        styledCell
            .contentShape(RoundedRectangle(cornerRadius: 6))
            .fileSelectionGestures(onSelect: onSelect, onDoubleClick: onDoubleClick)
    }

    private var styledCell: some View {
        cellContent
            .padding(.horizontal, 5)
            .padding(.vertical, 5)
            .frame(width: 104, height: 116, alignment: .top)
            .background(selectionBackground)
            .overlay(selectionBorder)
    }

    private var cellContent: some View {
        VStack(spacing: 5) {
            thumbnail

            HStack(spacing: 3) {
                if let gitChange {
                    GitChangeBadge(change: gitChange)
                }
                Text(item.name)
                    .font(.system(size: 10))
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .truncationMode(.middle)
            }
            .frame(width: 92)
            .frame(minHeight: 25, maxHeight: 25, alignment: .top)
        }
    }

    private var thumbnail: some View {
        ZStack(alignment: .bottomTrailing) {
            FinderThumbnailView(item: item, size: CGSize(width: 84, height: 76))
                .frame(width: 84, height: 76)

            if item.isSymlink {
                Image(systemName: "arrowshape.turn.up.right.fill")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(2)
                    .background(.regularMaterial, in: Circle())
            }
        }
    }

    private var selectionBackground: some View {
        RoundedRectangle(cornerRadius: 6)
            .fill(isSelected ? Color.accentColor.opacity(0.18) : .clear)
    }

    private var selectionBorder: some View {
        RoundedRectangle(cornerRadius: 6)
            .stroke(borderColor, lineWidth: isDropTargeted ? 2 : 1)
    }

    private var borderColor: Color {
        if isDropTargeted { return .accentColor }
        return isSelected ? Color.accentColor.opacity(0.65) : .clear
    }
}
