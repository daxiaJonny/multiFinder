import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct FileColumnView: View {
    @ObservedObject var viewModel: FileBrowserViewModel

    let canTransferToAdjacentPane: ([URL], FileDropOperation) -> Bool
    let onFocus: () -> Void
    let onBeginFiltering: () -> Void
    let onQuickLook: () -> Void
    let onRename: (FileItem) -> Void
    let onGetInfo: () -> Void
    let onCopyToAdjacentPane: ([URL]) -> Void
    let onMoveToAdjacentPane: ([URL]) -> Void

    @State private var selectionAnchor: FileItem.ID?
    @State private var dropTargetID: FileItem.ID?
    @FocusState private var hasKeyboardFocus: Bool

    var body: some View {
        GeometryReader { geometry in
            if geometry.size.width >= 520 {
                HSplitView {
                    itemColumn
                        .frame(minWidth: 250, idealWidth: geometry.size.width * 0.55)
                    preview
                        .frame(minWidth: 210, idealWidth: geometry.size.width * 0.45)
                }
            } else if geometry.size.height >= 320 {
                VSplitView {
                    itemColumn
                        .frame(minHeight: 145, idealHeight: geometry.size.height * 0.56)
                    preview
                        .frame(minHeight: 130, idealHeight: geometry.size.height * 0.44)
                }
            } else {
                itemColumn
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
        .onChange(of: viewModel.location) { _, _ in
            selectionAnchor = nil
            dropTargetID = nil
        }
        .onChange(of: viewModel.tableRevision) { _, _ in
            let visibleIDs = Set(viewModel.visibleItems.map(\.id))
            if let selectionAnchor, !visibleIDs.contains(selectionAnchor) {
                self.selectionAnchor = nil
            }
            if let dropTargetID, !visibleIDs.contains(dropTargetID) {
                self.dropTargetID = nil
            }
        }
    }

    private var itemColumn: some View {
        List(selection: focusedSelection) {
            ForEach(viewModel.visibleItems) { item in
                row(for: item)
                    .tag(item.id)
            }
        }
        .listStyle(.plain)
        .focused($hasKeyboardFocus)
        .contextMenu(forSelectionType: FileItem.ID.self) { selection in
            FinderItemsContextMenu(
                viewModel: viewModel,
                selection: selection,
                canTransferToAdjacentPane: canTransferToAdjacentPane,
                onFocus: focusColumn,
                onQuickLook: onQuickLook,
                onRename: onRename,
                onGetInfo: onGetInfo,
                onCopyToAdjacentPane: onCopyToAdjacentPane,
                onMoveToAdjacentPane: onMoveToAdjacentPane
            )
        } primaryAction: { selection in
            open(selection: selection)
        }
        .onKeyPress(KeyEquivalent("/")) {
            onBeginFiltering()
            return .handled
        }
        .onKeyPress(.space) {
            focusColumn()
            onQuickLook()
            return .handled
        }
        .onKeyPress(.return, phases: .down) { _ in
            guard let item = viewModel.selectedItem else { return .ignored }
            focusColumn()
            onRename(item)
            return .handled
        }
        .onKeyPress(KeyEquivalent("o"), phases: .down) { keyPress in
            guard keyPress.modifiers.contains(.command) else { return .ignored }
            open(selection: viewModel.selectedItems)
            return .handled
        }
        .onKeyPress(.delete, phases: .down) { keyPress in
            guard keyPress.modifiers.contains(.command) else { return .ignored }
            focusColumn()
            viewModel.deleteSelected()
            return .handled
        }
        .onKeyPress(.rightArrow, phases: .down) { keyPress in
            guard keyPress.modifiers.isEmpty,
                  let item = viewModel.selectedItem,
                  item.isDirectory,
                  !item.isPackage else { return .ignored }
            focusColumn()
            viewModel.openItem(item)
            return .handled
        }
        .onKeyPress(.leftArrow, phases: .down) { keyPress in
            guard keyPress.modifiers.isEmpty, viewModel.canGoUp else { return .ignored }
            focusColumn()
            viewModel.goUp()
            return .handled
        }
    }

    private var preview: some View {
        FileSelectionPreview(
            viewModel: viewModel,
            onQuickLook: onQuickLook,
            onGetInfo: onGetInfo
        )
    }

    @ViewBuilder
    private func row(for item: FileItem) -> some View {
        let content = HStack(spacing: 7) {
            Image(nsImage: IconCache.shared.icon(for: item.url.path))
                .resizable()
                .interpolation(.high)
                .frame(width: 18, height: 18)

            Text(item.name)
                .lineLimit(1)
                .truncationMode(.middle)

            if item.isSymlink {
                Image(systemName: "arrowshape.turn.up.right")
                    .font(.system(size: 8))
                    .foregroundStyle(.tertiary)
            }

            Spacer(minLength: 4)

            if item.isDirectory && !item.isPackage {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(minHeight: 22)
        .contentShape(Rectangle())
        .contextMenu {
            FinderItemsContextMenu(
                viewModel: viewModel,
                selection: contextSelection(for: item),
                canTransferToAdjacentPane: canTransferToAdjacentPane,
                onFocus: focusColumn,
                onQuickLook: onQuickLook,
                onRename: onRename,
                onGetInfo: onGetInfo,
                onCopyToAdjacentPane: onCopyToAdjacentPane,
                onMoveToAdjacentPane: onMoveToAdjacentPane
            )
        }

        if item.isDirectory && !item.isPackage {
            if FileDropSafety.canStartDragging(item) {
                content
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
                    .background(dropTargetID == item.id ? Color.accentColor.opacity(0.16) : .clear)
            } else {
                content
                    .dropDestination(
                        for: DroppedFileURL.self,
                        action: { droppedItems, _ in
                            transferDroppedItems(droppedItems, into: item.url)
                        },
                        isTargeted: { targeted in
                            dropTargetID = targeted ? item.id : nil
                        }
                    )
                    .background(dropTargetID == item.id ? Color.accentColor.opacity(0.16) : .clear)
            }
        } else if FileDropSafety.canStartDragging(item) {
            content.onDrag { dragProvider(for: item) }
        } else {
            content
        }
    }

    private var focusedSelection: Binding<Set<FileItem.ID>> {
        Binding(
            get: { viewModel.selectedItems },
            set: { selection in
                focusColumn()
                viewModel.selectedItems = selection
                if let last = viewModel.visibleItems.last(where: { selection.contains($0.id) }) {
                    selectionAnchor = last.id
                } else if selection.isEmpty {
                    selectionAnchor = nil
                }
            }
        )
    }

    private func focusColumn() {
        onFocus()
        hasKeyboardFocus = true
    }

    private func contextSelection(for item: FileItem) -> Set<FileItem.ID> {
        viewModel.selectedItems.contains(item.id) ? viewModel.selectedItems : [item.id]
    }

    private func open(selection: Set<FileItem.ID>) {
        focusColumn()
        let selectedItems = viewModel.items.filter { selection.contains($0.id) }
        if selectedItems.count == 1, let item = selectedItems.first {
            viewModel.openItem(item)
        } else {
            selectedItems.forEach(viewModel.openItem)
        }
    }

    private func dragProvider(for item: FileItem) -> NSItemProvider {
        focusColumn()
        if !viewModel.selectedItems.contains(item.id) {
            viewModel.selectedItems = [item.id]
            selectionAnchor = item.id
        }
        let draggedItems = viewModel.selectedItems.contains(item.id)
            ? viewModel.selectedFileItems
            : [item]
        guard draggedItems.allSatisfy({ FileDropSafety.canStartDragging($0) }) else {
            return NSItemProvider()
        }
        return FileDragProvider.provider(for: draggedItems.map(\.url))
            ?? NSItemProvider(object: item.url as NSURL)
    }

    private func transferDroppedItems(_ items: [DroppedFileURL], into destination: URL) -> Bool {
        let urls = items.flatMap(\.urls)
        guard !urls.isEmpty else { return false }
        focusColumn()
        dropTargetID = nil
        return viewModel.transferDroppedItems(
            urls,
            into: destination,
            operation: FileDropModifierKeys.operation(for: urls, into: destination)
        )
    }
}

struct FileSelectionPreview: View {
    @ObservedObject var viewModel: FileBrowserViewModel
    let onQuickLook: () -> Void
    let onGetInfo: () -> Void

    private var selectedItems: [FileItem] { viewModel.selectedFileItems }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 13) {
                    previewArtwork
                        .frame(maxWidth: .infinity)

                    previewDetails
                        .frame(maxWidth: 420)
                }
                .padding(18)
                .frame(maxWidth: .infinity, minHeight: 180, alignment: .center)
            }

            if !selectedItems.isEmpty {
                Divider()

                HStack(spacing: 8) {
                    Button(action: onQuickLook) {
                        Image(systemName: "eye")
                            .frame(width: 22, height: 22)
                    }
                    .buttonStyle(.borderless)
                    .help("Quick Look")

                    Button(action: onGetInfo) {
                        Image(systemName: "info.circle")
                            .frame(width: 22, height: 22)
                    }
                    .buttonStyle(.borderless)
                    .help("Get Info")
                }
                .padding(.horizontal, 12)
                .frame(height: 34)
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }

    @ViewBuilder
    private var previewArtwork: some View {
        if selectedItems.count == 1, let item = selectedItems.first {
            FinderThumbnailView(item: item, size: CGSize(width: 260, height: 220))
                .frame(maxWidth: 260, minHeight: 120, maxHeight: 220)
                .contentShape(Rectangle())
                .onTapGesture(count: 2, perform: onQuickLook)
                .accessibilityLabel(item.name)
        } else if selectedItems.count > 1 {
            ZStack {
                ForEach(Array(selectedItems.prefix(3).enumerated()), id: \.element.id) { index, item in
                    FinderThumbnailView(item: item, size: CGSize(width: 118, height: 104))
                        .frame(width: 118, height: 104)
                        .padding(7)
                        .background(Color(nsColor: .windowBackgroundColor))
                        .overlay {
                            RoundedRectangle(cornerRadius: 5)
                                .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
                        }
                        .offset(x: CGFloat(index - 1) * 24, y: CGFloat(index - 1) * -5)
                }
            }
            .frame(width: 190, height: 126)
            .contentShape(Rectangle())
            .onTapGesture(count: 2, perform: onQuickLook)
            .accessibilityLabel(L10n.format("%lld items", Int64(selectedItems.count)))
        } else {
            Image(systemName: "cursorarrow.click.2")
                .font(.system(size: 42, weight: .light))
                .foregroundStyle(.tertiary)
                .frame(height: 90)
                .accessibilityHidden(true)
        }
    }

    @ViewBuilder
    private var previewDetails: some View {
        if selectedItems.count == 1, let item = selectedItems.first {
            VStack(spacing: 6) {
                Text(item.name)
                    .font(.system(size: 15, weight: .semibold))
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .truncationMode(.middle)

                Text(item.kind)
                    .foregroundStyle(.secondary)

                if !item.isDirectory {
                    Text(ByteCountFormatter.string(fromByteCount: item.size, countStyle: .file))
                        .foregroundStyle(.secondary)
                }

                Text(item.modificationDate, format: .dateTime.year().month().day().hour().minute())
                    .foregroundStyle(.tertiary)

                Text(item.url.deletingLastPathComponent().path)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .multilineTextAlignment(.center)
                    .textSelection(.enabled)
            }
        } else if selectedItems.count > 1 {
            VStack(spacing: 6) {
                Text(L10n.format("%lld items", Int64(selectedItems.count)))
                    .font(.system(size: 15, weight: .semibold))

                let fileSize = selectedItems.lazy.filter { !$0.isDirectory }.reduce(Int64(0)) { $0 + $1.size }
                if fileSize > 0 {
                    Text(ByteCountFormatter.string(fromByteCount: fileSize, countStyle: .file))
                        .foregroundStyle(.secondary)
                }
            }
        } else {
            Text("No Selection")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
        }
    }
}

struct FinderThumbnailView: View {
    let item: FileItem
    let size: CGSize

    @Environment(\.displayScale) private var displayScale
    @State private var image: NSImage?

    private var requestKey: ThumbnailCache.RequestKey {
        ThumbnailCache.requestKey(
            for: item.url,
            size: size,
            scale: displayScale,
            modificationDate: item.modificationDate,
            isDirectory: item.isDirectory,
            isPackage: item.isPackage
        )
    }

    var body: some View {
        Image(nsImage: image ?? ThumbnailCache.shared.fallbackIcon(for: item.url, size: size))
            .resizable()
            .interpolation(.high)
            .aspectRatio(contentMode: .fit)
            .task(id: requestKey) {
                image = nil
                image = await ThumbnailCache.shared.image(
                    for: item.url,
                    size: size,
                    scale: displayScale,
                    modificationDate: item.modificationDate,
                    isDirectory: item.isDirectory,
                    isPackage: item.isPackage
                )
            }
    }
}

struct FinderItemsContextMenu: View {
    @ObservedObject var viewModel: FileBrowserViewModel
    @ObservedObject private var clipboard = FileClipboard.shared

    let selection: Set<FileItem.ID>
    let canTransferToAdjacentPane: ([URL], FileDropOperation) -> Bool
    let onFocus: () -> Void
    let onQuickLook: () -> Void
    let onRename: (FileItem) -> Void
    let onGetInfo: () -> Void
    let onCopyToAdjacentPane: ([URL]) -> Void
    let onMoveToAdjacentPane: ([URL]) -> Void

    private var selectedItems: [FileItem] {
        viewModel.items.filter { selection.contains($0.id) }
    }

    private var selectedURLs: [URL] { selectedItems.map(\.url) }

    var body: some View {
        Group {
            Button("Open") {
                prepareSelection()
                openSelectedItems()
            }
            .disabled(selectedItems.isEmpty)

            Button("Quick Look") {
                prepareSelection()
                onQuickLook()
            }
            .disabled(selectedItems.isEmpty)

            if canChooseApplication {
                openWithMenu
            }

            Button("Show in Finder") {
                prepareSelection()
                NSWorkspace.shared.activateFileViewerSelecting(selectedURLs)
            }
            .disabled(selectedItems.isEmpty)

            Button("Get Info") {
                prepareSelection()
                onGetInfo()
            }
            .disabled(selectedItems.isEmpty)

            Divider()

            Button("Copy") {
                prepareSelection()
                clipboard.copy(urls: selectedURLs)
            }
            .disabled(selectedItems.isEmpty)

            Button("Cut") {
                prepareSelection()
                clipboard.cut(urls: selectedURLs)
            }
            .disabled(selectedItems.isEmpty)

            Button("Paste") {
                pasteFromClipboard()
            }
            .disabled(!clipboard.hasContent || pasteDestination == nil)

            Button("Duplicate") {
                prepareSelection()
                viewModel.duplicateSelected()
            }
            .disabled(selectedItems.isEmpty || !viewModel.canCreateItems)

            Divider()

            Button("Copy to Adjacent Pane") {
                prepareSelection()
                onCopyToAdjacentPane(selectedURLs)
            }
            .disabled(!canTransferToAdjacentPane(selectedURLs, .copy))

            Button("Move to Adjacent Pane") {
                prepareSelection()
                onMoveToAdjacentPane(selectedURLs)
            }
            .disabled(!canTransferToAdjacentPane(selectedURLs, .move))

            Divider()

            Button("Rename…") {
                guard let item = selectedItems.first else { return }
                prepareSelection()
                onRename(item)
            }
            .disabled(selectedItems.count != 1)

            if selectedItems.count >= 2 {
                Button(L10n.format("Rename %lld Items…", Int64(selectedItems.count))) {
                    prepareSelection()
                    viewModel.requestBatchRename()
                }
            }

            Divider()

            Button(compressTitle) {
                prepareSelection()
                viewModel.compressItems(selectedURLs)
            }
            .disabled(selectedItems.isEmpty || !haveSameParent)

            if canExtract {
                Button(extractTitle) {
                    prepareSelection()
                    viewModel.extractItems(selectedURLs)
                }
            }

            Button("Move to Trash", role: .destructive) {
                prepareSelection()
                viewModel.deleteSelected()
            }
            .disabled(selectedItems.isEmpty)
        }
    }

    private var openWithMenu: some View {
        let applications = FileOpeningService.shared.applications(for: selectedURLs)
        return Menu("Open With") {
            if applications.isEmpty {
                Button("No Applications Available") {}
                    .disabled(true)
            } else {
                ForEach(applications) { application in
                    Button {
                        prepareSelection()
                        viewModel.openItems(selectedURLs, withApplicationAt: application.url)
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

            Button("Other…", action: chooseApplication)
        }
    }

    private var pasteDestination: URL? {
        viewModel.pasteDestination(for: selection)
    }

    private var canChooseApplication: Bool {
        !selectedItems.isEmpty && selectedItems.allSatisfy { !$0.isDirectory }
    }

    private var canExtract: Bool {
        !selectedItems.isEmpty
            && selectedItems.allSatisfy {
                FileOperationService.isExtractableArchive($0.url) && !$0.isDirectory
            }
    }

    private var haveSameParent: Bool {
        guard let parent = selectedItems.first?.url.deletingLastPathComponent() else { return false }
        return selectedItems.allSatisfy { $0.url.deletingLastPathComponent() == parent }
    }

    private var compressTitle: String {
        guard let first = selectedItems.first else { return L10n.string("Compress") }
        return selectedItems.count == 1
            ? L10n.format("Compress “%@”", first.name)
            : L10n.format("Compress %lld Items", Int64(selectedItems.count))
    }

    private var extractTitle: String {
        guard let first = selectedItems.first else { return L10n.string("Extract") }
        return selectedItems.count == 1
            ? L10n.format("Extract “%@”", first.name)
            : L10n.format("Extract %lld Archives", Int64(selectedItems.count))
    }

    private func prepareSelection() {
        onFocus()
        viewModel.selectForContextMenu(selection)
    }

    private func openSelectedItems() {
        if selectedItems.count == 1, let item = selectedItems.first {
            viewModel.openItem(item)
        } else {
            selectedItems.forEach(viewModel.openItem)
        }
    }

    private func chooseApplication() {
        let panel = NSOpenPanel()
        panel.title = L10n.string("Choose Application")
        panel.message = selectedItems.count == 1
            ? L10n.format("Choose an application to open “%@”.", selectedItems[0].name)
            : L10n.format("Choose an application to open these %lld files.", Int64(selectedItems.count))
        panel.prompt = L10n.string("Open")
        panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        panel.allowedContentTypes = [.applicationBundle]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.treatsFilePackagesAsDirectories = false

        panel.begin { response in
            guard response == .OK, let applicationURL = panel.url else { return }
            prepareSelection()
            viewModel.openItems(selectedURLs, withApplicationAt: applicationURL)
        }
    }

    private func pasteFromClipboard() {
        onFocus()
        guard let destination = pasteDestination, let payload = clipboard.payload else { return }
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
