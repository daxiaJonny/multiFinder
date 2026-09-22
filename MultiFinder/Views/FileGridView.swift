import AppKit
import SwiftUI

fileprivate let fileGridCoordinateSpaceName = "MultiFinder.FileGrid"

struct FileGridView: View {
    @ObservedObject var viewModel: FileBrowserViewModel
    @ObservedObject private var clipboard: FileClipboard
    @ObservedObject private var gitPulse = GitPulseStore.shared

    let canTransferToAdjacentPane: ([URL], FileDropOperation) -> Bool
    let onFocus: () -> Void
    let onBeginFiltering: () -> Void
    let onQuickLook: () -> Void
    let onRename: (FileItem) -> Void
    let onGetInfo: () -> Void
    let onCopyToAdjacentPane: ([URL]) -> Void
    let onMoveToAdjacentPane: ([URL]) -> Void

    @State private var keyboardFocusRequest = 0
    @State private var selectionAnchor: FileItem.ID?
    @State private var selectionCursor: FileItem.ID?
    @State private var dropTargetID: FileItem.ID?
    @State private var cellFrames: [FileItem.ID: CGRect] = [:]
    @State private var marqueeStartLocation: CGPoint?
    @State private var marqueeRect: CGRect?
    @State private var marqueeInitialSelection: Set<FileItem.ID> = []
    @State private var marqueeUsesCommand = false
    @State private var inlineRenameItem: FileItem?
    @State private var inlineRenameDraft = ""

    private static let thumbnailSize = CGSize(width: 72, height: 72)
    private static let gridHorizontalPadding: CGFloat = 14
    private static let gridMinimumCellWidth: CGFloat = 88
    private static let gridSpacing: CGFloat = 12

    init(
        viewModel: FileBrowserViewModel,
        canTransferToAdjacentPane: @escaping ([URL], FileDropOperation) -> Bool,
        onFocus: @escaping () -> Void,
        onBeginFiltering: @escaping () -> Void,
        onQuickLook: @escaping () -> Void,
        onRename: @escaping (FileItem) -> Void,
        onGetInfo: @escaping () -> Void,
        onCopyToAdjacentPane: @escaping ([URL]) -> Void,
        onMoveToAdjacentPane: @escaping ([URL]) -> Void
    ) {
        self.viewModel = viewModel
        self.canTransferToAdjacentPane = canTransferToAdjacentPane
        self.onFocus = onFocus
        self.onBeginFiltering = onBeginFiltering
        self.onQuickLook = onQuickLook
        self.onRename = onRename
        self.onGetInfo = onGetInfo
        self.onCopyToAdjacentPane = onCopyToAdjacentPane
        self.onMoveToAdjacentPane = onMoveToAdjacentPane
        _clipboard = ObservedObject(wrappedValue: FileClipboard.shared)
    }

    var body: some View {
        let gitIndex = gitPulse.cachedChangeIndex(for: viewModel.currentURL)
        VirtualFileGrid(
            items: viewModel.visibleItems,
            itemsRevision: viewModel.itemsRevision,
            selection: viewModel.selectedItems,
            gitIndex: gitIndex,
            gitGeneration: gitPulse.generation,
            onSelection: { selection in
                onFocus()
                viewModel.selectedItems = selection
            },
            onOpen: { item in
                onFocus()
                viewModel.openItem(item)
            },
            onFocus: onFocus,
            onQuickLook: {
                onFocus()
                onQuickLook()
            },
            onBeginFiltering: onBeginFiltering,
            onDelete: {
                onFocus()
                viewModel.deleteSelected()
            },
            onDrop: { urls, destination in
                onFocus()
                viewModel.transferDroppedItems(
                    urls,
                    into: destination,
                    operation: FileDropModifierKeys.operation(for: urls, into: destination)
                )
            }
        )
        .contextMenu {
            fileContextMenu(selection: viewModel.selectedItems)
        }
    }

    private static func columnCount(for width: CGFloat) -> Int {
        let contentWidth = max(width - (gridHorizontalPadding * 2), gridMinimumCellWidth)
        return max(
            1,
            Int((contentWidth + gridSpacing) / (gridMinimumCellWidth + gridSpacing))
        )
    }

