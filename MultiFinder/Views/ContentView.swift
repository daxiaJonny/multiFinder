import AppKit
import SwiftUI

struct WorkspaceSceneRoot: View {
    @SceneStorage("MultiFinder.workspaceState") private var workspaceState = ""
    @SceneStorage("MultiFinder.activeWorkspaceTemplateID") private var activeTemplateID = ""
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        ContentView(
            serializedState: workspaceState,
            activeTemplateID: $activeTemplateID,
            onPersist: { newState in
                workspaceState = newState
            },
            onRequestWorkspace: {
                openWindow(id: "workspace")
            }
        )
    }
}

struct ContentView: View {
    @StateObject private var layoutManager: LayoutManager
    @ObservedObject private var operationService = FileOperationService.shared
    @Environment(\.scenePhase) private var scenePhase
    @Binding private var activeTemplateID: String
    private let onPersist: (String) -> Void
    private let onRequestWorkspace: ExternalOpenRouter.WorkspaceOpenAction

    init(
        serializedState: String = "",
        activeTemplateID: Binding<String> = .constant(""),
        onPersist: @escaping (String) -> Void = { _ in },
        onRequestWorkspace: @escaping ExternalOpenRouter.WorkspaceOpenAction = {}
    ) {
        _layoutManager = StateObject(wrappedValue: LayoutManager(serializedState: serializedState))
        _activeTemplateID = activeTemplateID
        self.onPersist = onPersist
        self.onRequestWorkspace = onRequestWorkspace
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
        .background {
            WindowFrameRecovery { window in
                guard let window else { return }
                layoutManager.workspaceWindow = window
                ExternalOpenRouter.shared.register(layoutManager: layoutManager, window: window)
            }
        }
        .sheet(
            isPresented: $layoutManager.isGoToFolderPresented,
            onDismiss: layoutManager.dismissGoToFolder
        ) {
            GoToFolderSheet(layoutManager: layoutManager)
        }
        .focusedSceneValue(\.layoutManager, layoutManager)
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
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { notification in
            guard let window = notification.object as? NSWindow else { return }
            ExternalOpenRouter.shared.windowDidBecomeKey(window)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willCloseNotification)) { notification in
            guard let window = notification.object as? NSWindow else { return }
            if window === layoutManager.workspaceWindow,
               operationService.pendingConflict != nil {
                operationService.cancelCurrent()
            }
            ExternalOpenRouter.shared.windowWillClose(window)
        }
        .onAppear {
            onPersist(layoutManager.serializedState)
            ExternalOpenRouter.shared.register(layoutManager: layoutManager)
            ExternalOpenRouter.shared.setWorkspaceOpenAction(onRequestWorkspace)
        }
        .onDisappear {
            if operationService.pendingConflict != nil {
                operationService.cancelCurrent()
            }
            ExternalOpenRouter.shared.unregister(layoutManager: layoutManager)
        }
        .onOpenURL { url in
            _ = ExternalOpenRouter.shared.receive(urls: [url], source: .swiftUI)
        }
    }
}

private struct GoToFolderSheet: View {
    @ObservedObject var layoutManager: LayoutManager
    @Environment(\.dismiss) private var dismiss
    @FocusState private var isPathFocused: Bool
    @State private var path: String
    @State private var errorMessage: String?

