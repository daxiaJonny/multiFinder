import AppKit
import SwiftUI

struct CommandPaletteItem: Identifiable, Equatable {
    let id: String
    let title: String
    let subtitle: String?
    let category: CommandCategory
    let iconName: String
    let iconColor: Color
    let shortcut: String?
    let action: () -> Void

    static func == (lhs: CommandPaletteItem, rhs: CommandPaletteItem) -> Bool {
        lhs.id == rhs.id
    }
}

enum CommandCategory: String, CaseIterable, Comparable {
    case navigation = "Navigation"
    case panes = "Panes & Layout"
    case view = "View Mode"
    case file = "File Actions"
    case ai = "AI Tools"

    var sortOrder: Int {
        switch self {
        case .navigation: return 0
        case .panes: return 1
        case .view: return 2
        case .file: return 3
        case .ai: return 4
        }
    }

    static func < (lhs: CommandCategory, rhs: CommandCategory) -> Bool {
        lhs.sortOrder < rhs.sortOrder
    }
}

struct CommandPaletteView: View {
    @ObservedObject var layoutManager: LayoutManager
    @FocusState private var isSearchFieldFocused: Bool
    @State private var query = ""
    @State private var selectedIndex = 0

    private var allCommands: [CommandPaletteItem] {
        buildCommands()
    }