    private static func gridColumns(for width: CGFloat) -> [GridItem] {
        Array(
            repeating: GridItem(
                .flexible(minimum: gridMinimumCellWidth, maximum: 112),
                spacing: gridSpacing,
                alignment: .top
            ),
            count: columnCount(for: width)
        )
    }

    @ViewBuilder
    private func gridCell(for item: FileItem, gitIndex: GitChangeIndex?) -> some View {
        let contextSelection = selectionForContextMenu(for: item)
        let base = FileGridCell(
            item: item,
            thumbnailSize: Self.thumbnailSize,
            isSelected: viewModel.selectedItems.contains(item.id),
            isDropTargeted: dropTargetID == item.id,
            gitChange: gitIndex?.changeType(for: item.url),
            isRenaming: inlineRenameItem?.id == item.id,
            renameText: Binding(
                get: { inlineRenameDraft },
                set: { inlineRenameDraft = $0 }
            ),
            onSelect: { select(item, modifiers: $0) },
            onDoubleClick: { open(item: item) },
            onCommitRename: { newName in
                finishInlineRename(commit: true, submittedName: newName)
            },
            onCancelRename: { finishInlineRename(commit: false) }
        )
        .contextMenu {
            fileContextMenu(selection: contextSelection)
        }

        if item.isDirectory && !item.isPackage {
            base
                .onDrag { beginDragging(item) }
                .dropDestination(
                    for: DroppedFileURL.self,
                    action: { droppedItems, _ in
                        transferDroppedItems(droppedItems, into: item.url)
                    },
                    isTargeted: { isTargeted in
                        updateDropTarget(item, isTargeted: isTargeted)
                    }
                )
        } else if FileDropSafety.canStartDragging(item) {
            base.onDrag { beginDragging(item) }
        } else {
            base
        }
    }

    private func focusGrid() {
        keyboardFocusRequest &+= 1
        onFocus()
    }

    private func handleKeyDown(
        _ event: NSEvent,
        columns: Int,
        scrollProxy: ScrollViewProxy
    ) -> Bool {
        guard inlineRenameItem == nil else { return false }

        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let hasCommand = flags.contains(.command)
        let hasOption = flags.contains(.option)
        let hasControl = flags.contains(.control)
        let characters = event.charactersIgnoringModifiers?.lowercased()

        if characters == "/", !hasCommand, !hasOption, !hasControl {
            onBeginFiltering()
            return true
        }

        if event.keyCode == 49, !hasCommand, !hasOption, !hasControl {
            onQuickLook()
            return true
        }

        if (event.keyCode == 36 || event.keyCode == 76),
           !hasCommand,
           !hasOption,
           !hasControl,
           let item = singleSelectedItem {
            startInlineRename(item)
            return true
        }

        if characters == "o", hasCommand {
            open(selection: viewModel.selectedItems)
            return true
        }

        if (event.keyCode == 51 || event.keyCode == 117), hasCommand {
            focusGrid()
            viewModel.deleteSelected()
            return true
        }

        if characters == "a", hasCommand {
            focusGrid()
            viewModel.selectAll()
            selectionAnchor = viewModel.visibleItems.first?.id
            selectionCursor = viewModel.visibleItems.last?.id
            return true
        }

        guard !hasCommand, !hasOption, !hasControl,
              let key = arrowKey(for: event.keyCode) else { return false }
        return moveSelection(
            for: key,
            columns: columns,
            modifiers: eventModifiers(from: flags),
            scrollProxy: scrollProxy
        ) == .handled
    }

    private func arrowKey(for keyCode: UInt16) -> KeyEquivalent? {
        switch keyCode {
        case 123: return .leftArrow
        case 124: return .rightArrow
        case 125: return .downArrow
        case 126: return .upArrow
        default: return nil
        }
    }

    private func eventModifiers(from flags: NSEvent.ModifierFlags) -> EventModifiers {
        var modifiers: EventModifiers = []
        if flags.contains(.shift) { modifiers.insert(.shift) }
        if flags.contains(.command) { modifiers.insert(.command) }
        if flags.contains(.option) { modifiers.insert(.option) }
        if flags.contains(.control) { modifiers.insert(.control) }
        return modifiers
    }

