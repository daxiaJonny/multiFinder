import AppKit
import CoreTransferable
import SwiftUI
import UniformTypeIdentifiers

struct FileListView: View {
    @ObservedObject var viewModel: FileBrowserViewModel
    @ObservedObject private var clipboard = FileClipboard.shared
    @ObservedObject private var gitPulse = GitPulseStore.shared
    @State private var inlineRenameRequest: FileTableRenameRequest?
    @StateObject private var inlineRenameState = FileTableRenameState()
    let canTransferToAdjacentPane: ([URL], FileDropOperation) -> Bool
    let onFocus: () -> Void
    let onBeginFiltering: () -> Void
    let onQuickLook: () -> Void
    let onRename: (FileItem) -> Void
    let onGetInfo: () -> Void
    let onCopyToAdjacentPane: ([URL]) -> Void
    let onMoveToAdjacentPane: ([URL]) -> Void

    var body: some View {
        let gitIndex = gitPulse.changeIndex(for: viewModel.currentURL)
        return Table(
            of: FileItem.self,
            selection: focusedSelection,
            sortOrder: focusedSortOrder
        ) {
            TableColumn("Name", sortUsing: FileItemComparator(field: .name)) { item in
                FileTableNameCell(
                    item: item,
                    gitChange: gitIndex?.changeType(for: item.url),
                    renameState: inlineRenameState
                )
            }
            .width(min: 100, ideal: 180)

            TableColumn("Date Modified", sortUsing: FileItemComparator(field: .date)) { item in
                Text(item.modificationDate, format: .dateTime.year().month(.twoDigits).day().hour().minute())
                    .foregroundStyle(.secondary)
            }
            .width(min: 110, ideal: 130, max: 200)

            TableColumn("Size", sortUsing: FileItemComparator(field: .size)) { item in
                Text(item.isDirectory ? "--" : ByteCountFormatter.string(fromByteCount: item.size, countStyle: .file))
                    .foregroundStyle(.secondary)
            }
            .width(min: 55, ideal: 70, max: 110)

            TableColumn("Kind", sortUsing: FileItemComparator(field: .kind)) { item in
                Text(item.kind)
                    .foregroundStyle(.secondary)
            }
            .width(min: 65, ideal: 85, max: 150)
        } rows: {
            ForEach(viewModel.visibleItems) { item in
                // Table drop targets must be attached to TableRowContent, not hosted cell views.
                if item.isDirectory && !item.isPackage {
                    if FileDropSafety.canStartDragging(item) {
                        TableRow(item)
                            .itemProvider {
                                dragProvider(for: item)
                            }
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
                        .itemProvider {
                            dragProvider(for: item)
                        }
                }
            }
        }
        .id(viewModel.tableRevision)
        .overlay {
            FileTableRangeSelectionMonitor(
                itemIDs: viewModel.visibleItems.map(\.id),
                selection: focusedSelection
            )
            .allowsHitTesting(false)
        }
        .overlay(alignment: .topLeading) {
            FileTableClickMonitor(
                items: viewModel.visibleItems,
                renameRequest: inlineRenameRequest,
                onEditingItemChange: { itemID in
                    // Editing can also end during an NSViewRepresentable update.
                    DispatchQueue.main.async {
                        inlineRenameState.itemID = itemID
                    }
                },
                onRename: { item, newName in
                    viewModel.rename(item: item, to: newName)
                },
                onContextMenuItem: { item in
                    onFocus()
                    if !viewModel.selectedItems.contains(item.id) {
                        viewModel.selectedItems = [item.id]
                    }
                },
                onBlankContextMenu: {
                    onFocus()
                    viewModel.selectedItems.removeAll()
                }
            )
            .frame(width: 1, height: 1)
            .allowsHitTesting(false)
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
        .onKeyPress(.return, phases: .down) { _ in
            guard let item = viewModel.selectedItem else { return .ignored }
            onFocus()
            inlineRenameRequest = FileTableRenameRequest(itemID: item.id)
            return .handled
        }
        .onKeyPress(KeyEquivalent("o"), phases: .down) { keyPress in
            guard keyPress.modifiers.contains(.command) else { return .ignored }
            open(selection: viewModel.selectedItems)
            return .handled
        }
        .onKeyPress(.delete, phases: .down) { keyPress in
            guard keyPress.modifiers.contains(.command) else { return .ignored }
            onFocus()
            viewModel.deleteSelected()
            return .handled
        }
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
            onFocus()
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

        Button("Get Info") {
            onFocus()
            viewModel.selectForContextMenu(selection)
            onGetInfo()
        }
        .disabled(selectedItems.isEmpty)

        Divider()

        Button("Copy") {
            onFocus()
            viewModel.selectForContextMenu(selection)
            clipboard.copy(urls: selectedItems.map(\.url))
        }
        .disabled(selectedItems.isEmpty)

        CopyPathMenu(urls: selectedItems.map(\.url))

        Button("Cut") {
            onFocus()
            viewModel.selectForContextMenu(selection)
            clipboard.cut(urls: selectedItems.map(\.url))
        }
        .disabled(selectedItems.isEmpty)

        Button("Paste") {
            pasteFromClipboard(into: pasteDestination)
        }
        .disabled(!clipboard.hasContent || pasteDestination == nil)

        Button("Duplicate") {
            onFocus()
            viewModel.selectForContextMenu(selection)
            viewModel.duplicateSelected()
        }
        .disabled(selectedItems.isEmpty || !viewModel.canCreateItems)

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

        Button("Add to Stash Shelf") {
            onFocus()
            viewModel.selectForContextMenu(selection)
            StashShelfStore.shared.add(urls: selectedItems.map(\.url))
        }
        .disabled(selectedItems.isEmpty)

        Divider()

        Button("Rename…") {
            guard let item = selectedItems.first else { return }
            onFocus()
            viewModel.selectForContextMenu(selection)
            inlineRenameRequest = FileTableRenameRequest(itemID: item.id)
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
        let urls = items.flatMap(\.urls)
        guard !urls.isEmpty else { return }
        onFocus()
        viewModel.transferDroppedItems(
            urls,
            into: destination,
            operation: FileDropModifierKeys.operation(for: urls, into: destination)
        )
    }

    private func dragProvider(for item: FileItem) -> NSItemProvider {
        let dragItems = viewModel.selectedItems.contains(item.id)
            ? viewModel.selectedFileItems
            : [item]
        guard dragItems.allSatisfy({ FileDropSafety.canStartDragging($0) }) else {
            return NSItemProvider()
        }
        return FileDragProvider.provider(for: dragItems.map(\.url))
            ?? NSItemProvider(object: item.url as NSURL)
    }

    private func pasteFromClipboard(into destination: URL?) {
        onFocus()
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

struct FileTableRangeSelectionMonitor: NSViewRepresentable {
    let itemIDs: [FileItem.ID]
    @Binding var selection: Set<FileItem.ID>

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let view = PassthroughView(frame: .zero)
        context.coordinator.anchorView = view
        context.coordinator.monitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .leftMouseUp]
        ) { [weak coordinator = context.coordinator] event in
            guard let coordinator else { return event }
            return coordinator.handle(event)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.itemIDs = itemIDs
        context.coordinator.selection = selection
        context.coordinator.onSelection = { selection = $0 }
        if selection.isEmpty {
            context.coordinator.anchorID = nil
        } else if let anchor = context.coordinator.anchorID, !itemIDs.contains(anchor) {
            context.coordinator.anchorID = nil
        }
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        if let monitor = coordinator.monitor { NSEvent.removeMonitor(monitor) }
        coordinator.monitor = nil
    }

    final class PassthroughView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }

    @MainActor
    final class Coordinator {
        weak var anchorView: NSView?
        var monitor: Any?
        var itemIDs: [FileItem.ID] = []
        var selection: Set<FileItem.ID> = []
        var onSelection: (Set<FileItem.ID>) -> Void = { _ in }
        var anchorID: FileItem.ID?
        private var consumesMouseUp = false

        func handle(_ event: NSEvent) -> NSEvent? {
            if event.type == .leftMouseUp, consumesMouseUp {
                consumesMouseUp = false
                return nil
            }
            guard event.type == .leftMouseDown else { return event }
            consumesMouseUp = false
            guard let anchorView, let window = anchorView.window,
                  event.window === window,
                  !anchorView.isHiddenOrHasHiddenAncestor,
                  anchorView.visibleRect.contains(anchorView.convert(event.locationInWindow, from: nil)),
                  !event.modifierFlags.contains(.control),
                  let contentView = window.contentView else { return event }

            var hitView = contentView.hitTest(contentView.convert(event.locationInWindow, from: nil))
            // SwiftUI Table and List both host their rows inside an NSTableView.
            while let view = hitView, !(view is NSTableView) { hitView = view.superview }
            guard let tableView = hitView as? NSTableView else { return event }
            let row = tableView.row(at: tableView.convert(event.locationInWindow, from: nil))
            guard itemIDs.indices.contains(row) else { return event }

            guard event.modifierFlags.contains(.shift) else {
                anchorID = itemIDs[row]
                return event
            }

            let anchor = anchorID.flatMap { itemIDs.firstIndex(of: $0) }
                ?? itemIDs.firstIndex(where: selection.contains)
                ?? row
            anchorID = itemIDs[anchor]
            let range = min(anchor, row)...max(anchor, row)
            let rangeSelection = Set(itemIDs[range])
            let nextSelection = event.modifierFlags.contains(.command)
                ? selection.union(rangeSelection) : rangeSelection
            let indexes = IndexSet(itemIDs.indices.filter { nextSelection.contains(itemIDs[$0]) })
            tableView.selectRowIndexes(indexes, byExtendingSelection: false)
            selection = nextSelection
            onSelection(nextSelection)
            // Prevent the native drag/click handling from replacing this explicit range.
            consumesMouseUp = true
            return nil
        }
    }
}

private final class FileTableRenameState: ObservableObject {
    @Published var itemID: FileItem.ID?
}

private struct FileTableNameCell: View {
    let item: FileItem
    let gitChange: GitFileChange.ChangeType?
    // Table caches its cell content, so each cell must observe editing directly.
    @ObservedObject var renameState: FileTableRenameState

    var body: some View {
        HStack(spacing: 6) {
            Image(nsImage: IconCache.shared.icon(for: item.url.path))
                .resizable()
                .interpolation(.high)
                .frame(width: 16, height: 16)
            if let gitChange {
                GitChangeBadge(change: gitChange)
            }
            Text(item.name)
                .lineLimit(1)
                .truncationMode(.middle)
                .opacity(renameState.itemID == item.id ? 0 : 1)
                .accessibilityHidden(renameState.itemID == item.id)
            if item.isSymlink {
                Image(systemName: "arrowshape.turn.up.right")
                    .font(.system(size: 8))
                    .foregroundStyle(.tertiary)
            }
        }
    }
}

private struct FileTableRenameRequest: Equatable {
    let id = UUID()
    let itemID: FileItem.ID
}

private struct FileTableClickMonitor: NSViewRepresentable {
    let items: [FileItem]
    let renameRequest: FileTableRenameRequest?
    let onEditingItemChange: (FileItem.ID?) -> Void
    let onRename: (FileItem, String) -> Void
    let onContextMenuItem: (FileItem) -> Void
    let onBlankContextMenu: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(
            items: items,
            onEditingItemChange: onEditingItemChange,
            onRename: onRename,
            onContextMenuItem: onContextMenuItem,
            onBlankContextMenu: onBlankContextMenu
        )
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        context.coordinator.anchorView = view
        context.coordinator.startMonitoring()
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.anchorView = nsView
        context.coordinator.items = items
        context.coordinator.onEditingItemChange = onEditingItemChange
        context.coordinator.onRename = onRename
        context.coordinator.onContextMenuItem = onContextMenuItem
        context.coordinator.onBlankContextMenu = onBlankContextMenu
        context.coordinator.cancelEditingIfItemWasRemoved()
        context.coordinator.handle(renameRequest: renameRequest)
        context.coordinator.configureTableViewAppearance(for: nsView)
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.stopMonitoring()
    }

    @MainActor
    final class Coordinator: NSObject, NSTextFieldDelegate {
        weak var anchorView: NSView?
        var items: [FileItem]
        var onEditingItemChange: (FileItem.ID?) -> Void
        var onRename: (FileItem, String) -> Void
        var onContextMenuItem: (FileItem) -> Void
        var onBlankContextMenu: () -> Void

        private weak var resolvedTableView: NSTableView?
        private var nameColumnIdentifier: NSUserInterfaceItemIdentifier?
        private var eventMonitor: Any?
        private var pendingEditTask: Task<Void, Never>?
        private var lastNameClickItemID: FileItem.ID?
        private var lastNameClickTime: TimeInterval = 0
        private weak var inlineEditor: NSTextField?
        private var inlineEditorItem: FileItem?
        private var isFinishingEditing = false
        private var handledRenameRequestID: UUID?

        init(
            items: [FileItem],
            onEditingItemChange: @escaping (FileItem.ID?) -> Void,
            onRename: @escaping (FileItem, String) -> Void,
            onContextMenuItem: @escaping (FileItem) -> Void,
            onBlankContextMenu: @escaping () -> Void
        ) {
            self.items = items
            self.onEditingItemChange = onEditingItemChange
            self.onRename = onRename
            self.onContextMenuItem = onContextMenuItem
            self.onBlankContextMenu = onBlankContextMenu
        }

        func startMonitoring() {
            guard eventMonitor == nil else { return }
            eventMonitor = NSEvent.addLocalMonitorForEvents(
                matching: [.leftMouseDown, .leftMouseDragged, .rightMouseDown]
            ) { [weak self] event in
                self?.handle(event)
                return event
            }
        }

        func stopMonitoring() {
            pendingEditTask?.cancel()
            finishEditing(commit: false)
            guard let eventMonitor else { return }
            NSEvent.removeMonitor(eventMonitor)
            self.eventMonitor = nil
        }

        func handle(renameRequest: FileTableRenameRequest?) {
            guard let renameRequest,
                  renameRequest.id != handledRenameRequestID else { return }
            handledRenameRequestID = renameRequest.id

            DispatchQueue.main.async { [weak self] in
                self?.startEditing(itemID: renameRequest.itemID)
            }
        }

        private func handle(_ event: NSEvent) {
            guard let anchorView,
                  let window = anchorView.window,
                  event.window === window else {
                pendingEditTask?.cancel()
                resetNameClickSequence()
                if inlineEditor != nil {
                    finishEditing(commit: true)
                }
                return
            }

            let windowPoint = event.locationInWindow
            guard let tableView = resolveTableView(for: anchorView),
                  tableFrameInWindow(tableView).contains(windowPoint) else {
                pendingEditTask?.cancel()
                resetNameClickSequence()
                if inlineEditor != nil {
                    finishEditing(commit: true)
                }
                return
            }

            let tablePoint = tableView.convert(windowPoint, from: nil)
            if event.type == .rightMouseDown {
                let row = tableView.row(at: tablePoint)
                if items.indices.contains(row) {
                    onContextMenuItem(items[row])
                } else {
                    onBlankContextMenu()
                }
                return
            }

            guard event.type == .leftMouseDown else {
                pendingEditTask?.cancel()
                resetNameClickSequence()
                return
            }

            if let inlineEditor,
               inlineEditor.convert(inlineEditor.bounds, to: tableView).contains(tablePoint) {
                return
            }
            if inlineEditor != nil {
                finishEditing(commit: true)
            }

            guard let hit = nameHit(in: tableView, at: tablePoint) else {
                pendingEditTask?.cancel()
                resetNameClickSequence()
                return
            }

            pendingEditTask?.cancel()
            guard event.modifierFlags.intersection([.shift, .command, .control]).isEmpty else {
                resetNameClickSequence()
                return
            }
            if event.clickCount > 1 {
                resetNameClickSequence()
                return
            }

            let clickTime = ProcessInfo.processInfo.systemUptime
            let shouldEdit = lastNameClickItemID == hit.item.id
                && tableView.selectedRowIndexes.contains(hit.row)
                && clickTime - lastNameClickTime >= max(NSEvent.doubleClickInterval, 0.2)
            lastNameClickItemID = hit.item.id
            lastNameClickTime = clickTime
            guard shouldEdit else { return }

            resetNameClickSequence()
            pendingEditTask = Task { @MainActor [weak self, weak tableView] in
                do {
                    try await Task.sleep(for: .milliseconds(250))
                } catch {
                    return
                }
                guard let self, let tableView else { return }
                self.pendingEditTask = nil
                self.startEditing(hit.item, row: hit.row, column: hit.column, in: tableView)
            }
        }

        private func nameHit(in tableView: NSTableView, at point: NSPoint) -> (item: FileItem, row: Int, column: Int)? {
            let row = tableView.row(at: point)
            let column = tableView.column(at: point)
            guard items.indices.contains(row),
                  tableView.tableColumns.indices.contains(column),
                  isNameColumn(tableView.tableColumns[column], in: tableView) else { return nil }

            let item = items[row]
            let cellFrame = tableView.frameOfCell(atColumn: column, row: row)
            let nameWidth = (item.name as NSString).size(
                withAttributes: [.font: NSFont.systemFont(ofSize: NSFont.systemFontSize)]
            ).width
            let contentMaxX = min(cellFrame.maxX, cellFrame.minX + 44 + nameWidth)
            guard point.x <= contentMaxX else { return nil }

            return (item, row, column)
        }

        func configureTableViewAppearance(for anchorView: NSView) {
            guard let tableView = resolveTableView(for: anchorView) else { return }
            if tableView.usesAlternatingRowBackgroundColors {
                tableView.usesAlternatingRowBackgroundColors = false
            }
            tableView.backgroundColor = .clear
            tableView.gridStyleMask = []
            if let scrollView = tableView.enclosingScrollView {
                scrollView.backgroundColor = .clear
                scrollView.drawsBackground = false
                scrollView.autohidesScrollers = true
                scrollView.scrollerStyle = .overlay
                scrollView.horizontalScroller?.scrollerStyle = .overlay
                scrollView.verticalScroller?.scrollerStyle = .overlay
            }
        }

        private func isNameColumn(_ column: NSTableColumn, in tableView: NSTableView) -> Bool {
            if tableView !== resolvedTableView {
                resolvedTableView = tableView
                nameColumnIdentifier = tableView.tableColumns.first?.identifier
                if tableView.usesAlternatingRowBackgroundColors {
                    tableView.usesAlternatingRowBackgroundColors = false
                }
                tableView.backgroundColor = .clear
                tableView.gridStyleMask = []
                if let scrollView = tableView.enclosingScrollView {
                    scrollView.backgroundColor = .clear
                    scrollView.drawsBackground = false
                    scrollView.autohidesScrollers = true
                    scrollView.scrollerStyle = .overlay
                    scrollView.horizontalScroller?.scrollerStyle = .overlay
                    scrollView.verticalScroller?.scrollerStyle = .overlay
                }
            }
            return column.identifier == nameColumnIdentifier
        }

        private func resolveTableView(for anchorView: NSView) -> NSTableView? {
            guard let contentView = anchorView.window?.contentView else { return nil }
            let anchorPoint = NSPoint(
                x: anchorView.convert(anchorView.bounds, to: nil).midX,
                y: anchorView.convert(anchorView.bounds, to: nil).midY
            )
            return Self.tableViews(in: contentView).min { lhs, rhs in
                Self.distance(from: anchorPoint, to: tableFrameInWindow(lhs))
                    < Self.distance(from: anchorPoint, to: tableFrameInWindow(rhs))
            }
        }

        private func tableFrameInWindow(_ tableView: NSTableView) -> NSRect {
            let frameView = tableView.enclosingScrollView ?? tableView
            return frameView.convert(frameView.bounds, to: nil)
        }

        private static func tableViews(in view: NSView) -> [NSTableView] {
            let current = (view as? NSTableView).map { [$0] } ?? []
            return current + view.subviews.flatMap(tableViews(in:))
        }

        private static func distance(from point: NSPoint, to rect: NSRect) -> CGFloat {
            let dx = max(rect.minX - point.x, 0, point.x - rect.maxX)
            let dy = max(rect.minY - point.y, 0, point.y - rect.maxY)
            return dx * dx + dy * dy
        }

        private func startEditing(_ item: FileItem, row: Int, column: Int, in tableView: NSTableView) {
            guard inlineEditor == nil,
                  items.indices.contains(row),
                  items[row].id == item.id,
                  tableView.numberOfRows > row,
                  let cellView = tableView.view(
                      atColumn: column,
                      row: row,
                      makeIfNecessary: false
                  ) else { return }

            let editor = NSTextField(frame: .zero)
            editor.stringValue = item.name
            editor.font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
            editor.isEditable = true
            editor.isSelectable = true
            editor.isBezeled = false
            editor.isBordered = true
            editor.drawsBackground = true
            editor.backgroundColor = .textBackgroundColor
            editor.textColor = .textColor
            editor.focusRingType = .none
            editor.cell?.backgroundStyle = .normal
            editor.delegate = self
            editor.setAccessibilityElement(true)
            editor.setAccessibilityRole(.textField)
            editor.setAccessibilityLabel(L10n.string("Name"))

            let editorHeight = editor.intrinsicContentSize.height
            editor.frame = NSRect(
                x: 0,
                y: cellView.bounds.midY - editorHeight / 2,
                width: cellView.bounds.width,
                height: editorHeight
            )
            inlineEditor = editor
            inlineEditorItem = item
            onEditingItemChange(item.id)
            cellView.addSubview(editor, positioned: .above, relativeTo: nil)
            editor.selectText(nil)
            alignEditor(editor, in: cellView)
            selectEditableName(for: item, in: editor)
        }

        private func alignEditor(_ editor: NSTextField, in cellView: NSView) {
            guard let fieldEditor = editor.currentEditor() as? NSTextView,
                  let container = fieldEditor.textContainer,
                  let layoutManager = fieldEditor.layoutManager else { return }

            layoutManager.ensureLayout(for: container)
            let origin = fieldEditor.textContainerOrigin
            let textBounds = layoutManager.usedRect(for: container)
                .offsetBy(dx: origin.x, dy: origin.y)
            let textFrame = fieldEditor.convert(textBounds, to: cellView)
            let textStart = fieldEditor.convert(NSPoint(
                x: origin.x + container.lineFragmentPadding,
                y: origin.y
            ), to: cellView)

            // Match the 16-point icon plus 6-point spacing, including native editor insets.
            var frame = editor.frame
            frame.origin.x += 16 + 6 - textStart.x
            frame.origin.y += cellView.bounds.midY - textFrame.midY
            frame.size.width = max(cellView.bounds.maxX - frame.minX - 4, 48)
            editor.frame = frame
        }

        private func startEditing(itemID: FileItem.ID) {
            guard let anchorView,
                  let tableView = resolveTableView(for: anchorView),
                  let row = items.firstIndex(where: { $0.id == itemID }),
                  tableView.numberOfRows > row,
                  let column = tableView.tableColumns.indices.first(where: {
                      isNameColumn(tableView.tableColumns[$0], in: tableView)
                  }) else { return }

            pendingEditTask?.cancel()
            resetNameClickSequence()
            if inlineEditor != nil {
                finishEditing(commit: true)
            }
            tableView.scrollRowToVisible(row)
            startEditing(items[row], row: row, column: column, in: tableView)
        }

        private func selectEditableName(for item: FileItem, in editor: NSTextField) {
            guard let fieldEditor = editor.currentEditor() as? NSTextView else { return }
            fieldEditor.drawsBackground = true
            fieldEditor.backgroundColor = .textBackgroundColor
            fieldEditor.textColor = .textColor
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
            editor.setAccessibilitySelectedTextRange(selectedRange)
            editor.setAccessibilitySelectedText(name.substring(with: selectedRange))
        }

        private func finishEditing(commit: Bool) {
            guard !isFinishingEditing,
                  let editor = inlineEditor else { return }

            isFinishingEditing = true
            let item = inlineEditorItem
            let newName = editor.stringValue
            editor.delegate = nil
            if editor.window?.firstResponder === editor.currentEditor() {
                editor.window?.makeFirstResponder(resolvedTableView)
            }
            editor.removeFromSuperview()
            inlineEditor = nil
            inlineEditorItem = nil
            onEditingItemChange(nil)
            isFinishingEditing = false

            guard commit, let item, newName != item.name else { return }
            DispatchQueue.main.async { [onRename] in
                onRename(item, newName)
            }
        }

        func control(
            _ control: NSControl,
            textView: NSTextView,
            doCommandBy commandSelector: Selector
        ) -> Bool {
            switch commandSelector {
            case #selector(NSResponder.cancelOperation(_:)):
                finishEditing(commit: false)
                return true
            case #selector(NSStandardKeyBindingResponding.insertNewline(_:)):
                finishEditing(commit: true)
                return true
            default:
                return false
            }
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            finishEditing(commit: true)
        }

        func cancelEditingIfItemWasRemoved() {
            guard let item = inlineEditorItem,
                  !items.contains(where: { $0.id == item.id }) else { return }
            finishEditing(commit: false)
        }

        private func resetNameClickSequence() {
            lastNameClickItemID = nil
            lastNameClickTime = 0
        }
    }
}

enum FileDropModifierKeys {
    static var currentOperation: FileDropOperation {
        NSEvent.modifierFlags.contains(.option) ? .copy : .move
    }

