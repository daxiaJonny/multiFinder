import SwiftUI
import UniformTypeIdentifiers

struct FileBrowserPane: View {
    @ObservedObject var pane: BrowserPane
    @ObservedObject var layoutManager: LayoutManager
    let isFocused: Bool
    let isHighlighted: Bool
    let onFocus: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            if pane.tabs.count > 1 {
                PaneTabBar(pane: pane, layoutManager: layoutManager, onFocus: onFocus)

                Divider()
            }

            PaneTabContent(
                viewModel: pane.selectedTab,
                paneID: pane.id,
                layoutManager: layoutManager,
                isFocused: isFocused,
                onFocus: onFocus
            )
            .id(pane.selectedTab.id)
        }
        .frame(minWidth: 170, minHeight: 130)
        .overlay(
            RoundedRectangle(cornerRadius: 0)
                .stroke(
                    paneBorderColor,
                    lineWidth: paneBorderWidth
                )
                .shadow(
                    color: isHighlighted ? Color.accentColor.opacity(0.7) : .clear,
                    radius: isHighlighted ? 7 : 0
                )
        )
        .animation(.easeInOut(duration: 0.2), value: isHighlighted)
        .contextMenu {
            paneContextMenu
        }
    }

    // MARK: - Pane Context Menu (tab and split operations)

    @ViewBuilder
    private var paneContextMenu: some View {
        Button("New Tab") {
            layoutManager.newTab(in: pane.id)
        }

        if pane.tabs.count > 1 {
            Button("Close Tab") {
                layoutManager.closeTab(in: pane.id)
            }
        } else {
            Button("Close Pane") {
                layoutManager.removePane(pane.id)
            }
            .disabled(layoutManager.totalPaneCount <= 1)
        }

        Divider()

        Button("Split Right") {
            layoutManager.addPaneRight(of: pane.id)
        }

        Button("Split Left") {
            layoutManager.addPaneLeft(of: pane.id)
        }

        Divider()

        Button("Add Row Above") {
            layoutManager.addRowAbove(of: pane.id)
        }

        Button("Add Row Below") {
            layoutManager.addRowBelow(of: pane.id)
        }

        Divider()

        Button("Remove Pane", role: .destructive) {
            layoutManager.removePane(pane.id)
        }
        .disabled(layoutManager.totalPaneCount <= 1)
    }

    // MARK: - Helpers

    private var paneBorderColor: Color {
        if isHighlighted { return .accentColor }
        return isFocused ? Color.accentColor.opacity(0.4) : Color(nsColor: .separatorColor)
    }

    private var paneBorderWidth: Double {
        isHighlighted ? 3 : (isFocused ? 1.5 : 0.5)
    }
}

private struct PaneTabBar: View {
    @ObservedObject var pane: BrowserPane
    let layoutManager: LayoutManager
    let onFocus: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 1) {
                    ForEach(Array(pane.tabs.enumerated()), id: \.element.id) { index, tab in
                        PaneTabItem(
                            tab: tab,
                            isSelected: index == pane.selectedTabIndex,
                            onSelect: {
                                onFocus()
                                layoutManager.selectTab(at: index, in: pane.id)
                            },
                            onClose: {
                                layoutManager.closeTab(at: index, in: pane.id)
                            }
                        )
                    }
                }
                .padding(.horizontal, 4)
            }

            Button {
                onFocus()
                layoutManager.newTab(in: pane.id)
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(.secondary)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("New Tab")
        }
        .frame(height: 24)
        .background(Color(nsColor: .underPageBackgroundColor))
    }
}

private struct PaneTabItem: View {
    @ObservedObject var tab: FileBrowserViewModel
    let isSelected: Bool
    let onSelect: () -> Void
    let onClose: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 3) {
            Text(tab.title)
                .font(.system(size: 11))
                .lineLimit(1)
                .truncationMode(.tail)
                .foregroundColor(isSelected ? .primary : .secondary)

            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 7, weight: .bold))
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
            .opacity(isHovering || isSelected ? 1 : 0)
            .help("Close Tab")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .frame(maxWidth: 160)
        .background(isSelected ? Color(nsColor: .controlBackgroundColor) : .clear)
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .onHover { isHovering = $0 }
        .help(tab.pathDescription)
    }
}