    private func select(_ item: FileItem, modifiers: EventModifiers) {
        focusGrid()

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
            selectionCursor = item.id
        } else if isCommandDown {
            var nextSelection = viewModel.selectedItems
            if nextSelection.contains(item.id) {
                nextSelection.remove(item.id)
            } else {
                nextSelection.insert(item.id)
            }
            viewModel.selectedItems = nextSelection
            selectionAnchor = item.id
            selectionCursor = item.id
        } else {
            viewModel.selectedItems = [item.id]
            selectionAnchor = item.id
            selectionCursor = item.id
        }
    }

    private var singleSelectedItem: FileItem? {
        guard viewModel.selectedItems.count == 1 else { return nil }
        return viewModel.selectedFileItems.first
    }

    private func startInlineRename(_ item: FileItem) {
        guard inlineRenameItem == nil else { return }
        viewModel.selectedItems = [item.id]
        selectionAnchor = item.id
        selectionCursor = item.id
        inlineRenameDraft = item.name
        inlineRenameItem = item
    }

    private func finishInlineRename(commit: Bool, submittedName: String? = nil) {
        guard let item = inlineRenameItem else { return }
        let newName = submittedName ?? inlineRenameDraft
        inlineRenameItem = nil
        inlineRenameDraft = ""
        focusGrid()

        guard commit, newName != item.name else { return }
        viewModel.rename(item: item, to: newName)
    }

    private func updateMarquee(for value: DragGesture.Value) {
        if marqueeStartLocation == nil {
            guard !isInsideCell(value.startLocation) else { return }
            marqueeStartLocation = value.startLocation
            marqueeInitialSelection = viewModel.selectedItems
            marqueeUsesCommand = NSApp?.currentEvent?.modifierFlags.contains(.command) == true
            focusGrid()
        }

        updateMarquee(to: value.location)
    }

    private func updateMarquee(to point: CGPoint) {
        guard let marqueeStartLocation else { return }
        let nextRect = makeMarqueeRect(from: marqueeStartLocation, to: point)
        marqueeRect = nextRect

        let intersectedIDs = Set<FileItem.ID>(
            viewModel.visibleItems.compactMap { item in
                guard let frame = cellFrames[item.id], frame.intersects(nextRect) else {
                    return nil
                }
                return item.id
            }
        )
        let nextSelection = marqueeUsesCommand
            ? marqueeInitialSelection.symmetricDifference(intersectedIDs)
            : intersectedIDs
        applyMarqueeSelection(nextSelection)
    }

    private func endMarquee(at point: CGPoint) {
        guard marqueeStartLocation != nil else { return }
        updateMarquee(to: point)
        marqueeStartLocation = nil
        marqueeRect = nil
        marqueeInitialSelection = []
        marqueeUsesCommand = false
    }

    private func makeMarqueeRect(from start: CGPoint, to end: CGPoint) -> CGRect {
        CGRect(
            x: min(start.x, end.x),
            y: min(start.y, end.y),
            width: abs(end.x - start.x),
            height: abs(end.y - start.y)
        )
    }

    private func isInsideCell(_ point: CGPoint) -> Bool {
        cellFrames.values.contains { $0.insetBy(dx: -1, dy: -1).contains(point) }
    }

    private func applyMarqueeSelection(_ selection: Set<FileItem.ID>) {
        if viewModel.selectedItems != selection {
            viewModel.selectedItems = selection
        }
        let orderedSelection = viewModel.visibleItems.filter { selection.contains($0.id) }
        guard !orderedSelection.isEmpty else {
            selectionAnchor = nil
            selectionCursor = nil
            return
        }

        if !marqueeUsesCommand {
            selectionAnchor = orderedSelection.first?.id
        } else if let selectionAnchor,
                  selection.contains(selectionAnchor) == false {
            self.selectionAnchor = orderedSelection.first?.id
        } else if self.selectionAnchor == nil {
            selectionAnchor = orderedSelection.first?.id
        }
        selectionCursor = orderedSelection.last?.id
    }

    private func selectItemForContextMenu(at point: CGPoint) {
        guard let item = viewModel.visibleItems.first(where: { item in
            guard let frame = cellFrames[item.id] else { return false }
            return frame.insetBy(dx: -1, dy: -1).contains(point)
        }) else {
            guard !viewModel.selectedItems.isEmpty else { return }
            focusGrid()
            viewModel.selectedItems.removeAll()
            selectionAnchor = nil
            selectionCursor = nil
            return
        }
        guard !viewModel.selectedItems.contains(item.id) else { return }

        focusGrid()
        viewModel.selectedItems = [item.id]
        selectionAnchor = item.id
        selectionCursor = item.id
    }

    private func clearSelectionIfBlank(at point: CGPoint) {
        guard !cellFrames.isEmpty,
              !cellFrames.values.contains(where: { $0.insetBy(dx: -1, dy: -1).contains(point) }),
              !viewModel.selectedItems.isEmpty else { return }
        focusGrid()
        viewModel.selectedItems.removeAll()
        selectionAnchor = nil
        selectionCursor = nil
    }

    private func moveSelection(
        for key: KeyEquivalent,
        columns: Int,
        modifiers: EventModifiers,
        scrollProxy: ScrollViewProxy
    ) -> KeyPress.Result {
        if modifiers.contains(.command)
            || modifiers.contains(.option)
            || modifiers.contains(.control) {
            return .ignored
        }

        let visibleItems = viewModel.visibleItems
        guard !visibleItems.isEmpty else { return .ignored }

        let delta: Int
        switch key {
        case .leftArrow:
            delta = -1
        case .rightArrow:
            delta = 1
        case .upArrow:
            delta = -max(columns, 1)
        case .downArrow:
            delta = max(columns, 1)
        default:
            return .ignored
        }

        let currentIndex = selectionCursor.flatMap { cursor in
            visibleItems.firstIndex { $0.id == cursor }
        } ?? selectionAnchor.flatMap { anchor in
            visibleItems.firstIndex { $0.id == anchor }
        } ?? visibleItems.firstIndex { viewModel.selectedItems.contains($0.id) }
        let targetIndex: Int
        if let currentIndex {
            targetIndex = currentIndex + delta
        } else {
            targetIndex = 0
        }

        guard visibleItems.indices.contains(targetIndex) else { return .handled }
        let target = visibleItems[targetIndex]
        let isShiftDown = modifiers.contains(.shift)
        let isCommandDown = modifiers.contains(.command)

        focusGrid()
        if isShiftDown {
            let anchorIndex = selectionAnchor.flatMap { anchor in
                visibleItems.firstIndex { $0.id == anchor }
            } ?? currentIndex ?? targetIndex
            let range = min(anchorIndex, targetIndex)...max(anchorIndex, targetIndex)
            let rangeSelection = Set(visibleItems[range].map(\.id))
            viewModel.selectedItems = isCommandDown
                ? viewModel.selectedItems.union(rangeSelection)
                : rangeSelection
            if selectionAnchor == nil {
                selectionAnchor = visibleItems[anchorIndex].id
            }
        } else {
            viewModel.selectedItems = [target.id]
            selectionAnchor = target.id
        }
        selectionCursor = target.id
        scrollProxy.scrollTo(target.id, anchor: nil)
        return .handled
    }

    private func open(item: FileItem) {
        focusGrid()
        if !viewModel.selectedItems.contains(item.id) {
            viewModel.selectedItems = [item.id]
            selectionAnchor = item.id
        }
        selectionCursor = item.id
        viewModel.openItem(item)
    }

    private func open(selection: Set<FileItem.ID>) {
        focusGrid()
        let selectedItems = items(for: selection)
        if selectedItems.count == 1, let item = selectedItems.first {
            viewModel.openItem(item)
        } else {
            selectedItems.forEach(viewModel.openItem)
        }
    }

    private func beginDragging(_ item: FileItem) -> NSItemProvider {
        focusGrid()
        if !viewModel.selectedItems.contains(item.id) {
            viewModel.selectedItems = [item.id]
            selectionAnchor = item.id
        }
        selectionCursor = item.id

        let dragItems = viewModel.selectedItems.contains(item.id)
            ? viewModel.selectedFileItems
            : [item]
        return FileDragProvider.provider(
            for: dragItems.map(\.url),
            primaryIsDirectory: dragItems.first?.isDirectory == true && dragItems.first?.isPackage != true
        ) ?? NSItemProvider(object: item.url as NSURL)
    }

    private func updateDropTarget(_ item: FileItem, isTargeted: Bool) {
        if isTargeted {
            dropTargetID = item.id
        } else if dropTargetID == item.id {
            dropTargetID = nil
        }
    }

    @discardableResult
    private func transferDroppedItems(_ items: [DroppedFileURL], into destination: URL) -> Bool {
        let urls = items.flatMap(\.urls)
        guard !urls.isEmpty else { return false }
        focusGrid()
        dropTargetID = nil
        return viewModel.transferDroppedItems(
            urls,
            into: destination,
            operation: FileDropModifierKeys.operation(for: urls, into: destination)
        )
    }

    @ViewBuilder
    private func fileContextMenu(selection: Set<FileItem.ID>) -> some View {
        let selectedItems = items(for: selection)
        let pasteDestination = viewModel.pasteDestination(for: selection)

        Button("Open") {
            viewModel.selectForContextMenu(selection)
            open(selection: selection)
        }
        .disabled(selectedItems.isEmpty)

        Button("Quick Look") {
            focusGrid()
            viewModel.selectForContextMenu(selection)
            onQuickLook()
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
                            focusGrid()
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
            focusGrid()
            viewModel.selectForContextMenu(selection)
            NSWorkspace.shared.activateFileViewerSelecting(selectedItems.map(\.url))
        }
        .disabled(selectedItems.isEmpty)

        Button("Get Info") {
            focusGrid()
            viewModel.selectForContextMenu(selection)
            onGetInfo()
        }
        .disabled(selectedItems.isEmpty)

        Divider()

        Button("Copy") {
            focusGrid()
            viewModel.selectForContextMenu(selection)
            clipboard.copy(urls: selectedItems.map(\.url))
        }
        .disabled(selectedItems.isEmpty)

        CopyPathMenu(urls: selectedItems.map(\.url))

        Button("Cut") {
            focusGrid()
            viewModel.selectForContextMenu(selection)
            clipboard.cut(urls: selectedItems.map(\.url))
        }
        .disabled(selectedItems.isEmpty)

        Button("Paste") {
            pasteFromClipboard(into: pasteDestination)
        }
        .disabled(!clipboard.hasContent || pasteDestination == nil)

        Button("Duplicate") {
            focusGrid()
            viewModel.selectForContextMenu(selection)
            viewModel.duplicateSelected()
        }
        .disabled(selectedItems.isEmpty || !viewModel.canCreateItems)

        Divider()

        Button("Copy to Adjacent Pane") {
            focusGrid()
            viewModel.selectForContextMenu(selection)
            onCopyToAdjacentPane(selectedItems.map(\.url))
        }
        .disabled(!canTransferToAdjacentPane(selectedItems.map(\.url), .copy))

        Button("Move to Adjacent Pane") {
            focusGrid()
            viewModel.selectForContextMenu(selection)
            onMoveToAdjacentPane(selectedItems.map(\.url))
        }
        .disabled(!canTransferToAdjacentPane(selectedItems.map(\.url), .move))

        Divider()

        Button("Rename…") {
            guard let item = selectedItems.first else { return }
            focusGrid()
            viewModel.selectForContextMenu(selection)
            startInlineRename(item)
        }
        .disabled(selectedItems.count != 1)

        if selectedItems.count >= 2 {
            Button(L10n.format("Rename %lld Items…", Int64(selectedItems.count))) {
                focusGrid()
                viewModel.selectForContextMenu(selection)
                viewModel.requestBatchRename()
            }
        }

        Divider()

        Button(compressTitle(for: selectedItems)) {
            focusGrid()
            viewModel.selectForContextMenu(selection)
            viewModel.compressItems(selectedItems.map(\.url))
        }
        .disabled(selectedItems.isEmpty || !haveSameParent(selectedItems))

        if !selectedItems.isEmpty,
           selectedItems.allSatisfy({ FileOperationService.isExtractableArchive($0.url) && !$0.isDirectory }) {
            Button(extractTitle(for: selectedItems)) {
                focusGrid()
                viewModel.selectForContextMenu(selection)
                viewModel.extractItems(selectedItems.map(\.url))
            }
        }

        Button("Move to Trash", role: .destructive) {
            focusGrid()
            viewModel.selectForContextMenu(selection)
            viewModel.deleteSelected()
        }
        .disabled(selectedItems.isEmpty)
    }

    private func selectionForContextMenu(for item: FileItem) -> Set<FileItem.ID> {
        viewModel.selectedItems.contains(item.id) ? viewModel.selectedItems : [item.id]
    }

    private func items(for ids: Set<FileItem.ID>) -> [FileItem] {
        viewModel.items.filter { ids.contains($0.id) }
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
            focusGrid()
            viewModel.selectForContextMenu(selection)
            viewModel.openItems(items.map(\.url), withApplicationAt: applicationURL)
        }
    }

    private func haveSameParent(_ items: [FileItem]) -> Bool {
        guard let parent = items.first?.url.deletingLastPathComponent() else { return false }
        return items.allSatisfy { $0.url.deletingLastPathComponent() == parent }
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

    private func pasteFromClipboard(into destination: URL?) {
        focusGrid()
        guard let destination, let payload = clipboard.payload else { return }
        if payload.isCut {
            viewModel.moveItems(from: payload.urls, to: destination) { result in
                consumeMovedItems(from: payload, result: result)
            }
        } else {
            viewModel.copyItems(from: payload.urls, to: destination)
        }
    }

    private func consumeMovedItems(from payload: FileClipboardPayload, result: FileOperationResult) {
        let completedSources = Set(result.completedOutcomes.map { $0.source.standardizedFileURL })
        guard !completedSources.isEmpty else { return }
        let remainingURLs = payload.urls.filter { !completedSources.contains($0.standardizedFileURL) }
        clipboard.consumeIfUnchanged(payload, remainingURLs: remainingURLs)
    }
}

