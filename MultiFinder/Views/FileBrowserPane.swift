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
        .background(isFocused ? Color(nsColor: .controlBackgroundColor) : Color(nsColor: .windowBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(
                    isHighlighted
                        ? MFDTheme.primaryAccent
                        : (isFocused ? MFDTheme.primaryAccent.opacity(0.65) : MFDTheme.subtleHairline),
                    lineWidth: isHighlighted ? 2.5 : (isFocused ? 1.5 : 0.8)
                )
        )
        .overlay {
            PaneFocusMonitor(onFocus: onFocus)
                .allowsHitTesting(false)
        }
        .shadow(color: Color.black.opacity(isFocused ? 0.16 : 0.05), radius: isFocused ? 6 : 2, y: 1)
        .animation(.easeOut(duration: 0.12), value: isFocused)
        .animation(.easeOut(duration: 0.12), value: isHighlighted)
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

}

private struct PaneTabBar: View {
    @ObservedObject var pane: BrowserPane
    let layoutManager: LayoutManager
    let onFocus: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
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
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
            }

            Button {
                onFocus()
                layoutManager.newTab(in: pane.id)
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(.secondary)
                    .frame(width: 20, height: 20)
                    .background(
                        RoundedRectangle(cornerRadius: 4)
                            .fill(MFDTheme.breadcrumbPillBackground)
                    )
            }
            .buttonStyle(.plain)
            .padding(.trailing, 6)
            .help("New Tab")
        }
        .frame(height: 26)
        .background(MFDTheme.paneTabBarBackground)
    }
}

private struct PaneTabItem: View {
    @ObservedObject var tab: FileBrowserViewModel
    let isSelected: Bool
    let onSelect: () -> Void
    let onClose: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "folder")
                .font(.system(size: 9))
                .foregroundColor(isSelected ? MFDTheme.primaryAccent : .secondary)

            Text(tab.title)
                .font(.system(size: 11, weight: isSelected ? .medium : .regular))
                .lineLimit(1)
                .truncationMode(.tail)
                .foregroundColor(isSelected ? .primary : .secondary)

            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 7, weight: .bold))
                    .foregroundColor(.secondary)
                    .frame(width: 14, height: 14)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .opacity(isHovering || isSelected ? 1 : 0)
            .help("Close Tab")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .frame(maxWidth: 160)
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(isSelected ? MFDTheme.activeTabBackground : (isHovering ? MFDTheme.hoverPillBackground : Color.clear))
                .shadow(color: isSelected ? Color.black.opacity(0.06) : Color.clear, radius: 2, y: 1)
        )
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
                viewModel: viewModel,
                location: viewModel.location,
                isFocused: isFocused,
                isFilterFocused: $isFilterFieldFocused,
                onFocus: onFocus,
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

    private var statusBar: some View {
        HStack(spacing: 8) {
            HStack(spacing: 4) {
                Image(systemName: "folder")
                    .font(.system(size: 9))
                Text(itemCountText)
            }
            .font(.system(size: 11))
            .foregroundStyle(.secondary)

            Spacer()

            if !viewModel.selectedItems.isEmpty {
                HStack(spacing: 4) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 9))
                    Text(L10n.format("%lld selected", Int64(viewModel.selectedItems.count)))
                }
                .font(.system(size: 10, weight: .medium))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(
                    Capsule()
                        .fill(MFDTheme.primaryAccent.opacity(0.15))
                )
                .foregroundStyle(MFDTheme.primaryAccent)
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
                ? MFDTheme.primaryAccent.opacity(0.18)
                : MFDTheme.paneHeaderBackground.opacity(0.5)
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

// MARK: - Pane Focus Monitor (Instant 0ms focus switching on mouse down)

private struct PaneFocusMonitor: NSViewRepresentable {
    let onFocus: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onFocus: onFocus)
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        context.coordinator.attach(to: view)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.onFocus = onFocus
        context.coordinator.attach(to: nsView)
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.detach()
    }

    @MainActor
    final class Coordinator: NSObject {
        var onFocus: () -> Void
        private weak var view: NSView?
        private var monitor: Any?

        init(onFocus: @escaping () -> Void) {
            self.onFocus = onFocus
        }

        func attach(to view: NSView) {
            self.view = view
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
                guard let self = self,
                      let view = self.view,
                      let window = view.window,
                      event.window === window else {
                    return event
                }
                let locationInWindow = event.locationInWindow
                let viewFrameInWindow = view.convert(view.bounds, to: nil)
                if viewFrameInWindow.contains(locationInWindow) {
                    self.onFocus()
                }
                return event
            }
        }

        func detach() {
            if let monitor {
                NSEvent.removeMonitor(monitor)
                self.monitor = nil
            }
            view = nil
        }
    }
}
