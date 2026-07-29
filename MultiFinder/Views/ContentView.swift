import SwiftUI

struct WorkspaceSceneRoot: View {
    @SceneStorage("MultiFinder.workspaceState") private var workspaceState = ""
    @SceneStorage("MultiFinder.activeWorkspaceTemplateID") private var activeTemplateID = ""

    var body: some View {
        ContentView(
            serializedState: workspaceState,
            activeTemplateID: $activeTemplateID
        ) { newState in
            workspaceState = newState
        }
    }
}

struct ContentView: View {
    @StateObject private var layoutManager: LayoutManager
    @Environment(\.scenePhase) private var scenePhase
    @Binding private var activeTemplateID: String
    private let onPersist: (String) -> Void

    init(
        serializedState: String = "",
        activeTemplateID: Binding<String> = .constant(""),
        onPersist: @escaping (String) -> Void = { _ in }
    ) {
        _layoutManager = StateObject(wrappedValue: LayoutManager(serializedState: serializedState))
        _activeTemplateID = activeTemplateID
        self.onPersist = onPersist
    }

    var body: some View {
        Group {
            if let focusedPane = layoutManager.focusedPane {
                WorkspaceSurface(
                    layoutManager: layoutManager,
                    focusedPane: focusedPane,
                    activeTemplateID: $activeTemplateID
                )
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
    @Binding var activeTemplateID: String
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
                activeTemplateID: currentTemplateID,
                onSaveTemplate: saveCurrentTemplate,
                onSaveTemplateAs: beginSavingTemplateAs,
                onApplyTemplate: applyTemplate,
                onDeleteTemplate: { templatePendingDeletion = $0 }
            )
        }
        .focusedValue(
            \.workspaceTemplateActions,
            WorkspaceTemplateActions(save: saveCurrentTemplate, saveAs: beginSavingTemplateAs)
        )
        .alert("另存工作区模板", isPresented: $isNamingTemplate) {
            TextField("模板名称", text: $templateName)
            Button("取消", role: .cancel) {}
            Button("另存为", action: saveTemplateAs)
                .disabled(templateNameIsEmpty || templateNameAlreadyExists)
        } message: {
            if templateNameAlreadyExists {
                Text("已存在同名模板，请使用其他名称。")
            } else {
                Text("将当前工作区创建为新模板，原模板不会被覆盖。")
            }
        }
        .confirmationDialog(
            "删除工作区模板？",
            isPresented: deleteTemplatePresented,
            titleVisibility: .visible,
            presenting: templatePendingDeletion
        ) { template in
            Button("删除“\(template.name)”", role: .destructive) {
                templateStore.remove(id: template.id)
                if currentTemplateID == template.id {
                    activeTemplateID = ""
                }
                templatePendingDeletion = nil
            }
            Button("取消", role: .cancel) {
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

    private var currentTemplateID: WorkspaceTemplate.ID? {
        guard let id = UUID(uuidString: activeTemplateID),
              templateStore.templates.contains(where: { $0.id == id }) else { return nil }
        return id
    }

    private var currentTemplate: WorkspaceTemplate? {
        guard let currentTemplateID else { return nil }
        return templateStore.templates.first { $0.id == currentTemplateID }
    }

    private var templateNameIsEmpty: Bool {
        templateName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var templateNameAlreadyExists: Bool {
        templateStore.contains(name: templateName)
    }

    private func saveCurrentTemplate() {
        guard let currentTemplateID,
              templateStore.update(
                id: currentTemplateID,
                layoutState: layoutManager.makeTemplateState()
              ) != nil else {
            beginSavingTemplateAs()
            return
        }
    }

    private func beginSavingTemplateAs() {
        templateName = availableTemplateName()
        isNamingTemplate = true
    }

    private func saveTemplateAs() {
        guard let template = templateStore.create(
            name: templateName,
            layoutState: layoutManager.makeTemplateState()
        ) else { return }
        activeTemplateID = template.id.uuidString
    }

    private func applyTemplate(_ template: WorkspaceTemplate) {
        guard layoutManager.applyTemplate(template.layoutState) else { return }
        activeTemplateID = template.id.uuidString
    }

    private func availableTemplateName() -> String {
        let baseName = currentTemplate.map { "\($0.name) 副本" }
            ?? "工作区 \(templateStore.templates.count + 1)"
        guard templateStore.contains(name: baseName) else { return baseName }

        var suffix = 2
        while templateStore.contains(name: "\(baseName) \(suffix)") {
            suffix += 1
        }
        return "\(baseName) \(suffix)"
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
    let activeTemplateID: WorkspaceTemplate.ID?
    let onSaveTemplate: () -> Void
    let onSaveTemplateAs: () -> Void
    let onApplyTemplate: (WorkspaceTemplate) -> Void
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
                Button(saveTemplateTitle, action: onSaveTemplate)
                Button("另存为…", action: onSaveTemplateAs)

                if templateStore.templates.isEmpty {
                    Divider()
                    Text("暂无已保存模板")
                } else {
                    Divider()
                    ForEach(templateStore.templates) { template in
                        Button {
                            onApplyTemplate(template)
                        } label: {
                            if template.id == activeTemplateID {
                                Label(template.name, systemImage: "checkmark")
                            } else {
                                Text(template.name)
                            }
                        }
                    }
                    Divider()
                    Menu("删除模板") {
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
            .help("工作区模板")

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

    private var saveTemplateTitle: String {
        guard let activeTemplateID,
              let template = templateStore.templates.first(where: { $0.id == activeTemplateID }) else {
            return "保存…"
        }
        return "保存到“\(template.name)”"
    }
}

struct WorkspaceTemplateActions {
    let save: () -> Void
    let saveAs: () -> Void
}

private struct WorkspaceTemplateActionsKey: FocusedValueKey {
    typealias Value = WorkspaceTemplateActions
}

extension FocusedValues {
    var workspaceTemplateActions: WorkspaceTemplateActions? {
        get { self[WorkspaceTemplateActionsKey.self] }
        set { self[WorkspaceTemplateActionsKey.self] = newValue }
    }
}
