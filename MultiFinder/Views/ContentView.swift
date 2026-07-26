import SwiftUI

struct WorkspaceSceneRoot: View {
    @SceneStorage("MultiFinder.workspaceState") private var workspaceState = ""

    var body: some View {
        ContentView(serializedState: workspaceState) { newState in
            workspaceState = newState
        }
    }
}

struct ContentView: View {
    @StateObject private var layoutManager: LayoutManager
    @Environment(\.scenePhase) private var scenePhase
    private let onPersist: (String) -> Void

    init(serializedState: String = "", onPersist: @escaping (String) -> Void = { _ in }) {
        _layoutManager = StateObject(wrappedValue: LayoutManager(serializedState: serializedState))
        self.onPersist = onPersist
    }

    var body: some View {
        Group {
            if let focusedPane = layoutManager.focusedPane {
                WorkspaceSurface(layoutManager: layoutManager, focusedPane: focusedPane)
            }
        }
        .frame(minWidth: 600, idealWidth: 1100, minHeight: 400, idealHeight: 700)
        .focusedValue(\.layoutManager, layoutManager)
        .onChange(of: layoutManager.serializedState) { _, newState in
            onPersist(newState)
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .inactive || newPhase == .background {
                layoutManager.save()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
            layoutManager.save()
        }
        .onAppear {
            onPersist(layoutManager.serializedState)
        }
    }
}

private struct WorkspaceSurface: View {
    @ObservedObject var layoutManager: LayoutManager
    @ObservedObject var focusedPane: FileBrowserViewModel
    @ObservedObject private var operationService = FileOperationService.shared

    var body: some View {
        WorkspaceLayoutView(layoutManager: layoutManager, focusedPane: focusedPane)
        .navigationTitle(focusedPane.title)
        .toolbar {
            BrowserToolbar(layoutManager: layoutManager, pane: focusedPane)
        }
        .confirmationDialog(
            "An Item Already Exists",
            isPresented: conflictPresented,
            titleVisibility: .visible,
            presenting: operationService.pendingConflict
        ) { _ in
            Button("Replace", role: .destructive) {
                operationService.resolveConflict(.replace, applyToAll: false)
            }
            Button("Replace All", role: .destructive) {
                operationService.resolveConflict(.replace, applyToAll: true)
            }
            Button("Keep Both") {
                operationService.resolveConflict(.keepBoth, applyToAll: false)
            }
            Button("Keep Both for All") {
                operationService.resolveConflict(.keepBoth, applyToAll: true)
            }
            Button("Skip") {
                operationService.resolveConflict(.skip, applyToAll: false)
            }
            Button("Skip All") {
                operationService.resolveConflict(.skip, applyToAll: true)
            }
            Button("Cancel Operation", role: .cancel) {
                operationService.resolveConflict(.cancel, applyToAll: false)
            }
        } message: { conflict in
            Text("“\(conflict.destination.lastPathComponent)” already exists in \(conflict.destination.deletingLastPathComponent().path).")
        }
    }

    private var conflictPresented: Binding<Bool> {
        Binding(
            get: { operationService.pendingConflict != nil },
            set: { presented in
                if !presented, operationService.pendingConflict != nil {
                    operationService.resolveConflict(.cancel, applyToAll: false)
                }
            }
        )
    }
}

private struct BrowserToolbar: ToolbarContent {
    @ObservedObject var layoutManager: LayoutManager
    @ObservedObject var pane: FileBrowserViewModel
    @ObservedObject private var clipboard = FileClipboard.shared
    @ObservedObject private var operationService = FileOperationService.shared
    @ObservedObject private var favoritesStore = FavoritesStore.shared

    var body: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            Button(action: pane.goBack) {
                Image(systemName: "chevron.left")
            }
            .disabled(!pane.canGoBack)
            .help("Back")

            Button(action: pane.goForward) {
                Image(systemName: "chevron.right")
            }
            .disabled(!pane.canGoForward)
            .help("Forward")

            Button(action: pane.goUp) {
                Image(systemName: "arrow.up")
            }
            .disabled(!pane.canGoUp)
            .help("Enclosing Folder")
        }

        ToolbarItemGroup(placement: .automatic) {
            Button(action: toggleFavorite) {
                Image(systemName: isCurrentFolderFavorite ? "star.fill" : "star")
            }
            .disabled(pane.currentURL == nil)
            .help(isCurrentFolderFavorite ? "Remove from Favorites" : "Add to Favorites")

            Button(action: pane.newFolder) {
                Image(systemName: "folder.badge.plus")
            }
            .disabled(!pane.canCreateItems)
            .help("New Folder")

            Button(action: pane.toggleHiddenFiles) {
                Image(systemName: pane.showHiddenFiles ? "eye" : "eye.slash")
            }
            .help("Toggle Hidden Files")

            Button(action: paste) {
                Image(systemName: "doc.on.clipboard")
            }
            .disabled(!clipboard.hasContent || !pane.canCreateItems)
            .help("Paste")
        }

        ToolbarItemGroup(placement: .automatic) {
            Menu {
                if operationService.history.isEmpty {
                    Text("No Operations")
                } else {
                    ForEach(operationService.history.prefix(12)) { record in
                        if record.status == .failed {
                            Button("Retry \(record.kind.rawValue)") {
                                operationService.retry(record.id)
                            }
                        } else {
                            Text("\(record.kind.rawValue) · \(record.status.rawValue.capitalized)")
                        }
                    }
                }
            } label: {
                Image(systemName: "clock.arrow.circlepath")
            }
            .help("Operation History")

            Menu {
                Button("Split Right") {
                    layoutManager.addPaneRight(of: pane.id)
                }
                Button("Split Left") {
                    layoutManager.addPaneLeft(of: pane.id)
                }
                Divider()
                Button("Add Row Below") {
                    layoutManager.addRowBelow(of: pane.id)
                }
                Button("Add Row Above") {
                    layoutManager.addRowAbove(of: pane.id)
                }
                Divider()
                Button("Remove Pane", role: .destructive) {
                    layoutManager.removePane(pane.id)
                }
                .disabled(layoutManager.totalPaneCount <= 1)
            } label: {
                Image(systemName: "plus.square.on.square")
            }
            .help("Arrange Panes")
        }
    }

    private func paste() {
        guard let payload = clipboard.payload else { return }
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

    private var isCurrentFolderFavorite: Bool {
        guard let url = pane.currentURL else { return false }
        return favoritesStore.contains(url)
    }

    private func toggleFavorite() {
        guard let url = pane.currentURL else { return }
        favoritesStore.toggle(url)
    }
}