private struct FileGridKeyboardFocusView: NSViewRepresentable {
    let focusRequest: Int
    let shouldFocus: Bool
    let onKeyDown: (NSEvent) -> Bool

    func makeNSView(context: Context) -> KeyView {
        let view = KeyView()
        view.setAccessibilityElement(false)
        return view
    }

    func updateNSView(_ nsView: KeyView, context: Context) {
        nsView.onKeyDown = onKeyDown
        nsView.updateFocusRequest(focusRequest, shouldFocus: shouldFocus)
    }

    @MainActor
    final class KeyView: NSView {
        var onKeyDown: ((NSEvent) -> Bool)?
        private var focusRequest = 0
        private var appliedFocusRequest = 0
        private var pendingFocusRequest: Int?
        private var shouldFocus = false

        override var acceptsFirstResponder: Bool { true }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            requestFocusIfNeeded()
        }

        override func keyDown(with event: NSEvent) {
            guard onKeyDown?(event) != true else { return }
            super.keyDown(with: event)
        }

        func updateFocusRequest(_ request: Int, shouldFocus: Bool) {
            focusRequest = request
            self.shouldFocus = shouldFocus
            if !shouldFocus {
                pendingFocusRequest = nil
            }
            requestFocusIfNeeded()
        }

        private func requestFocusIfNeeded() {
            guard shouldFocus,
                  focusRequest != appliedFocusRequest,
                  focusRequest != pendingFocusRequest,
                  window != nil else { return }
            let request = focusRequest
            pendingFocusRequest = request
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                guard self.pendingFocusRequest == request else { return }
                self.pendingFocusRequest = nil
                guard self.shouldFocus,
                      self.focusRequest == request,
                      let window = self.window,
                      !(window.firstResponder is NSTextView),
                      !(window.firstResponder is NSTextField),
                      window.makeFirstResponder(self) else { return }
                self.appliedFocusRequest = request
            }
        }
    }
}