    init(layoutManager: LayoutManager) {
        self.layoutManager = layoutManager
        _path = State(initialValue: layoutManager.focusedPane?.currentURL?.path ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Go to Folder")
                .font(.headline)

            TextField("Path", text: $path)
                .textFieldStyle(.roundedBorder)
                .focused($isPathFocused)
                .onSubmit(submit)

            if let errorMessage {
                Text(verbatim: errorMessage)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()

                Button("Cancel", role: .cancel, action: cancel)
                    .keyboardShortcut(.cancelAction)

                Button("Go", action: submit)
                    .keyboardShortcut(.defaultAction)
                    .disabled(path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 440)
        .onAppear {
            path = layoutManager.focusedPane?.currentURL?.path ?? ""
            errorMessage = nil
            isPathFocused = true
        }
    }

    private func submit() {
        guard layoutManager.goToFolder(path) else {
            errorMessage = layoutManager.focusedPane?.errorMessage
                ?? L10n.string("The requested path does not exist.")
            return
        }

        errorMessage = nil
        layoutManager.dismissGoToFolder()
        dismiss()
    }

    private func cancel() {
        layoutManager.dismissGoToFolder()
        dismiss()
    }
}

private struct WindowFrameRecovery: NSViewRepresentable {
    let onWindowChange: @MainActor (NSWindow?) -> Void

    init(onWindowChange: @escaping @MainActor (NSWindow?) -> Void = { _ in }) {
        self.onWindowChange = onWindowChange
    }

    func makeNSView(context: Context) -> WindowFrameRecoveryView {
        WindowFrameRecoveryView(onWindowChange: onWindowChange)
    }

    func updateNSView(_ nsView: WindowFrameRecoveryView, context: Context) {
        nsView.onWindowChange = onWindowChange
        if let window = nsView.window {
            onWindowChange(window)
        }
    }
}

@MainActor
private final class WindowFrameRecoveryView: NSView {
    private static let recoveryVersionKey = "MultiFinder.windowFrameRecovery.v1"
    var onWindowChange: @MainActor (NSWindow?) -> Void

    init(onWindowChange: @escaping @MainActor (NSWindow?) -> Void) {
        self.onWindowChange = onWindowChange
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) {
        onWindowChange = { _ in }
        super.init(coder: coder)
    }

    private static var primaryScreen: NSScreen? {
        NSScreen.screens.first { $0.frame.origin == .zero } ?? NSScreen.screens.first
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        onWindowChange(window)
        guard let window else { return }

        // SwiftUI applies the restored frame after the view enters the window.
        DispatchQueue.main.async {
            Self.recoverIfNeeded(window)
        }
    }

    private static func recoverIfNeeded(_ window: NSWindow) {
        let shouldMigratePreviousFrame = !UserDefaults.standard.bool(forKey: recoveryVersionKey)
        let frame = window.frame
        let titleBarHeight: CGFloat = 44
        let titleBar = NSRect(
            x: frame.minX + min(200, frame.width / 2),
            y: frame.maxY - titleBarHeight,
            width: min(400, frame.width),
            height: titleBarHeight
        )
        let hasVisibleTitleBar = NSScreen.screens.contains { screen in
            screen.visibleFrame.intersects(titleBar)
        }

        guard shouldMigratePreviousFrame || !hasVisibleTitleBar else { return }
        let targetScreen = shouldMigratePreviousFrame
            ? Self.primaryScreen
            : (window.screen ?? Self.primaryScreen)
        guard let screen = targetScreen else { return }

        UserDefaults.standard.set(true, forKey: recoveryVersionKey)

        let visibleFrame = screen.visibleFrame
        var recoveredFrame = frame
        recoveredFrame.size.width = min(max(recoveredFrame.width, 600), visibleFrame.width)
        recoveredFrame.size.height = min(max(recoveredFrame.height, 400), visibleFrame.height)
        recoveredFrame.origin.x = visibleFrame.midX - recoveredFrame.width / 2
        recoveredFrame.origin.y = visibleFrame.midY - recoveredFrame.height / 2

        window.setFrame(recoveredFrame, display: true, animate: false)
        window.makeKeyAndOrderFront(nil)
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
        .overlay(alignment: .bottomTrailing) {
            StashShelfView(layoutManager: layoutManager)
                .padding(16)
        }
        .overlay {
            if layoutManager.isCommandPalettePresented {
                CommandPaletteView(layoutManager: layoutManager)
                    .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .top)))
            }
        }
        .animation(.easeOut(duration: 0.15), value: layoutManager.isCommandPalettePresented)
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
        .focusedSceneValue(
            \.workspaceTemplateActions,
            WorkspaceTemplateActions(save: saveCurrentTemplate, saveAs: beginSavingTemplateAs)
        )
        .alert("Save Workspace Template As", isPresented: $isNamingTemplate) {
            TextField("Template Name", text: $templateName)
            Button("Cancel", role: .cancel) {}
            Button("Save As", action: saveTemplateAs)
                .disabled(templateNameIsEmpty || templateNameAlreadyExists)
        } message: {
            if templateNameAlreadyExists {
                Text("A template with this name already exists. Choose another name.")
            } else {
                Text("Create a new template from the current workspace without replacing the original template.")
            }
        }
        .confirmationDialog(
            "Delete Workspace Template?",
            isPresented: deleteTemplatePresented,
            titleVisibility: .visible,
            presenting: templatePendingDeletion
        ) { template in
            Button(L10n.format("Delete “%@”", template.name), role: .destructive) {
                templateStore.remove(id: template.id)
                if currentTemplateID == template.id {
                    activeTemplateID = ""
                }
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
            Text(L10n.format(
                "“%@” already exists in %@.",
                conflict.destination.lastPathComponent,
                conflict.destination.deletingLastPathComponent().path
            ))
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
        let baseName = currentTemplate.map { L10n.format("%@ Copy", $0.name) }
            ?? L10n.format("Workspace %lld", Int64(templateStore.templates.count + 1))
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
    @ObservedObject private var appSettings = AppSettings.shared
    @ObservedObject private var stashStore = StashShelfStore.shared
    private let terminalService = TerminalService.shared
    let activeTemplateID: WorkspaceTemplate.ID?
    let onSaveTemplate: () -> Void
    let onSaveTemplateAs: () -> Void
    let onApplyTemplate: (WorkspaceTemplate) -> Void
    let onDeleteTemplate: (WorkspaceTemplate) -> Void

    @State private var isToolsPopoverPresented = false

    private var pinnedTools: [ToolbarToolID] {
        ToolbarToolID.allCases
            .filter { appSettings.isToolPinned($0) }
            .sorted { lhs, rhs in
                let indexL = appSettings.pinnedToolbarToolIDs.firstIndex(of: lhs.rawValue) ?? lhs.defaultOrder
                let indexR = appSettings.pinnedToolbarToolIDs.firstIndex(of: rhs.rawValue) ?? rhs.defaultOrder
                return indexL < indexR
            }
    }

    var body: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            Button(action: layoutManager.toggleSidebar) {
                Image(systemName: "sidebar.left")
                    .accessibilityLabel(sidebarToggleTitle)
            }
            .help(sidebarToggleTitle)

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
            ForEach(pinnedTools) { tool in
                pinnedToolView(for: tool)
            }

            Button {
                isToolsPopoverPresented.toggle()
            } label: {
                Image(systemName: "puzzlepiece.extension")
                    .font(.system(size: 11, weight: .medium))
            }
            .popover(isPresented: $isToolsPopoverPresented, arrowEdge: .bottom) {
                ToolbarToolsPopoverView(
                    layoutManager: layoutManager,
                    pane: pane,
                    appSettings: appSettings,
                    stashStore: stashStore,
                    clipboard: clipboard,
                    operationService: operationService,
                    favoritesStore: favoritesStore,
                    templateStore: templateStore,
                    terminalService: terminalService,
                    activeTemplateID: activeTemplateID,
                    onSaveTemplate: onSaveTemplate,
                    onSaveTemplateAs: onSaveTemplateAs,
                    onApplyTemplate: onApplyTemplate,
                    onDeleteTemplate: onDeleteTemplate,
                    onDismiss: { isToolsPopoverPresented = false }
                )
            }
            .help(L10n.string("Toolbar Tools"))
        }
    }

