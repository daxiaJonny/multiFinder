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
        .onOpenURL { url in
            guard let request = ExternalOpenRequest(url: url) else { return }
            layoutManager.openExternalPath(request.targetURL)
        }
    }
}

private struct WorkspaceSurface: View {
    @ObservedObject var layoutManager: LayoutManager
    @ObservedObject var focusedPane: FileBrowserViewModel
    @ObservedObject private var operationService = FileOperationService.shared
    @ObservedObject private var templateStore = WorkspaceTemplateStore.shared
    @State private var isNamingTemplate = false
    @State private var templateName = ""
    @State private var templatePendingDeletion: WorkspaceTemplate?

    var body: some View {
        WorkspaceLayoutView(layoutManager: layoutManager, focusedPane: focusedPane)
        .navigationTitle(focusedPane.title)
        .toolbar {
            BrowserToolbar(
                layoutManager: layoutManager,
                pane: focusedPane,
                onSaveTemplate: beginSavingTemplate,
                onDeleteTemplate: { templatePendingDeletion = $0 }
            )
        }
        .alert("Save Workspace Template", isPresented: $isNamingTemplate) {
            TextField("Template Name", text: $templateName)
            Button("Cancel", role: .cancel) {}
            Button("Save", action: saveTemplate)
                .disabled(templateName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .confirmationDialog(
            "Delete Workspace Template?",
            isPresented: deleteTemplatePresented,
            titleVisibility: .visible,
            presenting: templatePendingDeletion
        ) { template in
            Button("Delete \(template.name)", role: .destructive) {
                templateStore.remove(id: template.id)
                templatePendingDeletion = nil
            }
            Button("Cancel", role: .cancel) {
                templatePendingDeletion = nil
            }
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

    private var deleteTemplatePresented: Binding<Bool> {
        Binding(
            get: { templatePendingDeletion != nil },
            set: { if !$0 { templatePendingDeletion = nil } }
        )
    }

    private func beginSavingTemplate() {
        templateName = "Workspace \(templateStore.templates.count + 1)"
        isNamingTemplate = true
    }

    private func saveTemplate() {
        templateStore.save(name: templateName, layoutState: layoutManager.makeTemplateState())
    }
}

private struct BrowserToolbar: ToolbarContent {
    @ObservedObject var layoutManager: LayoutManager
    @ObservedObject var pane: FileBrowserViewModel
    @ObservedObject private var clipboard = FileClipboard.shared
    @ObservedObject private var operationService = FileOperationService.shared
    @ObservedObject private var favoritesStore = FavoritesStore.shared
    @ObservedObject private var templateStore = WorkspaceTemplateStore.shared
    private let iTermService = ITermService.shared
    let onSaveTemplate: () -> Void
    let onDeleteTemplate: (WorkspaceTemplate) -> Void

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

            Button(action: pane.presentSearch) {
                Image(systemName: "magnifyingglass")
                    .accessibilityLabel("搜索")
            }
            .help("搜索")

            Button(action: pane.toggleAIAssistant) {
                Image(systemName: "sparkles")
                    .accessibilityLabel("询问当前文件夹")
            }
            .disabled(pane.currentURL == nil || !pane.isAIAssistantAvailable)
            .help(pane.isAIAssistantAvailable ? "询问当前文件夹" : "未安装 Cursor CLI")

            Button(action: pane.presentAIOrganize) {
                Image(systemName: "wand.and.stars")
                    .accessibilityLabel("AI 整理")
            }
            .disabled(pane.currentURL == nil || !pane.isAIAssistantAvailable)
            .help(pane.isAIAssistantAvailable ? "AI 整理" : "未安装 Cursor CLI")

            Button(action: pane.newFolder) {
                Image(systemName: "folder.badge.plus")
            }
            .disabled(!pane.canCreateItems)
            .help("New Folder")

            Button(action: pane.toggleHiddenFiles) {
                Image(systemName: pane.showHiddenFiles ? "eye" : "eye.slash")
            }
            .help("Toggle Hidden Files")

            Button(action: openInITerm) {
                Image(systemName: "terminal")
            }
            .disabled(pane.currentURL == nil || !iTermService.isAvailable)
            .help(iTermService.isAvailable ? "Open in iTerm2" : "iTerm2 Not Installed")

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
                Button("Save Current Workspace…", action: onSaveTemplate)

                if templateStore.templates.isEmpty {
                    Divider()
                    Text("No Saved Templates")
                } else {
                    Divider()
                    ForEach(templateStore.templates) { template in
                        Button(template.name) {
                            layoutManager.applyTemplate(template.layoutState)
                        }
                    }
                    Divider()
                    Menu("Delete Template") {
                        ForEach(templateStore.templates) { template in
                            Button(template.name, role: .destructive) {
                                onDeleteTemplate(template)
                            }
                        }
                    }
                }
            } label: {
                Image(systemName: "square.grid.2x2")
            }
            .help("Workspace Templates")

            Menu {
                Button {
                    guard let id = layoutManager.focusedPaneID else { return }
                    layoutManager.newTab(in: id)
                } label: {
                    Image(systemName: "plus.rectangle.on.rectangle")
                        .accessibilityLabel("New Tab")
                }
                .help("New Tab")

                Divider()

                Button {
                    guard let id = layoutManager.focusedPaneID else { return }
                    layoutManager.addPaneRight(of: id)
                } label: {
                    Image(systemName: "rectangle.righthalf.inset.filled")
                        .accessibilityLabel("Split Right")
                }
                .help("Split Right")

                Button {
                    guard let id = layoutManager.focusedPaneID else { return }
                    layoutManager.addPaneLeft(of: id)
                } label: {
                    Image(systemName: "rectangle.lefthalf.inset.filled")
                        .accessibilityLabel("Split Left")
                }
                .help("Split Left")

                Divider()

                Button {
                    guard let id = layoutManager.focusedPaneID else { return }
                    layoutManager.addRowBelow(of: id)
                } label: {
                    Image(systemName: "rectangle.bottomhalf.inset.filled")
                        .accessibilityLabel("Add Row Below")
                }
                .help("Add Row Below")

                Button {
                    guard let id = layoutManager.focusedPaneID else { return }
                    layoutManager.addRowAbove(of: id)
                } label: {
                    Image(systemName: "rectangle.tophalf.inset.filled")
                        .accessibilityLabel("Add Row Above")
                }
                .help("Add Row Above")

                Divider()

                Button(role: .destructive) {
                    guard let id = layoutManager.focusedPaneID else { return }
                    layoutManager.removePane(id)
                } label: {
                    Image(systemName: "rectangle.badge.minus")
                        .accessibilityLabel("Remove Pane")
                }
                .disabled(layoutManager.totalPaneCount <= 1)
                .help("Remove Pane")
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

    private func openInITerm() {
        guard let url = pane.currentURL else { return }
        do {
            try iTermService.openDirectory(url)
        } catch {
            pane.errorMessage = error.localizedDescription
        }
    }
}