extension View {
    func fileSelectionGestures(
        onSelect: @escaping (EventModifiers) -> Void,
        onDoubleClick: @escaping () -> Void
    ) -> some View {
        // Capture modifiers in the gesture, before double-click recognition can delay selection.
        let modifiedClick = TapGesture().modifiers([.command, .shift])
            .onEnded { onSelect([.command, .shift]) }
            .exclusively(before: TapGesture().modifiers(.shift)
                .onEnded { onSelect(.shift) })
            .exclusively(before: TapGesture().modifiers(.command)
                .onEnded { onSelect(.command) })

        return self
            .onTapGesture(count: 2, perform: onDoubleClick)
            .onTapGesture { onSelect([]) }
            .highPriorityGesture(modifiedClick)
    }
}

private struct FileGridCell: View {
    let item: FileItem
    let thumbnailSize: CGSize
    let isSelected: Bool
    let isDropTargeted: Bool
    let gitChange: GitFileChange.ChangeType?
    let isRenaming: Bool
    @Binding var renameText: String
    let onSelect: (EventModifiers) -> Void
    let onDoubleClick: () -> Void
    let onCommitRename: (String) -> Void
    let onCancelRename: () -> Void

    var body: some View {
        VStack(spacing: 6) {
            ZStack(alignment: .bottomTrailing) {
                FileGridThumbnailView(item: item, size: thumbnailSize)

                if item.isSymlink {
                    Image(systemName: "arrowshape.turn.up.right.fill")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .padding(3)
                        .background(.regularMaterial, in: Circle())
                }
            }
            .frame(width: thumbnailSize.width, height: thumbnailSize.height)

            if isRenaming {
                FileGridInlineRenameField(
                    item: item,
                    text: $renameText,
                    onCommit: onCommitRename,
                    onCancel: onCancelRename
                )
                .frame(maxWidth: .infinity, minHeight: 30, maxHeight: 30, alignment: .top)
            } else {
                HStack(spacing: 3) {
                    if let gitChange {
                        GitChangeBadge(change: gitChange)
                    }
                    Text(item.name)
                        .font(.system(size: 11))
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                        .truncationMode(.middle)
                }
                .frame(maxWidth: .infinity, minHeight: 30, maxHeight: 30, alignment: .top)
            }
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, minHeight: 122, maxHeight: 122, alignment: .top)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isSelected ? Color.accentColor.opacity(0.18) : .clear)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 6)
                .stroke(
                    isDropTargeted
                        ? Color.accentColor
                        : (isSelected ? Color.accentColor.opacity(0.65) : .clear),
                    lineWidth: isDropTargeted ? 2 : 1
                )
        }
        .background {
            GeometryReader { proxy in
                Color.clear.preference(
                    key: FileGridCellFramePreferenceKey.self,
                    value: [item.id: proxy.frame(in: .named(fileGridCoordinateSpaceName))]
                )
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: 6))
        .fileSelectionGestures(onSelect: onSelect, onDoubleClick: onDoubleClick)
        .accessibilityElement(children: isRenaming ? .contain : .combine)
        .accessibilityLabel(item.name)
        .accessibilityValue(item.kind)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