    @ViewBuilder
    private func pinnedToolView(for tool: ToolbarToolID) -> some View {
        switch tool {
        case .commandPalette:
            commandPaletteButton
                .contextMenu { unpinButton(for: tool) }
        case .stashShelf:
            stashShelfButton
                .contextMenu { unpinButton(for: tool) }
        case .aiAssistant:
            aiAssistantButton
                .contextMenu { unpinButton(for: tool) }
        case .aiOrganize:
            aiOrganizeButton
                .contextMenu { unpinButton(for: tool) }
        case .search:
            searchButton
                .contextMenu { unpinButton(for: tool) }
        case .favorite:
            favoriteButton
                .contextMenu { unpinButton(for: tool) }
        case .newFolder:
            newFolderButton
                .contextMenu { unpinButton(for: tool) }
        case .hiddenFiles:
            hiddenFilesButton
                .contextMenu { unpinButton(for: tool) }
        case .terminal:
            terminalButton
                .contextMenu { unpinButton(for: tool) }
        case .paste:
            pasteButton
                .contextMenu { unpinButton(for: tool) }
        case .operationHistory:
            historyMenu
                .contextMenu { unpinButton(for: tool) }
        case .workspaceTemplates:
            templatesMenu
                .contextMenu { unpinButton(for: tool) }
        case .arrangePanes:
            arrangePanesMenu
                .contextMenu { unpinButton(for: tool) }
        }
    }

