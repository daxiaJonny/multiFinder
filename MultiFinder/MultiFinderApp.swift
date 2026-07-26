import AppKit
import SwiftUI

@main
struct MultiFinderApp: App {
    @Environment(\.openWindow) private var openWindow
    @FocusedValue(\.layoutManager) private var layoutManager: LayoutManager?
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
                    operationService.undo()
                }
                .keyboardShortcut("z", modifiers: .command)
                .disabled(!operationService.canUndo)

                Button("Redo File Operation") {
                    operationService.redo()
                }
                .keyboardShortcut("z", modifiers: [.command, .shift])
                .disabled(!operationService.canRedo)
            }

            CommandGroup(replacing: .pasteboard) {
                Button("Cut") {
                    guard let urls = layoutManager?.focusedPane?.selectedItemURLs else { return }
                    clipboard.cut(urls: urls)
                }
                .keyboardShortcut("x", modifiers: .command)
                .disabled(layoutManager?.focusedPane?.selectedItems.isEmpty != false)

                Button("Copy") {
                    guard let urls = layoutManager?.focusedPane?.selectedItemURLs else { return }
                    clipboard.copy(urls: urls)
                }
                .keyboardShortcut("c", modifiers: .command)
                .disabled(layoutManager?.focusedPane?.selectedItems.isEmpty != false)

                Button("Paste") {
                    paste()
                }
                .keyboardShortcut("v", modifiers: .command)
                .disabled(!clipboard.hasContent || layoutManager?.focusedPane?.canCreateItems != true)

                Button("Select All") {
                    layoutManager?.focusedPane?.selectAll()
                }
                .keyboardShortcut("a", modifiers: .command)
                .disabled(layoutManager == nil)
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
            }

            CommandMenu("Go") {
                Button("Back") { layoutManager?.focusedPane?.goBack() }
                    .keyboardShortcut("[", modifiers: .command)
                Button("Forward") { layoutManager?.focusedPane?.goForward() }
                    .keyboardShortcut("]", modifiers: .command)
                Button("Enclosing Folder") { layoutManager?.focusedPane?.goUp() }
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
    }

    private func paste() {
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

    private func consumeMovedItems(from payload: FileClipboardPayload, result: FileOperationResult) {
        let completedSources = Set(result.completedOutcomes.map { $0.source.standardizedFileURL })
        guard !completedSources.isEmpty else { return }
        let remainingURLs = payload.urls.filter { !completedSources.contains($0.standardizedFileURL) }
        clipboard.consumeIfUnchanged(payload, remainingURLs: remainingURLs)
    }

    private var toggleFavoriteTitle: String {
        guard let url = layoutManager?.focusedPane?.currentURL else { return "Add to Favorites" }
        return favoritesStore.contains(url) ? "Remove from Favorites" : "Add to Favorites"
    }
}