private struct FileGridInlineRenameField: NSViewRepresentable {
    let item: FileItem
    @Binding var text: String
    let onCommit: (String) -> Void
    let onCancel: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(
            item: item,
            text: $text,
            onCommit: onCommit,
            onCancel: onCancel
        )
    }

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField(frame: .zero)
        field.stringValue = text
        field.font = NSFont.systemFont(ofSize: 11)
        field.alignment = .center
        field.isEditable = true
        field.isSelectable = true
        field.isBordered = true
        field.isBezeled = true
        field.bezelStyle = .roundedBezel
        field.drawsBackground = true
        field.backgroundColor = .textBackgroundColor
        field.focusRingType = .exterior
        field.lineBreakMode = .byTruncatingMiddle
        field.delegate = context.coordinator
        field.setAccessibilityElement(true)
        field.setAccessibilityRole(.textField)
        field.setAccessibilityLabel(L10n.string("Name"))

        context.coordinator.field = field
        let coordinator = context.coordinator
        DispatchQueue.main.async { [weak coordinator, weak field] in
            guard let coordinator, let field else { return }
            coordinator.beginEditing(field)
        }
        return field
    }

    func updateNSView(_ nsView: NSTextField, context: Context) {
        context.coordinator.item = item
        context.coordinator.text = $text
        context.coordinator.onCommit = onCommit
        context.coordinator.onCancel = onCancel
        if !context.coordinator.isFinishing,
           nsView.stringValue != text {
            nsView.stringValue = text
        }
    }

    static func dismantleNSView(_ nsView: NSTextField, coordinator: Coordinator) {
        nsView.delegate = nil
        coordinator.field = nil
    }

    @MainActor
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var item: FileItem
        var text: Binding<String>
        var onCommit: (String) -> Void
        var onCancel: () -> Void
        weak var field: NSTextField?
        var isFinishing = false

        init(
            item: FileItem,
            text: Binding<String>,
            onCommit: @escaping (String) -> Void,
            onCancel: @escaping () -> Void
        ) {
            self.item = item
            self.text = text
            self.onCommit = onCommit
            self.onCancel = onCancel
        }

        func beginEditing(_ field: NSTextField) {
            guard !isFinishing else { return }
            _ = field.window?.makeFirstResponder(field)
            guard let fieldEditor = field.currentEditor() as? NSTextView else { return }

            let name = item.name as NSString
            var selectionLength = name.length
            if !item.isDirectory {
                let pathExtension = name.pathExtension as NSString
                if pathExtension.length > 0 {
                    selectionLength -= pathExtension.length + 1
                }
            }
            let selectedRange = NSRange(location: 0, length: max(selectionLength, 0))
            fieldEditor.setSelectedRange(selectedRange)
            field.setAccessibilitySelectedTextRange(selectedRange)
            field.setAccessibilitySelectedText(name.substring(with: selectedRange))
        }

        func controlTextDidChange(_ notification: Notification) {
            guard !isFinishing,
                  let field = notification.object as? NSTextField else { return }
            text.wrappedValue = field.stringValue
        }

        func control(
            _ control: NSControl,
            textView: NSTextView,
            doCommandBy commandSelector: Selector
        ) -> Bool {
            switch commandSelector {
            case #selector(NSResponder.cancelOperation(_:)):
                finish(commit: false)
                return true
            case #selector(NSStandardKeyBindingResponding.insertNewline(_:)):
                finish(commit: true)
                return true
            default:
                return false
            }
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            finish(commit: true)
        }

        private func finish(commit: Bool) {
            guard !isFinishing else { return }
            isFinishing = true
            field?.delegate = nil
            if commit, let field {
                let newName = field.stringValue
                text.wrappedValue = newName
                onCommit(newName)
            } else {
                onCancel()
            }
        }
    }
}