    private func unpinButton(for tool: ToolbarToolID) -> some View {
        Button(role: .destructive) {
            withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
                appSettings.unpinTool(tool)
            }
        } label: {
            Label("从工具栏取消固定", systemImage: "pin.slash")
        }
    }

    private var commandPaletteButton: some View {
        Button(action: layoutManager.toggleCommandPalette) {
            HStack(spacing: 3) {
                Image(systemName: "command")
                    .font(.system(size: 10, weight: .semibold))
                Text("K")
                    .font(.system(size: 11, weight: .semibold))
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(
                Capsule()
                    .fill(layoutManager.isCommandPalettePresented ? MFDTheme.primaryAccent.opacity(0.18) : Color.primary.opacity(0.06))
                    .overlay(
                        Capsule()
                            .stroke(layoutManager.isCommandPalettePresented ? MFDTheme.primaryAccent.opacity(0.5) : MFDTheme.subtleHairline, lineWidth: 0.8)
                    )
            )
            .foregroundStyle(layoutManager.isCommandPalettePresented ? MFDTheme.primaryAccent : .secondary)
        }
        .buttonStyle(.plain)
        .help("Command Palette (⌘K)")
    }

    private var stashShelfButton: some View {
        Button(action: stashStore.togglePresented) {
            HStack(spacing: 3) {
                Image(systemName: "tray.2.fill")
                    .font(.system(size: 10, weight: .semibold))
                if stashStore.count > 0 {
                    Text("\(stashStore.count)")
                        .font(.system(size: 10, weight: .bold))
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(
                Capsule()
                    .fill(stashStore.isPresented ? MFDTheme.primaryAccent.opacity(0.18) : Color.primary.opacity(0.06))
                    .overlay(
                        Capsule()
                            .stroke(stashStore.isPresented ? MFDTheme.primaryAccent.opacity(0.5) : MFDTheme.subtleHairline, lineWidth: 0.8)
                    )
            )
            .foregroundStyle(stashStore.isPresented ? MFDTheme.primaryAccent : .secondary)
        }
        .buttonStyle(.plain)
        .help("Stash Shelf (⌘B)")
    }

    private var aiAssistantButton: some View {
        Button(action: pane.toggleAIAssistant) {
            Image(systemName: "sparkles")
                .accessibilityLabel("Ask About Current Folder")
        }
        .disabled(pane.currentURL == nil || !pane.isAIAssistantAvailable)
        .help(
            pane.isAIAssistantAvailable
                ? L10n.string("Ask About Current Folder")
                : L10n.string("Cursor CLI Not Installed")
        )
    }

    private var aiOrganizeButton: some View {
        Button(action: pane.presentAIOrganize) {
            Image(systemName: "wand.and.stars")
                .accessibilityLabel("AI Organize")
        }
        .disabled(pane.currentURL == nil || !pane.isAIAssistantAvailable)
        .help(
            pane.isAIAssistantAvailable
                ? L10n.string("AI Organize")
                : L10n.string("Cursor CLI Not Installed")
        )
    }

    private var searchButton: some View {
        Button(action: pane.presentSearch) {
            Image(systemName: "magnifyingglass")
                .accessibilityLabel("Search")
        }
        .help("Search")
    }

    private var favoriteButton: some View {
        Button(action: toggleFavorite) {
            Image(systemName: isCurrentFolderFavorite ? "star.fill" : "star")
        }
        .disabled(pane.currentURL == nil)
        .help(
            isCurrentFolderFavorite
                ? L10n.string("Remove from Favorites")
                : L10n.string("Add to Favorites")
        )
    }

    private var newFolderButton: some View {
        Button(action: pane.newFolder) {
            Image(systemName: "folder.badge.plus")
        }
        .disabled(!pane.canCreateItems)
        .help("New Folder")
    }

    private var hiddenFilesButton: some View {
        Button(action: pane.toggleHiddenFiles) {
            Image(systemName: pane.showHiddenFiles ? "eye" : "eye.slash")
        }
        .help("Toggle Hidden Files")
    }

    private var terminalButton: some View {
        Button(action: openInTerminal) {
            Image(systemName: "terminal")
        }
        .disabled(pane.currentURL == nil || !terminalService.isAvailable)
        .help(
            terminalService.isAvailable
                ? L10n.format("Open in %@", terminalApplicationName)
                : L10n.format("%@ is not installed.", terminalApplicationName)
        )
    }

    private var pasteButton: some View {
        Button(action: paste) {
            Image(systemName: "doc.on.clipboard")
        }
        .disabled(!clipboard.hasContent || !pane.canCreateItems)
        .help("Paste")
    }

    private var historyMenu: some View {
        Menu {
            if operationService.history.isEmpty {
                Text("No Operations")
            } else {
                ForEach(operationService.history.prefix(12)) { record in
                    if record.status == .failed {
                        Button(L10n.format("Retry %@", record.kind.localizedName)) {
                            operationService.retry(record.id)
                        }
                    } else {
                        Text(L10n.format(
                            "%@ · %@",
                            record.kind.localizedName,
                            record.status.localizedName
                        ))
                    }
                }
            }
        } label: {
            Image(systemName: "clock.arrow.circlepath")
        }
        .help("Operation History")
    }

    private var templatesMenu: some View {
        Menu {
            Button(saveTemplateTitle, action: onSaveTemplate)
            Button("Save As…", action: onSaveTemplateAs)

            if templateStore.templates.isEmpty {
                Divider()
                Text("No Saved Templates")
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
    }

    private var arrangePanesMenu: some View {
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

    private var sidebarToggleTitle: String {
        layoutManager.isSidebarVisible
            ? L10n.string("Hide Sidebar")
            : L10n.string("Show Sidebar")
    }

    private func toggleFavorite() {
        guard let url = pane.currentURL else { return }
        favoritesStore.toggle(url)
    }

    private func openInTerminal() {
        guard let url = pane.currentURL else { return }
        do {
            try terminalService.openDirectory(url)
        } catch {
            pane.errorMessage = error.localizedDescription
        }
    }

    private var terminalApplicationName: String {
        appSettings.preferredTerminalApplication.displayName
    }

    private var saveTemplateTitle: String {
        guard let activeTemplateID,
              let template = templateStore.templates.first(where: { $0.id == activeTemplateID }) else {
            return L10n.string("Save…")
        }
        return L10n.format("Save to “%@”", template.name)
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