    static func operation(for urls: [URL], into destination: URL) -> FileDropOperation {
        FileBrowserViewModel.dropOperation(
            for: urls,
            into: destination,
            optionPressed: NSEvent.modifierFlags.contains(.option)
        )
    }
}

enum FileDragProvider {
    static func provider(for urls: [URL]) -> NSItemProvider? {
        let normalizedURLs = uniqueStandardizedURLs(urls)
        guard let firstURL = normalizedURLs.first else { return nil }

        let provider = NSItemProvider(contentsOf: firstURL)
            ?? NSItemProvider(object: firstURL as NSURL)
        // Chromium-based apps (DingTalk mail) load the file UTI and name the
        // temp file from suggestedName. NSItemProvider(contentsOf:) leaves it
        // nil, so the receiver falls back to the UTI description.
        provider.suggestedName = firstURL.lastPathComponent
        guard normalizedURLs.count > 1,
              let batchData = DroppedFileURL.batchData(for: normalizedURLs) else {
            return provider
        }

        provider.registerDataRepresentation(
            forTypeIdentifier: DroppedFileURL.batchTypeIdentifier,
            visibility: .all
        ) { completion in
            completion(batchData, nil)
            return nil
        }
        return provider
    }

    private static func uniqueStandardizedURLs(_ urls: [URL]) -> [URL] {
        var seen = Set<URL>()
        return urls.map(\.standardizedFileURL).filter { seen.insert($0).inserted }
    }
}

struct DroppedFileURL: Transferable, Equatable, Sendable {
    let urls: [URL]