private struct FileGridContextMenuSelectionMonitor: NSViewRepresentable {
    let onRightMouseDown: (CGPoint) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onRightMouseDown: onRightMouseDown)
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        context.coordinator.anchorView = view
        context.coordinator.startMonitoring()
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.onRightMouseDown = onRightMouseDown
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.stopMonitoring()
    }

    @MainActor
    final class Coordinator: NSObject {
        weak var anchorView: NSView?
        var onRightMouseDown: (CGPoint) -> Void
        private var eventMonitor: Any?

        init(onRightMouseDown: @escaping (CGPoint) -> Void) {
            self.onRightMouseDown = onRightMouseDown
        }

        func startMonitoring() {
            guard eventMonitor == nil else { return }
            eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .rightMouseDown) {
                [weak self] event in
                guard let self,
                      let anchorView = self.anchorView,
                      let window = anchorView.window,
                      event.window === window else {
                    return event
                }

                let pointInView = anchorView.convert(event.locationInWindow, from: nil)
                guard anchorView.bounds.contains(pointInView) else { return event }

                let pointInSwiftUI = CGPoint(
                    x: pointInView.x,
                    y: anchorView.bounds.height - pointInView.y
                )
                self.onRightMouseDown(pointInSwiftUI)
                return event
            }
        }

        func stopMonitoring() {
            guard let eventMonitor else { return }
            NSEvent.removeMonitor(eventMonitor)
            self.eventMonitor = nil
        }
    }
}

