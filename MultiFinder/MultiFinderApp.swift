import AppKit
import QuickLookUI
import SwiftUI

@MainActor
final class MultiFinderApplicationDelegate: NSObject, NSApplicationDelegate {
    func application(_ application: NSApplication, open urls: [URL]) {
        _ = ExternalOpenRouter.shared.receive(urls: urls, source: .appKit)
    }

    func application(_ sender: NSApplication, openFile filename: String) -> Bool {
        guard !filename.isEmpty else { return false }
        _ = ExternalOpenRouter.shared.receive(
            urls: [URL(fileURLWithPath: filename)],
            source: .appKit
        )
        return true
    }

    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        let urls = filenames
            .filter { !$0.isEmpty }
            .map { URL(fileURLWithPath: $0) }
        _ = ExternalOpenRouter.shared.receive(urls: urls, source: .appKit)
        sender.reply(toOpenOrPrint: urls.count == filenames.count ? .success : .failure)
    }
}

@main
struct MultiFinderApp: App {
    @NSApplicationDelegateAdaptor(MultiFinderApplicationDelegate.self)
    private var applicationDelegate
    @Environment(\.openWindow) private var openWindow
    @FocusedValue(\.layoutManager) private var layoutManager: LayoutManager?
    @FocusedValue(\.workspaceTemplateActions) private var workspaceTemplateActions: WorkspaceTemplateActions?
    @StateObject private var operationService = FileOperationService.shared
    @StateObject private var clipboard = FileClipboard.shared
    @StateObject private var favoritesStore = FavoritesStore.shared

    init() {
        NSTableView.disableZebraStripesGlobally()
        NSTableRowView.disableRowSeparatorsGlobally()
        NSScroller.enforceOverlayGlobally()
    }

