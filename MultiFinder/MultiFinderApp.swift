import AppKit
import SwiftUI

@main
struct MultiFinderApp: App {
    @Environment(\.openWindow) private var openWindow
    @FocusedValue(\.layoutManager) private var layoutManager: LayoutManager?
    @FocusedValue(\.workspaceTemplateActions) private var workspaceTemplateActions: WorkspaceTemplateActions?
    @StateObject private var operationService = FileOperationService.shared
    @StateObject private var clipboard = FileClipboard.shared
    @StateObject private var favoritesStore = FavoritesStore.shared

    var body: some Scene {
        WindowGroup(id: "workspace") {
            WorkspaceSceneRoot()
        }
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

                Button("Close Tab") {
                    guard let id = layoutManager?.focusedPaneID else { return }
                    layoutManager?.closeTab(in: id)
                }
                .keyboardShortcut("w", modifiers: .command)
                .disabled(layoutManager?.canCloseTab != true)

                Button("Close Window") {
                    NSApp.keyWindow?.performClose(nil)
                }
                .keyboardShortcut("w", modifiers: [.command, .shift])
            }

            CommandGroup(replacing: .undoRedo) {
                Button("Undo File Operation") {
                    undo()
                }
                .keyboardShortcut("z", modifiers: .command)

                Button("Redo File Operation") {
                    redo()
                }
                .keyboardShortcut("y", modifiers: .command)
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
                .keyboardShortcut("d", modifiers: .command)
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

            CommandMenu("Go") {
                Button("Back", action: goBack)
                    .keyboardShortcut(.leftArrow, modifiers: .command)
                Button("Forward", action: goForward)
                    .keyboardShortcut(.rightArrow, modifiers: .command)
                Button("Enclosing Folder", action: goUp)
                    .keyboardShortcut(.upArrow, modifiers: .command)
                Divider()
                Button("Home") {
                    layoutManager?.focusedPane?.navigate(to: FileManager.default.homeDirectoryForCurrentUser)
                }
                .keyboardShortcut("h", modifiers: [.command, .shift])
                Button("Applications") {
                    layoutManager?.focusedPane?.navigate(to: URL(fileURLWithPath: "/Applications"))
                }
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