private struct FileGridCellFramePreferenceKey: PreferenceKey {
    static let defaultValue: [FileItem.ID: CGRect] = [:]

    static func reduce(
        value: inout [FileItem.ID: CGRect],
        nextValue: () -> [FileItem.ID: CGRect]
    ) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

private struct FileGridThumbnailView: View {
    let item: FileItem
    let size: CGSize

    @State private var image: NSImage?

    private var scale: CGFloat {
        max(NSScreen.main?.backingScaleFactor ?? 2, 1)
    }

    private var requestKey: ThumbnailCache.RequestKey {
        ThumbnailCache.requestKey(
            for: item.url,
            size: size,
            scale: scale,
            modificationDate: item.modificationDate,
            isDirectory: item.isDirectory,
            isPackage: item.isPackage
        )
    }

    var body: some View {
        Image(nsImage: image ?? fallbackIcon)
            .resizable()
            .interpolation(.high)
            .aspectRatio(contentMode: .fit)
            .frame(width: size.width, height: size.height)
            .task(id: requestKey) {
                image = await ThumbnailCache.shared.image(
                    for: item.url,
                    size: size,
                    scale: scale,
                    modificationDate: item.modificationDate,
                    isDirectory: item.isDirectory,
                    isPackage: item.isPackage
                )
            }
            .onDisappear {
                image = nil
            }
    }

    private var fallbackIcon: NSImage {
        ThumbnailCache.shared.fallbackIcon(for: item.url, size: size)
    }
}