    private var filteredCommands: [CommandPaletteItem] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if trimmed.isEmpty {
            return allCommands
        }
        return allCommands.filter { item in
            item.title.localizedCaseInsensitiveContains(trimmed) ||
            (item.subtitle?.localizedCaseInsensitiveContains(trimmed) ?? false) ||
            item.category.rawValue.localizedCaseInsensitiveContains(trimmed)
        }
    }

    var body: some View {
        ZStack {
            // Semi-transparent backdrop to dismiss
            Color.black.opacity(0.35)
                .ignoresSafeArea()
                .onTapGesture {
                    dismiss()
                }

            // Floating glass HUD card positioned in top 18% of window
            VStack(spacing: 0) {
                searchHeader

                Divider()
                    .opacity(0.4)

                resultsList
            }
            .frame(width: 580)
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(MFDTheme.specularHighlightGradient, lineWidth: 1)
            )
            .shadow(color: Color.black.opacity(0.35), radius: 24, y: 12)
            .shadow(color: MFDTheme.activeAmbientGlow, radius: 14, y: 4)
            .padding(.top, 40)
            .frame(maxHeight: .infinity, alignment: .top)
        }
        .onAppear {
            isSearchFieldFocused = true
            selectedIndex = 0
        }
        .onKeyPress(.escape) {
            dismiss()
            return .handled
        }
        .onKeyPress(.downArrow) {
            selectNext()
            return .handled
        }
        .onKeyPress(.upArrow) {
            selectPrevious()
            return .handled
        }
        .onKeyPress(.return) {
            executeSelected()
            return .handled
        }
    }

    // MARK: - Search Header

    private var searchHeader: some View {
        HStack(spacing: 12) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(MFDTheme.primaryAccent)

            TextField("Search commands, navigation, actions…", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 15, weight: .regular))
                .focused($isSearchFieldFocused)
                .onChange(of: query) { _, _ in
                    selectedIndex = 0
                }

            if !query.isEmpty {
                Button {
                    query = ""
                    selectedIndex = 0
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }

            Text("ESC to close")
                .font(.system(size: 10, weight: .medium))
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(Color.white.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    // MARK: - Results List

    private var resultsList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 4) {
                    if filteredCommands.isEmpty {
                        VStack(spacing: 8) {
                            Image(systemName: "questionmark.folder")
                                .font(.system(size: 28))
                                .foregroundStyle(.secondary)
                            Text("No matching commands found")
                                .font(.system(size: 13))
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 36)
                    } else {
                        ForEach(Array(filteredCommands.enumerated()), id: \.element.id) { index, item in
                            commandRow(item: item, isSelected: index == selectedIndex)
                                .id(item.id)
                                .onTapGesture {
                                    selectedIndex = index
                                    executeSelected()
                                }
                        }
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
            }
            .frame(maxHeight: 340)
            .onChange(of: selectedIndex) { _, newIndex in
                if filteredCommands.indices.contains(newIndex) {
                    withAnimation(.easeInOut(duration: 0.1)) {
                        proxy.scrollTo(filteredCommands[newIndex].id, anchor: .center)
                    }
                }
            }
        }
    }

    private func commandRow(item: CommandPaletteItem, isSelected: Bool) -> some View {
        HStack(spacing: 12) {
            Image(systemName: item.iconName)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(item.iconColor)
                .frame(width: 24, height: 24)
                .background(item.iconColor.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(.primary)

                if let subtitle = item.subtitle {
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            Text(item.category.rawValue)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.white.opacity(0.05))
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))

            if let shortcut = item.shortcut {
                Text(shortcut)
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.black.opacity(0.2))
                    .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isSelected ? MFDTheme.primaryAccent.opacity(0.18) : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(isSelected ? MFDTheme.primaryAccent.opacity(0.4) : Color.clear, lineWidth: 1)
        )
        .contentShape(Rectangle())
    }

    // MARK: - Navigation & Actions

    private func selectNext() {
        guard !filteredCommands.isEmpty else { return }
        selectedIndex = (selectedIndex + 1) % filteredCommands.count
    }

    private func selectPrevious() {
        guard !filteredCommands.isEmpty else { return }
        selectedIndex = (selectedIndex - 1 + filteredCommands.count) % filteredCommands.count
    }

    private func executeSelected() {
        guard filteredCommands.indices.contains(selectedIndex) else { return }
        let command = filteredCommands[selectedIndex]
        dismiss()
        // Execute on next runloop to allow smooth dismiss animation
        DispatchQueue.main.async {
            command.action()
        }
    }

    private func dismiss() {
        layoutManager.dismissCommandPalette()
    }

    // MARK: - Command Builder

    private func buildCommands() -> [CommandPaletteItem] {
        var items: [CommandPaletteItem] = []

        // MARK: Navigation
        items.append(CommandPaletteItem(
            id: "nav.goto",
            title: "Go to Folder…",
            subtitle: "Open directory by path",
            category: .navigation,
            iconName: "folder.badge.gearshape",
            iconColor: .blue,
            shortcut: "⇧⌘G",
            action: { layoutManager.presentGoToFolder() }
        ))

        items.append(CommandPaletteItem(
            id: "nav.home",
            title: "Go to Home Folder",
            subtitle: FileManager.default.homeDirectoryForCurrentUser.path,
            category: .navigation,
            iconName: "house.fill",
            iconColor: .blue,
            shortcut: "⇧⌘H",
            action: { layoutManager.focusedPane?.navigate(to: FileManager.default.homeDirectoryForCurrentUser) }
        ))

        items.append(CommandPaletteItem(
            id: "nav.apps",
            title: "Go to Applications",
            subtitle: "/Applications",
            category: .navigation,
            iconName: "app.fill",
            iconColor: .indigo,
            shortcut: nil,
            action: { layoutManager.focusedPane?.navigate(to: URL(fileURLWithPath: "/Applications")) }
        ))

        let docURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        if let docURL {
            items.append(CommandPaletteItem(
                id: "nav.docs",
                title: "Go to Documents",
                subtitle: docURL.path,
                category: .navigation,
                iconName: "doc.text.fill",
                iconColor: .cyan,
                shortcut: nil,
                action: { layoutManager.focusedPane?.navigate(to: docURL) }
            ))
        }

        let downloadURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        if let downloadURL {
            items.append(CommandPaletteItem(
                id: "nav.downloads",
                title: "Go to Downloads",
                subtitle: downloadURL.path,
                category: .navigation,
                iconName: "arrow.down.circle.fill",
                iconColor: .teal,
                shortcut: nil,
                action: { layoutManager.focusedPane?.navigate(to: downloadURL) }
            ))
        }

        // Add Favorites
        for fav in FavoritesStore.shared.favorites {
            items.append(CommandPaletteItem(
                id: "nav.fav.\(fav.url.path)",
                title: fav.name,
                subtitle: "Favorite: \(fav.url.path)",
                category: .navigation,
                iconName: "star.fill",
                iconColor: .yellow,
                shortcut: nil,
                action: { layoutManager.focusedPane?.navigate(to: fav.url) }
            ))
        }

        // MARK: Panes & Layout
        if let focusedID = layoutManager.focusedPaneID {
            items.append(CommandPaletteItem(
                id: "pane.splitRight",
                title: "Split Right",
                subtitle: "Add pane to the right",
                category: .panes,
                iconName: "rectangle.split.2x1.fill",
                iconColor: .purple,
                shortcut: "⇧⌘D",
                action: { layoutManager.addPaneRight(of: focusedID) }
            ))

            items.append(CommandPaletteItem(
                id: "pane.addRowBelow",
                title: "Add Row Below",
                subtitle: "Add pane row below",
                category: .panes,
                iconName: "rectangle.split.1x2.fill",
                iconColor: .purple,
                shortcut: nil,
                action: { layoutManager.addRowBelow(of: focusedID) }
            ))

            items.append(CommandPaletteItem(
                id: "pane.newTab",
                title: "New Tab in Current Pane",
                subtitle: "Add browser tab",
                category: .panes,
                iconName: "plus.rectangle.fill",
                iconColor: .green,
                shortcut: "⌘T",
                action: { layoutManager.newTab(in: focusedID) }
            ))

            if layoutManager.totalPaneCount > 1 {
                items.append(CommandPaletteItem(
                    id: "pane.remove",
                    title: "Close Current Pane",
                    subtitle: "Remove pane from layout",
                    category: .panes,
                    iconName: "xmark.rectangle.fill",
                    iconColor: .red,
                    shortcut: nil,
                    action: { layoutManager.removePane(focusedID) }
                ))
            }
        }

        items.append(CommandPaletteItem(
            id: "pane.toggleSidebar",
            title: "Toggle Sidebar",
            subtitle: layoutManager.isSidebarVisible ? "Hide sidebar" : "Show sidebar",
            category: .panes,
            iconName: "sidebar.left",
            iconColor: .orange,
            shortcut: "⌥⌘S",
            action: { layoutManager.toggleSidebar() }
        ))

        // MARK: View Modes
        if let pane = layoutManager.focusedPane {
            items.append(CommandPaletteItem(
                id: "view.list",
                title: "View as List",
                subtitle: "Detailed table list",
                category: .view,
                iconName: "list.bullet",
                iconColor: .blue,
                shortcut: "⌘1",
                action: { pane.viewMode = .list }
            ))

            items.append(CommandPaletteItem(
                id: "view.icon",
                title: "View as Icons",
                subtitle: "Grid thumbnail view",
                category: .view,
                iconName: "square.grid.2x2",
                iconColor: .blue,
                shortcut: "⌘2",
                action: { pane.viewMode = .icon }
            ))

            items.append(CommandPaletteItem(
                id: "view.column",
                title: "View as Columns",
                subtitle: "Hierarchical column view",
                category: .view,
                iconName: "rectangle.split.3x1",
                iconColor: .blue,
                shortcut: "⌘3",
                action: { pane.viewMode = .column }
            ))

            items.append(CommandPaletteItem(
                id: "view.gallery",
                title: "View as Gallery",
                subtitle: "Large preview gallery",
                category: .view,
                iconName: "rectangle.inset.filled.and.person.filled",
                iconColor: .blue,
                shortcut: "⌘4",
                action: { pane.viewMode = .gallery }
            ))

            items.append(CommandPaletteItem(
                id: "view.hiddenFiles",
                title: "Toggle Hidden Files",
                subtitle: pane.showHiddenFiles ? "Hide dotfiles" : "Show dotfiles",
                category: .view,
                iconName: "eye.slash",
                iconColor: .gray,
                shortcut: "⇧⌘.",
                action: { pane.toggleHiddenFiles() }
            ))
        }

        // MARK: File Actions
        if let pane = layoutManager.focusedPane {
            items.append(CommandPaletteItem(
                id: "file.newFolder",
                title: "New Folder",
                subtitle: "Create untitled folder",
                category: .file,
                iconName: "folder.badge.plus",
                iconColor: .green,
                shortcut: "⇧⌘N",
                action: { pane.newFolder() }
            ))

            items.append(CommandPaletteItem(
                id: "file.newText",
                title: "New Text File",
                subtitle: "Create an empty .txt file",
                category: .file,
                iconName: "doc.badge.plus",
                iconColor: .green,
                shortcut: "⌥⌘N",
                action: { pane.createFile(.text) }
            ))

            items.append(CommandPaletteItem(
                id: "file.newMarkdown",
                title: "New Markdown File",
                subtitle: "Create an empty .md file",
                category: .file,
                iconName: "doc.richtext",
                iconColor: .green,
                shortcut: nil,
                action: { pane.createFile(.markdown) }
            ))

            items.append(CommandPaletteItem(
                id: "file.newJSON",
                title: "New JSON File",
                subtitle: "Create an empty .json file",
                category: .file,
                iconName: "curlybraces",
                iconColor: .green,
                shortcut: nil,
                action: { pane.createFile(.json) }
            ))

            if pane.currentURL != nil {
                items.append(CommandPaletteItem(
                    id: "file.gitChanges",
                    title: pane.showsOnlyGitChanges ? "Show All Files" : "Show Git Changes Only",
                    subtitle: "Filter the current folder to uncommitted files",
                    category: .file,
                    iconName: "arrow.triangle.branch",
                    iconColor: .orange,
                    shortcut: "⌥⌘G",
                    action: { pane.showsOnlyGitChanges.toggle() }
                ))
            }

            if !pane.selectedItems.isEmpty {
                let selectedURLs = pane.selectedItemURLs
                items.append(CommandPaletteItem(
                    id: "file.copyPath",
                    title: "Copy Absolute Path",
                    subtitle: "Copy selected paths to the clipboard",
                    category: .file,
                    iconName: "link",
                    iconColor: .cyan,
                    shortcut: "⌥⌘C",
                    action: { PathClipboard.copy(selectedURLs, style: .absolute) }
                ))

                items.append(CommandPaletteItem(
                    id: "file.copyHomePath",
                    title: "Copy Path from Home",
                    subtitle: "Copy ~/ paths to the clipboard",
                    category: .file,
                    iconName: "house",
                    iconColor: .cyan,
                    shortcut: nil,
                    action: { PathClipboard.copy(selectedURLs, style: .homeRelative) }
                ))

                items.append(CommandPaletteItem(
                    id: "file.copyFileURL",
                    title: "Copy File URL",
                    subtitle: "Copy file:// URLs to the clipboard",
                    category: .file,
                    iconName: "link",
                    iconColor: .cyan,
                    shortcut: nil,
                    action: { PathClipboard.copy(selectedURLs, style: .fileURL) }
                ))

                items.append(CommandPaletteItem(
                    id: "file.copyName",
                    title: "Copy File Name",
                    subtitle: "Copy selected names to the clipboard",
                    category: .file,
                    iconName: "textformat",
                    iconColor: .cyan,
                    shortcut: nil,
                    action: { PathClipboard.copy(selectedURLs, style: .name) }
                ))

                items.append(CommandPaletteItem(
                    id: "file.showInFinder",
                    title: "Show in Finder",
                    subtitle: "Reveal item in native Finder",
                    category: .file,
                    iconName: "macwindow",
                    iconColor: .blue,
                    shortcut: nil,
                    action: {
                        let urls = pane.selectedItems.compactMap { id in
                            pane.visibleItems.first(where: { $0.id == id })?.url
                        }
                        if !urls.isEmpty {
                            NSWorkspace.shared.activateFileViewerSelecting(urls)
                        }
                    }
                ))
            }
        }

        // MARK: Stash Shelf
        items.append(CommandPaletteItem(
            id: "stash.toggle",
            title: "Toggle Stash Shelf",
            subtitle: StashShelfStore.shared.isPresented ? "Hide floating stash shelf" : "Show floating stash shelf",
            category: .file,
            iconName: "tray.2.fill",
            iconColor: .indigo,
            shortcut: "⌘B",
            action: { StashShelfStore.shared.togglePresented() }
        ))

        if let pane = layoutManager.focusedPane, !pane.selectedItems.isEmpty {
            items.append(CommandPaletteItem(
                id: "stash.addSelected",
                title: "Add Selected Items to Stash",
                subtitle: "Stash \(pane.selectedItems.count) item(s) for cross-pane transfer",
                category: .file,
                iconName: "arrow.down.doc.fill",
                iconColor: .indigo,
                shortcut: "⌥S",
                action: {
                    let urls = pane.selectedItemURLs
                    StashShelfStore.shared.add(urls: urls)
                }
            ))
        }

        if !StashShelfStore.shared.items.isEmpty, let pane = layoutManager.focusedPane, let currentURL = pane.currentURL {
            items.append(CommandPaletteItem(
                id: "stash.dumpCopy",
                title: "Dump Stash to Active Pane (Copy)",
                subtitle: "Copy \(StashShelfStore.shared.count) stashed items into \(currentURL.lastPathComponent)",
                category: .file,
                iconName: "doc.on.doc.fill",
                iconColor: .blue,
                shortcut: "⌥V",
                action: {
                    StashShelfStore.shared.transferAll(into: currentURL, operation: .copy)
                }
            ))

            items.append(CommandPaletteItem(
                id: "stash.dumpMove",
                title: "Dump Stash to Active Pane (Move)",
                subtitle: "Move \(StashShelfStore.shared.count) stashed items into \(currentURL.lastPathComponent)",
                category: .file,
                iconName: "arrow.right.doc.on.clipboard",
                iconColor: .orange,
                shortcut: nil,
                action: {
                    StashShelfStore.shared.transferAll(into: currentURL, operation: .move)
                }
            ))

            items.append(CommandPaletteItem(
                id: "stash.clear",
                title: "Clear Stash Shelf",
                subtitle: "Remove all stashed items",
                category: .file,
                iconName: "trash",
                iconColor: .red,
                shortcut: nil,
                action: {
                    StashShelfStore.shared.clear()
                }
            ))
        }

        // MARK: Git Pulse
        if let pane = layoutManager.focusedPane,
           let currentURL = pane.currentURL,
           let gitStatus = GitPulseStore.shared.cachedStatus(for: currentURL) {
            items.append(CommandPaletteItem(
                id: "git.copyBranch",
                title: "Git: Copy Branch Name (\(gitStatus.branch))",
                subtitle: "Copy active Git branch to clipboard",
                category: .file,
                iconName: "arrow.triangle.branch",
                iconColor: .green,
                shortcut: nil,
                action: {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(gitStatus.branch, forType: .string)
                }
            ))

            let terminalName = TerminalService.shared.isITermAvailable ? "iTerm" : TerminalService.shared.applicationName
            items.append(CommandPaletteItem(
                id: "git.openTerminal",
                title: "Git: Open Repository in \(terminalName)",
                subtitle: "Launch \(terminalName) at \(gitStatus.repoRootURL.lastPathComponent)",
                category: .file,
                iconName: "terminal",
                iconColor: .green,
                shortcut: nil,
                action: {
                    try? TerminalService.shared.openInITermPreferred(gitStatus.repoRootURL)
                }
            ))

            items.append(CommandPaletteItem(
                id: "git.refresh",
                title: "Git: Refresh Pulse Status",
                subtitle: "Re-query git status for active repository",
                category: .file,
                iconName: "arrow.clockwise",
                iconColor: .green,
                shortcut: nil,
                action: {
                    GitPulseStore.shared.refresh(for: gitStatus.repoRootURL, force: true)
                }
            ))
        }

        // MARK: AI Tools
        if let pane = layoutManager.focusedPane, pane.isAIAssistantAvailable {
            items.append(CommandPaletteItem(
                id: "ai.ask",
                title: "Ask AI About Current Folder…",
                subtitle: "Semantic query on current directory",
                category: .ai,
                iconName: "sparkles",
                iconColor: .purple,
                shortcut: "⌥⌘A",
                action: { pane.toggleAIAssistant() }
            ))

            items.append(CommandPaletteItem(
                id: "ai.organize",
                title: "Organize Current Folder with AI…",
                subtitle: "Smart grouping and file categorization",
                category: .ai,
                iconName: "wand.and.stars",
                iconColor: .purple,
                shortcut: nil,
                action: { pane.presentAIOrganize() }
            ))
        }

        return items
    }
}