private struct PaneTabContent: View {
    private struct PendingRename {
        let item: FileItem
        let newName: String
    }

    @ObservedObject var viewModel: FileBrowserViewModel
    let paneID: UUID
    let layoutManager: LayoutManager
    let isFocused: Bool
    let onFocus: () -> Void

    @State private var renameTarget: FileItem?
    @State private var pendingRename: PendingRename?
    @State private var isCurrentDirectoryDropTargeted = false
    @FocusState private var isFilterFieldFocused: Bool
    @ObservedObject private var operationService = FileOperationService.shared

    var body: some View {
        VStack(spacing: 0) {
            if viewModel.isAIAssistantVisible && viewModel.isAIAssistantAvailable && viewModel.currentURL != nil {
                AIInputBar(viewModel: viewModel)

                Divider()
            }

            PathBarView(
                location: viewModel.location,
                isFocused: isFocused,
                onNavigate: { url in
                    onFocus()
                    viewModel.navigate(to: url)
                },
                onNavigateToFile: { url in
                    onFocus()
                    viewModel.navigateToFile(url)
                },
                onRefresh: {
                    onFocus()
                    viewModel.refresh()
                },
                canRemovePane: layoutManager.totalPaneCount > 1,
                onRemovePane: {
                    onFocus()
                    layoutManager.removePane(paneID)
                },
                onTransferDroppedItems: { urls, destination, operation in
                    onFocus()
                    viewModel.transferDroppedItems(urls, into: destination, operation: operation)
                }
            )

            Divider()

            filterBar

            Divider()

            browserContent
            .simultaneousGesture(TapGesture().onEnded { _ in onFocus() })

            Divider()

            statusBar
        }
        .sheet(item: $renameTarget, onDismiss: finishPendingRename) { item in
            RenameSheet(item: item) { newName in
                pendingRename = PendingRename(item: item, newName: newName)
            }
        }
        .sheet(isPresented: batchRenamePresented) {
            if let batchItems = viewModel.batchRenameItems {
                BatchRenameSheet(items: batchItems, viewModel: viewModel)
            }
        }
        .sheet(isPresented: $viewModel.isSearchPresented) {
            FileSearchSheet(viewModel: viewModel)
        }
        .sheet(isPresented: $viewModel.isAIOrganizePresented, onDismiss: viewModel.dismissAIOrganize) {
            AIOrganizeFlowSheet(viewModel: viewModel)
        }
        .alert("Error", isPresented: showErrorBinding) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(viewModel.errorMessage ?? "")
        }
        .onChange(of: viewModel.location) { _, _ in
            QuickLookManager.shared.closePreview(ownerID: quickLookOwnerID)
            layoutManager.save()
        }
        .onChange(of: viewModel.selectedItems) { _, _ in
            syncQuickLookPreview()
        }
        .onChange(of: viewModel.items) { _, _ in
            syncQuickLookPreview()
        }
        .onChange(of: viewModel.sortOrder) { _, _ in
            layoutManager.save()
        }
        .onChange(of: viewModel.viewMode) { _, _ in
            layoutManager.save()
        }
        .onChange(of: viewModel.showHiddenFiles) { _, _ in
            layoutManager.save()
        }
        .onChange(of: viewModel.isInfoPresented) { _, isPresented in
            guard isPresented else { return }
            viewModel.isInfoPresented = false
            presentInfoWindow()
        }
        .onDisappear {
            QuickLookManager.shared.closePreview(ownerID: quickLookOwnerID)
        }
    }

    // MARK: - Status Bar

    @ViewBuilder
    private var browserContent: some View {
        switch viewModel.viewMode {
        case .list:
            FileListView(
                viewModel: viewModel,
                canTransferToAdjacentPane: canTransferToAdjacentPane,
                onFocus: onFocus,
                onBeginFiltering: beginFiltering,
                onQuickLook: quickLook,
                onRename: beginRenaming,
                onGetInfo: viewModel.presentInfo,
                onCopyToAdjacentPane: copyToAdjacentPane,
                onMoveToAdjacentPane: moveToAdjacentPane
            )
        case .icon:
            FileGridView(
                viewModel: viewModel,
                canTransferToAdjacentPane: canTransferToAdjacentPane,
                onFocus: onFocus,
                onBeginFiltering: beginFiltering,
                onQuickLook: quickLook,
                onRename: beginRenaming,
                onGetInfo: viewModel.presentInfo,
                onCopyToAdjacentPane: copyToAdjacentPane,
                onMoveToAdjacentPane: moveToAdjacentPane
            )
        case .column:
            FileColumnView(
                viewModel: viewModel,
                canTransferToAdjacentPane: canTransferToAdjacentPane,
                onFocus: onFocus,
                onBeginFiltering: beginFiltering,
                onQuickLook: quickLook,
                onRename: beginRenaming,
                onGetInfo: viewModel.presentInfo,
                onCopyToAdjacentPane: copyToAdjacentPane,
                onMoveToAdjacentPane: moveToAdjacentPane
            )
        case .gallery:
            FileGalleryView(
                viewModel: viewModel,
                canTransferToAdjacentPane: canTransferToAdjacentPane,
                onFocus: onFocus,
                onBeginFiltering: beginFiltering,
                onQuickLook: quickLook,
                onRename: beginRenaming,
                onGetInfo: viewModel.presentInfo,
                onCopyToAdjacentPane: copyToAdjacentPane,
                onMoveToAdjacentPane: moveToAdjacentPane
            )
        }
    }

    private var filterBar: some View {
        HStack(spacing: 7) {
            Image(systemName: "line.3.horizontal.decrease")
                .foregroundStyle(.secondary)

            TextField("Filter by file name", text: $viewModel.filterText)
                .textFieldStyle(.plain)
                .focused($isFilterFieldFocused)
                .onSubmit {
                    isFilterFieldFocused = false
                }
                .onKeyPress(.escape) {
                    viewModel.clearFilter()
                    isFilterFieldFocused = false
                    return .handled
                }

            if viewModel.isFiltering {
                Button {
                    viewModel.clearFilter()
                    isFilterFieldFocused = true
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Clear Filter")
            }

            Picker("View", selection: $viewModel.viewMode) {
                ForEach(BrowserViewMode.allCases, id: \.self) { mode in
                    Image(systemName: mode.systemImage)
                        .accessibilityLabel(mode.localizedName)
                        .tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .help("View Mode")
        }
        .font(.system(size: 11))
        .padding(.horizontal, 9)
        .frame(height: 27)
        .background(Color(nsColor: .underPageBackgroundColor))
        .onChange(of: isFilterFieldFocused) { _, focused in
            if focused { onFocus() }
        }
    }

    private var statusBar: some View {
        HStack {
            Text(itemCountText)
            Spacer()
            if !viewModel.selectedItems.isEmpty {
                Text(L10n.format("%lld selected", Int64(viewModel.selectedItems.count)))
            }
            if viewModel.isLoading {
                ProgressView()
                    .controlSize(.small)
            }
            if let operation = operationService.activeOperation {
                ProgressView(value: operation.fractionCompleted)
                    .frame(width: 70)
                Button(action: operationService.cancelCurrent) {
                    Image(systemName: "xmark.circle")
                }
                .buttonStyle(.plain)
                .help("Cancel Operation")
            }
        }
        .font(.system(size: 11))
        .foregroundColor(.secondary)
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .background(
            isCurrentDirectoryDropTargeted
                ? Color.accentColor.opacity(0.18)
                : Color(nsColor: .underPageBackgroundColor)
        )
        .onDrop(
            of: [UTType.fileURL],
            delegate: CurrentDirectoryDropDelegate(
                viewModel: viewModel,
                isTargeted: $isCurrentDirectoryDropTargeted,
                onFocus: onFocus
            )
        )
    }

    // MARK: - Helpers

    private func canTransferToAdjacentPane(_ urls: [URL], operation: FileDropOperation) -> Bool {
        layoutManager.canTransferItemsToAdjacentPane(
            urls,
            from: paneID,
            operation: operation
        )
    }

    private func beginFiltering() {
        onFocus()
        isFilterFieldFocused = true
    }

    private func quickLook() {
        QuickLookManager.shared.togglePreview(
            urls: viewModel.selectedItemURLs,
            ownerID: quickLookOwnerID
        )
    }

    private func syncQuickLookPreview() {
        QuickLookManager.shared.updatePreview(
            urls: viewModel.selectedItemURLs,
            ownerID: quickLookOwnerID
        )
    }

    private var quickLookOwnerID: UUID { viewModel.id }

    private func beginRenaming(_ item: FileItem) {
        renameTarget = item
    }

    private func copyToAdjacentPane(_ urls: [URL]) {
        onFocus()
        layoutManager.transferItemsToAdjacentPane(urls, from: paneID, operation: .copy)
    }

    private func moveToAdjacentPane(_ urls: [URL]) {
        onFocus()
        layoutManager.transferItemsToAdjacentPane(urls, from: paneID, operation: .move)
    }

    private func renameFromInfo(_ url: URL, _ newName: String) {
        let item = viewModel.items.first(where: {
            $0.url.standardizedFileURL == url.standardizedFileURL
        }) ?? FileItem(url: url)
        viewModel.rename(item: item, to: newName)
    }

    private func presentInfoWindow() {
        InfoWindowCoordinator.shared.present(
            urls: viewModel.selectedItemURLs,
            onRename: renameFromInfo
        )
    }

    private func finishPendingRename() {
        guard let request = pendingRename else { return }
        pendingRename = nil
        viewModel.rename(item: request.item, to: request.newName)
    }

    private var batchRenamePresented: Binding<Bool> {
        Binding(
            get: { viewModel.batchRenameItems != nil },
            set: { if !$0 { viewModel.batchRenameItems = nil } }
        )
    }

    private var itemCountText: String {
        if viewModel.isFiltering {
            return L10n.format(
                "Showing %lld of %lld items",
                Int64(viewModel.visibleItems.count),
                Int64(viewModel.items.count)
            )
        }
        return viewModel.items.count == 1
            ? L10n.string("1 item")
            : L10n.format("%lld items", Int64(viewModel.items.count))
    }

    private var showErrorBinding: Binding<Bool> {
        Binding(
            get: { viewModel.errorMessage != nil },
            set: { if !$0 { viewModel.errorMessage = nil } }
        )
    }
}

private struct CurrentDirectoryDropDelegate: DropDelegate {
    let viewModel: FileBrowserViewModel
    @Binding var isTargeted: Bool
    let onFocus: () -> Void

    func validateDrop(info: DropInfo) -> Bool {
        viewModel.canCreateItems && info.hasItemsConforming(to: [.fileURL])
    }

    func dropEntered(info: DropInfo) {
        isTargeted = validateDrop(info: info)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        guard validateDrop(info: info) else {
            return DropProposal(operation: .forbidden)
        }
        return DropProposal(operation: currentOperation == .copy ? .copy : .move)
    }

    func dropExited(info: DropInfo) {
        isTargeted = false
    }

    func performDrop(info: DropInfo) -> Bool {
        guard validateDrop(info: info),
              let destination = viewModel.currentURL else { return false }
        let providers = info.itemProviders(for: [.fileURL])
        guard !providers.isEmpty else { return false }
        let operation = currentOperation
        isTargeted = false
        onFocus()

        DroppedFileURLLoader.load(providers) { urls in
            viewModel.transferDroppedItems(urls, into: destination, operation: operation)
        }
        return true
    }

    private var currentOperation: FileDropOperation {
        FileDropModifierKeys.currentOperation
    }
}