    static let batchTypeIdentifier = "com.multifinder.multifinder-file-url-list"
    static let batchContentType = UTType(
        importedAs: batchTypeIdentifier,
        conformingTo: .data
    )

    init(url: URL) {
        urls = [url]
    }

    init(urls: [URL]) {
        self.urls = urls
    }

    var url: URL { urls[0] }

    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(importedContentType: batchContentType) { data in
            guard let urls = Self.urls(fromBatchData: data), !urls.isEmpty else {
                throw CocoaError(.fileReadCorruptFile)
            }
            return DroppedFileURL(urls: urls)
        }
        DataRepresentation(importedContentType: .fileURL) { data in
            guard let url = URL(dataRepresentation: data, relativeTo: nil), url.isFileURL else {
                throw CocoaError(.fileReadCorruptFile)
            }
            return DroppedFileURL(url: url)
        }
    }

    static func batchData(for urls: [URL]) -> Data? {
        let values = urls.map(\.standardizedFileURL.absoluteString)
        return try? JSONEncoder().encode(values)
    }

    static func urls(fromBatchData data: Data) -> [URL]? {
        guard let values = try? JSONDecoder().decode([String].self, from: data) else {
            return nil
        }
        var seen = Set<URL>()
        let urls = values.compactMap(URL.init(string:)).filter { url in
            url.isFileURL && seen.insert(url.standardizedFileURL).inserted
        }
        return urls.isEmpty ? nil : urls.map(\.standardizedFileURL)
    }
}