    var body: some Scene {
        WindowGroup(id: "workspace") {
            WorkspaceSceneRoot()
        }
        // AppKit owns open-document and custom URL delivery. This prevents
        // WindowGroup from creating a second scene for the same event.
        .handlesExternalEvents(matching: [])
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified)
        .defaultSize(width: 1100, height: 700)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Window") {
                    openWindow(id: "workspace")
                }
                .keyboardShortcut("n", modifiers: .command)

                Button("New Tab") {
                    guard let id = layoutManager?.focusedPaneID else { return }
                    layoutManager?.newTab(in: id)
                }
                .keyboardShortcut("t", modifiers: .command)
                .disabled(layoutManager == nil)

                Button("New Folder") {
                    layoutManager?.focusedPane?.newFolder()
                }
                .keyboardShortcut("n", modifiers: [.command, .shift])
                .disabled(layoutManager?.focusedPane?.canCreateItems != true)

                Divider()

                Button("Get Info") {
                    presentInfo()
                }
                .keyboardShortcut("i", modifiers: .command)
                .disabled(layoutManager?.focusedPane?.selectedItems.isEmpty ?? true)

                Button("Open") {
                    openSelectedItems()
                }
                .keyboardShortcut("o", modifiers: .command)
                .disabled(layoutManager?.focusedPane?.selectedItems.isEmpty ?? true)

                Button("Duplicate") {
                    duplicateSelectedItems()
                }
                .keyboardShortcut("d", modifiers: .command)
                .disabled(
                    layoutManager?.focusedPane?.canCreateItems != true ||
                    (layoutManager?.focusedPane?.selectedItems.isEmpty ?? true)
                )

                Button("Move to Trash") {
                    deleteSelectedItems()
                }
                .keyboardShortcut(.delete, modifiers: .command)
                .disabled(layoutManager?.focusedPane?.selectedItems.isEmpty ?? true)
            }

            CommandGroup(replacing: .saveItem) {
                Button("Save Workspace Template") {
                    workspaceTemplateActions?.save()
                }
                .keyboardShortcut("s", modifiers: .command)
                .disabled(workspaceTemplateActions == nil)

                Button("Save Workspace Template As…") {
                    workspaceTemplateActions?.saveAs()
                }
                .keyboardShortcut("s", modifiers: [.command, .shift])
                .disabled(workspaceTemplateActions == nil)

                Divider()

                Button {
                    closeFocusedItem()
                } label: {
                    Text(verbatim: closeFocusedItemTitle)
                }
                .keyboardShortcut("w", modifiers: .command)
                .disabled(!canCloseFocusedItem)

                Button("Close Window") {
                    closeWorkspaceWindow()
                }
                .keyboardShortcut("w", modifiers: [.command, .shift])
                .disabled(layoutManager == nil && NSApp.keyWindow == nil)
            }

            CommandGroup(replacing: .undoRedo) {
                Button("Undo File Operation") {
                    undo()
                }
                .keyboardShortcut("z", modifiers: .command)

                Button("Redo File Operation") {
                    redo()
                }
                .keyboardShortcut("z", modifiers: [.command, .shift])
            }

            CommandGroup(replacing: .pasteboard) {
                Button("Cut") {
                    cut()
                }
                .keyboardShortcut("x", modifiers: .command)

                Button("Copy") {
                    copy()
                }
                .keyboardShortcut("c", modifiers: .command)

                Button("Paste") {
                    paste()
                }
                .keyboardShortcut("v", modifiers: .command)

                Button("Select All") {
                    selectAll()
                }
                .keyboardShortcut("a", modifiers: .command)

                Divider()

                Button("Rename Selected Items…") {
                    layoutManager?.focusedPane?.requestBatchRename()
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled((layoutManager?.focusedPane?.selectedItems.count ?? 0) < 2)
            }

            CommandGroup(after: .toolbar) {
                Button(toggleFavoriteTitle) {
                    guard let url = layoutManager?.focusedPane?.currentURL else { return }
                    favoritesStore.toggle(url)
                }
                .keyboardShortcut("t", modifiers: [.command, .control])
                .disabled(layoutManager?.focusedPane?.currentURL == nil)

                Button("Toggle Hidden Files") {
                    layoutManager?.focusedPane?.toggleHiddenFiles()
                }
                .keyboardShortcut(".", modifiers: [.command, .shift])
                .disabled(layoutManager == nil)

                Divider()

                Button("Search…") {
                    layoutManager?.focusedPane?.presentSearch()
                }
                .keyboardShortcut("f", modifiers: .command)
                .disabled(layoutManager == nil)

                Button("Ask About Current Folder…") {
                    layoutManager?.focusedPane?.toggleAIAssistant()
                }
                .keyboardShortcut("a", modifiers: [.command, .option])
                .disabled(
                    layoutManager?.focusedPane?.currentURL == nil ||
                    layoutManager?.focusedPane?.isAIAssistantAvailable != true
                )

                Button("Organize Current Folder with AI…") {
                    layoutManager?.focusedPane?.presentAIOrganize()
                }
                .disabled(
                    layoutManager?.focusedPane?.currentURL == nil ||
                    layoutManager?.focusedPane?.isAIAssistantAvailable != true
                )
            }

            CommandMenu("View") {
                Button {
                    layoutManager?.toggleSidebar()
                } label: {
                    Text(verbatim: sidebarToggleTitle)
                }
                .keyboardShortcut("s", modifiers: [.command, .option])
                .disabled(layoutManager == nil)

                Divider()

                Button("as List") {
                    setViewMode(.list)
                }
                .keyboardShortcut("1", modifiers: .command)
                .disabled(layoutManager?.focusedPane == nil)

                Button("as Icons") {
                    setViewMode(.icon)
                }
                .keyboardShortcut("2", modifiers: .command)
                .disabled(layoutManager?.focusedPane == nil)

                Button("as Columns") {
                    setViewMode(.column)
                }
                .keyboardShortcut("3", modifiers: .command)
                .disabled(layoutManager?.focusedPane == nil)

                Button("as Gallery") {
                    setViewMode(.gallery)
                }
                .keyboardShortcut("4", modifiers: .command)
                .disabled(layoutManager?.focusedPane == nil)

                Divider()

                Picker("Sort By", selection: sortFieldSelection) {
                    ForEach(SortField.allCases, id: \.self) { field in
                        Text(verbatim: field.localizedName).tag(field)
                    }
                }
                .disabled(layoutManager?.focusedPane == nil)

                Picker("Sort Direction", selection: sortAscendingSelection) {
                    Text("Ascending").tag(true)
                    Text("Descending").tag(false)
                }
                .disabled(layoutManager?.focusedPane == nil)

                Divider()

                Button("Quick Look", action: quickLookSelectedItems)
                    .disabled(layoutManager?.focusedPane?.selectedItems.isEmpty ?? true)
            }

            CommandMenu("Go") {
                Button("Back", action: goBack)
                    .keyboardShortcut(.leftArrow, modifiers: .command)
                    .disabled(!(layoutManager?.canGoBack ?? false))
                Button("Forward", action: goForward)
                    .keyboardShortcut(.rightArrow, modifiers: .command)
                    .disabled(!(layoutManager?.canGoForward ?? false))
                Button("Enclosing Folder", action: goUp)
                    .keyboardShortcut(.upArrow, modifiers: .command)
                    .disabled(!(layoutManager?.canGoUp ?? false))
                Button("Open", action: openSelectedItems)
                    .keyboardShortcut(.downArrow, modifiers: .command)
                    .disabled(layoutManager?.focusedPane?.selectedItems.isEmpty ?? true)
                Divider()
                Button("Home") {
                    layoutManager?.focusedPane?.navigate(to: FileManager.default.homeDirectoryForCurrentUser)
                }
                .keyboardShortcut("h", modifiers: [.command, .shift])
                Button("Applications") {
                    layoutManager?.focusedPane?.navigate(to: URL(fileURLWithPath: "/Applications"))
                }

                Divider()

                Button("Go to Folder…") {
                    layoutManager?.presentGoToFolder()
                }
                .keyboardShortcut("g", modifiers: [.command, .shift])
                .disabled(layoutManager == nil)
            }

            CommandMenu("Panes") {
                Button("Copy to Adjacent Pane") {
                    layoutManager?.copySelectionToAdjacentPane()
                }
                .keyboardShortcut(KeyEquivalent("\u{F708}"), modifiers: [])
                .disabled(!canTransferSelectionToAdjacentPane(.copy))

                Button("Move to Adjacent Pane") {
                    layoutManager?.moveSelectionToAdjacentPane()
                }
                .keyboardShortcut(KeyEquivalent("\u{F709}"), modifiers: [])
                .disabled(!canTransferSelectionToAdjacentPane(.move))

                Divider()

                Button("Split Right") {
                    guard let id = layoutManager?.focusedPaneID else { return }
                    layoutManager?.addPaneRight(of: id)
                }
                .keyboardShortcut("d", modifiers: [.command, .shift])
                Button("Add Row Below") {
                    guard let id = layoutManager?.focusedPaneID else { return }
                    layoutManager?.addRowBelow(of: id)
                }
                Divider()
                Button("Remove Pane") {
                    guard let id = layoutManager?.focusedPaneID else { return }
                    layoutManager?.removePane(id)
                }
                .disabled((layoutManager?.totalPaneCount ?? 1) <= 1)
                Divider()
                Button("Next Tab") {
                    guard let id = layoutManager?.focusedPaneID else { return }
                    layoutManager?.selectNextTab(in: id)
                }
                .keyboardShortcut(.tab, modifiers: .control)
                .disabled((layoutManager?.focusedBrowserPane?.tabs.count ?? 0) < 2)
                Button("Previous Tab") {
                    guard let id = layoutManager?.focusedPaneID else { return }
                    layoutManager?.selectPreviousTab(in: id)
                }
                .keyboardShortcut(.tab, modifiers: [.control, .shift])
                .disabled((layoutManager?.focusedBrowserPane?.tabs.count ?? 0) < 2)
                Divider()
                Button("Focus Pane Left") { layoutManager?.focusPane(direction: .left) }
                    .keyboardShortcut(.leftArrow, modifiers: [.command, .option])
                Button("Focus Pane Right") { layoutManager?.focusPane(direction: .right) }
                    .keyboardShortcut(.rightArrow, modifiers: [.command, .option])
                Button("Focus Pane Above") { layoutManager?.focusPane(direction: .up) }
                    .keyboardShortcut(.upArrow, modifiers: [.command, .option])
                Button("Focus Pane Below") { layoutManager?.focusPane(direction: .down) }
                    .keyboardShortcut(.downArrow, modifiers: [.command, .option])
            }
        }

        Settings {
            SettingsView()
        }
    }

    private func cut() {
        guard !TextEditingCommandRouter.perform(#selector(NSText.cut(_:))) else { return }
        guard let urls = layoutManager?.focusedPane?.selectedItemURLs, !urls.isEmpty else { return }
        clipboard.cut(urls: urls)
    }

    private func presentInfo() {
        guard !TextEditingCommandRouter.isTextEditingResponder(NSApp.keyWindow?.firstResponder) else {
            return
        }
        layoutManager?.focusedPane?.presentInfo()
    }

    private func openSelectedItems() {
        guard !TextEditingCommandRouter.isTextEditingResponder(NSApp.keyWindow?.firstResponder) else {
            return
        }
        layoutManager?.focusedPane?.openSelectedItems()
    }

    private func deleteSelectedItems() {
        guard !TextEditingCommandRouter.perform(
            #selector(NSStandardKeyBindingResponding.deleteToBeginningOfLine(_:))
        ) else { return }
        layoutManager?.focusedPane?.deleteSelected()
    }

    private func duplicateSelectedItems() {
        guard !TextEditingCommandRouter.isTextEditingResponder(NSApp.keyWindow?.firstResponder) else {
            return
        }
        layoutManager?.focusedPane?.duplicateSelected()
    }

    private func closeFocusedItem() {
        let workspaceWindow = layoutManager?.workspaceWindow
        if let attachedSheet = workspaceWindow?.attachedSheet {
            closeAuxiliaryWindow(attachedSheet)
            return
        }
        if let keyWindow = NSApp.keyWindow,
           keyWindow !== workspaceWindow {
            closeAuxiliaryWindow(keyWindow)
            return
        }

        guard let layoutManager else {
            NSApp.keyWindow?.performClose(nil)
            return
        }

        switch layoutManager.closeTarget {
        case .tab:
            guard let id = layoutManager.focusedPaneID else { return }
            layoutManager.closeTab(in: id)
        case .pane:
            guard let id = layoutManager.focusedPaneID else { return }
            layoutManager.removePane(id)
        case .window:
            (workspaceWindow ?? NSApp.keyWindow)?.performClose(nil)
        }
    }

    private var closeFocusedItemTitle: String {
        if layoutManager?.workspaceWindow?.attachedSheet != nil {
            return L10n.string("Close Window")
        }
        if let workspaceWindow = layoutManager?.workspaceWindow,
           let keyWindow = NSApp.keyWindow,
           keyWindow !== workspaceWindow {
            return L10n.string("Close Window")
        }

        switch layoutManager?.closeTarget {
        case .tab: return L10n.string("Close Tab")
        case .pane: return L10n.string("Close Pane")
        case .window, .none: return L10n.string("Close Window")
        }
    }

    private var canCloseFocusedItem: Bool {
        layoutManager?.workspaceWindow != nil || NSApp.keyWindow != nil
    }

    private func closeWorkspaceWindow() {
        (layoutManager?.workspaceWindow ?? NSApp.keyWindow)?.performClose(nil)
    }

    private func closeAuxiliaryWindow(_ window: NSWindow) {
        let workspaceWindow = layoutManager?.workspaceWindow
        if window is QLPreviewPanel {
            QuickLookManager.shared.closePreview()
        } else if let sheetParent = window.sheetParent {
            sheetParent.endSheet(window, returnCode: .cancel)
        } else {
            window.performClose(nil)
        }

        if let workspaceWindow {
            DispatchQueue.main.async {
                workspaceWindow.makeKeyAndOrderFront(nil)
            }
        }
    }

    private func setViewMode(_ mode: BrowserViewMode) {
        guard !TextEditingCommandRouter.isTextEditingResponder(NSApp.keyWindow?.firstResponder) else {
            return
        }
        layoutManager?.focusedPane?.viewMode = mode
    }

    private func quickLookSelectedItems() {
        guard !TextEditingCommandRouter.isTextEditingResponder(NSApp.keyWindow?.firstResponder),
              let pane = layoutManager?.focusedPane,
              !pane.selectedItemURLs.isEmpty else { return }
        QuickLookManager.shared.togglePreview(urls: pane.selectedItemURLs, ownerID: pane.id)
    }

    private var sortFieldSelection: Binding<SortField> {
        Binding(
            get: { layoutManager?.focusedPane?.sortField ?? .name },
            set: { field in
                guard let pane = layoutManager?.focusedPane else { return }
                pane.setSort(by: field, ascending: pane.sortAscending)
            }
        )
    }

    private var sortAscendingSelection: Binding<Bool> {
        Binding(
            get: { layoutManager?.focusedPane?.sortAscending ?? true },
            set: { ascending in
                guard let pane = layoutManager?.focusedPane else { return }
                pane.setSort(by: pane.sortField, ascending: ascending)
            }
        )
    }

    private func undo() {
        guard !TextEditingCommandRouter.performUndo() else { return }
        operationService.undo()
    }

    private func redo() {
        guard !TextEditingCommandRouter.performRedo() else { return }
        operationService.redo()
    }

    private func goBack() {
        guard !TextEditingCommandRouter.perform(
            #selector(NSStandardKeyBindingResponding.moveToBeginningOfLine(_:))
        ) else { return }
        layoutManager?.focusedPane?.goBack()
    }

    private func goForward() {
        guard !TextEditingCommandRouter.perform(
            #selector(NSStandardKeyBindingResponding.moveToEndOfLine(_:))
        ) else { return }
        layoutManager?.focusedPane?.goForward()
    }

    private func goUp() {
        guard !TextEditingCommandRouter.perform(
            #selector(NSStandardKeyBindingResponding.moveToBeginningOfDocument(_:))
        ) else { return }
        layoutManager?.focusedPane?.goUp()
    }

    private func copy() {
        guard !TextEditingCommandRouter.perform(#selector(NSText.copy(_:))) else { return }
        guard let urls = layoutManager?.focusedPane?.selectedItemURLs, !urls.isEmpty else { return }
        clipboard.copy(urls: urls)
    }

    private func paste() {
        guard !TextEditingCommandRouter.perform(#selector(NSText.paste(_:))) else { return }
        guard let pane = layoutManager?.focusedPane,
              let payload = clipboard.payload else { return }
        if payload.isCut {
            pane.moveItems(from: payload.urls) { result in
                consumeMovedItems(from: payload, result: result)
            }
        } else {
            pane.copyItems(from: payload.urls)
        }
    }

    private func selectAll() {
        guard !TextEditingCommandRouter.perform(#selector(NSText.selectAll(_:))) else { return }
        layoutManager?.focusedPane?.selectAll()
    }

    private func consumeMovedItems(from payload: FileClipboardPayload, result: FileOperationResult) {
        let completedSources = Set(result.completedOutcomes.map { $0.source.standardizedFileURL })
        guard !completedSources.isEmpty else { return }
        let remainingURLs = payload.urls.filter { !completedSources.contains($0.standardizedFileURL) }
        clipboard.consumeIfUnchanged(payload, remainingURLs: remainingURLs)
    }

    private var toggleFavoriteTitle: String {
        guard let url = layoutManager?.focusedPane?.currentURL else {
            return L10n.string("Add to Favorites")
        }
        return favoritesStore.contains(url)
            ? L10n.string("Remove from Favorites")
            : L10n.string("Add to Favorites")
    }

    private var sidebarToggleTitle: String {
        layoutManager?.isSidebarVisible == true
            ? L10n.string("Hide Sidebar")
            : L10n.string("Show Sidebar")
    }

    private func canTransferSelectionToAdjacentPane(_ operation: FileDropOperation) -> Bool {
        guard let layoutManager,
              let focusedPaneID = layoutManager.focusedPaneID else { return false }
        return layoutManager.canTransferSelectionToAdjacentPane(
            from: focusedPaneID,
            operation: operation
        )
    }
}

@MainActor
enum TextEditingCommandRouter {
    @discardableResult
    static func perform(_ action: Selector) -> Bool {
        guard let responder = NSApp.keyWindow?.firstResponder as? NSTextView else { return false }
        return NSApp.sendAction(action, to: responder, from: nil)
    }

    static func isTextEditingResponder(_ responder: NSResponder?) -> Bool {
        responder is NSTextView
    }

    static func performUndo() -> Bool {
        performUndo(on: NSApp.keyWindow?.firstResponder)
    }

    static func performUndo(on responder: NSResponder?) -> Bool {
        guard let responder = responder as? NSTextView else { return false }
        if let undoManager = responder.undoManager, undoManager.canUndo {
            undoManager.undo()
        }
        return true
    }

    static func performRedo() -> Bool {
        performRedo(on: NSApp.keyWindow?.firstResponder)
    }

    static func performRedo(on responder: NSResponder?) -> Bool {
        guard let responder = responder as? NSTextView else { return false }
        if let undoManager = responder.undoManager, undoManager.canRedo {
            undoManager.redo()
        }
        return true
    }
}