enum DroppedFileURLLoader {
    static func load(_ providers: [NSItemProvider], completion: @escaping ([URL]) -> Void) {
        let collector = DroppedFileURLCollector()
        let group = DispatchGroup()

        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(DroppedFileURL.batchTypeIdentifier) {
                group.enter()
                provider.loadDataRepresentation(
                    forTypeIdentifier: DroppedFileURL.batchTypeIdentifier
                ) { data, _ in
                    if let data, let urls = DroppedFileURL.urls(fromBatchData: data) {
                        collector.append(contentsOf: urls)
                        group.leave()
                    } else if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                        Self.loadFileURL(from: provider, collector: collector, group: group)
                    } else {
                        group.leave()
                    }
                }
            } else if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                group.enter()
                loadFileURL(from: provider, collector: collector, group: group)
            }
        }

        group.notify(queue: .main) {
            completion(collector.urls)
        }
    }

    private static func loadFileURL(
        from provider: NSItemProvider,
        collector: DroppedFileURLCollector,
        group: DispatchGroup
    ) {
        provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
            if let url = fileURL(from: item) {
                collector.append(url)
            }
            group.leave()
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

    func append(contentsOf urls: [URL]) {
        lock.lock()
        storage.append(contentsOf: urls)
        lock.unlock()
    }

    var urls: [URL] {
        lock.lock()
        let values = storage
        lock.unlock()

        var seen = Set<URL>()
        return values.map(\.standardizedFileURL).filter { seen.insert($0).inserted }
    }
}
