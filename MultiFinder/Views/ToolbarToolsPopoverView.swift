import AppKit
import SwiftUI

struct ToolbarToolsPopoverView: View {
    @ObservedObject var layoutManager: LayoutManager
    @ObservedObject var pane: FileBrowserViewModel
    @ObservedObject var appSettings: AppSettings
    @ObservedObject var stashStore: StashShelfStore
    @ObservedObject var clipboard: FileClipboard
    @ObservedObject var operationService: FileOperationService
    @ObservedObject var favoritesStore: FavoritesStore
    @ObservedObject var templateStore: WorkspaceTemplateStore
    let terminalService: TerminalService
    let activeTemplateID: WorkspaceTemplate.ID?
    let onSaveTemplate: () -> Void
    let onSaveTemplateAs: () -> Void
    let onApplyTemplate: (WorkspaceTemplate) -> Void
    let onDeleteTemplate: (WorkspaceTemplate) -> Void
    let onDismiss: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            // Header
            headerView

            Divider()
                .opacity(0.6)

            // Content List
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(ToolbarToolCategory.allCases) { category in
                        categorySection(category)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
            }
            .frame(maxHeight: 460)

            Divider()
                .opacity(0.6)

            // Footer
            footerView
        }
        .frame(width: 320)
        .background(.ultraThinMaterial)
    }

    // MARK: - Header

    private var headerView: some View {
        HStack(alignment: .center, spacing: 8) {
            Image(systemName: "puzzlepiece.extension.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(MFDTheme.primaryAccent)

            VStack(alignment: .leading, spacing: 1) {
                Text("工具与扩展")
                    .font(.system(size: 13, weight: .bold))
                Text("点击直接使用，或固定到工具栏")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Close")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    // MARK: - Category Section

    private func categorySection(_ category: ToolbarToolCategory) -> some View {
        let tools = ToolbarToolID.allCases.filter { $0.category == category }

        return VStack(alignment: .leading, spacing: 6) {
            Text(category.localizedTitle)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.leading, 2)

            VStack(spacing: 2) {
                ForEach(tools) { tool in
                    toolRow(tool)
                }
            }
            .padding(4)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.primary.opacity(0.03))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(MFDTheme.subtleHairline, lineWidth: 0.5)
                    )
            )
        }
    }

    // MARK: - Tool Row

    @ViewBuilder
    private func toolRow(_ tool: ToolbarToolID) -> some View {
        let isPinned = appSettings.isToolPinned(tool)

        HStack(spacing: 8) {
            // Main Action Button / Menu
            Group {
                switch tool {
                case .operationHistory:
                    historyMenuLabel
                case .workspaceTemplates:
                    templatesMenuLabel
                case .arrangePanes:
                    arrangePanesMenuLabel
                default:
                    directActionButton(tool)
                }
            }

            Spacer(minLength: 4)

            // Shortcut badge if any
            if let shortcut = tool.shortcut {
                Text(shortcut)
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .padding(.horizontal, 4)
                    .padding(.vertical, 2)
                    .background(
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color.primary.opacity(0.06))
                    )
                    .foregroundStyle(.secondary)
            }

            // Pin / Unpin Button
            Button {
                withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
                    appSettings.toggleToolPinned(tool)
                }
            } label: {
                Image(systemName: isPinned ? "pin.fill" : "pin")
                    .font(.system(size: 11, weight: isPinned ? .bold : .regular))
                    .foregroundStyle(isPinned ? MFDTheme.primaryAccent : .secondary.opacity(0.7))
                    .frame(width: 24, height: 24)
                    .background(
                        RoundedRectangle(cornerRadius: 5)
                            .fill(isPinned ? MFDTheme.primaryAccent.opacity(0.12) : Color.clear)
                    )
            }
            .buttonStyle(.plain)
            .help(isPinned ? "从工具栏取消固定" : "固定到工具栏")
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.clear)
        )
    }

    // MARK: - Direct Action Button

    private func directActionButton(_ tool: ToolbarToolID) -> some View {
        Button {
            executeDirectAction(tool)
        } label: {
            HStack(spacing: 8) {
                toolIcon(tool)

                VStack(alignment: .leading, spacing: 1) {
                    Text(tool.title)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(isToolEnabled(tool) ? .primary : .secondary)
                        .lineLimit(1)
                    Text(tool.subtitle)
                        .font(.system(size: 9.5))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isToolEnabled(tool))
    }

    // MARK: - Menu Labels for Popover

    private var historyMenuLabel: some View {
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
            HStack(spacing: 8) {
                toolIcon(.operationHistory)

                VStack(alignment: .leading, spacing: 1) {
                    Text(ToolbarToolID.operationHistory.title)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(ToolbarToolID.operationHistory.subtitle)
                        .font(.system(size: 9.5))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
            .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
    }

    private var templatesMenuLabel: some View {
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
            HStack(spacing: 8) {
                toolIcon(.workspaceTemplates)

                VStack(alignment: .leading, spacing: 1) {
                    Text(ToolbarToolID.workspaceTemplates.title)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(ToolbarToolID.workspaceTemplates.subtitle)
                        .font(.system(size: 9.5))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
            .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
    }

    private var arrangePanesMenuLabel: some View {
        Menu {
            Button {
                guard let id = layoutManager.focusedPaneID else { return }
                layoutManager.newTab(in: id)
            } label: {
                Label("New Tab", systemImage: "plus.rectangle.on.rectangle")
            }

            Divider()

            Button {
                guard let id = layoutManager.focusedPaneID else { return }
                layoutManager.addPaneRight(of: id)
            } label: {
                Label("Split Right", systemImage: "rectangle.righthalf.inset.filled")
            }

            Button {
                guard let id = layoutManager.focusedPaneID else { return }
                layoutManager.addPaneLeft(of: id)
            } label: {
                Label("Split Left", systemImage: "rectangle.lefthalf.inset.filled")
            }

            Divider()

            Button {
                guard let id = layoutManager.focusedPaneID else { return }
                layoutManager.addRowBelow(of: id)
            } label: {
                Label("Add Row Below", systemImage: "rectangle.bottomhalf.inset.filled")
            }

            Button {
                guard let id = layoutManager.focusedPaneID else { return }
                layoutManager.addRowAbove(of: id)
            } label: {
                Label("Add Row Above", systemImage: "rectangle.tophalf.inset.filled")
            }

            Divider()

            Button(role: .destructive) {
                guard let id = layoutManager.focusedPaneID else { return }
                layoutManager.removePane(id)
            } label: {
                Label("Remove Pane", systemImage: "rectangle.badge.minus")
            }
            .disabled(layoutManager.totalPaneCount <= 1)
        } label: {
            HStack(spacing: 8) {
                toolIcon(.arrangePanes)

                VStack(alignment: .leading, spacing: 1) {
                    Text(ToolbarToolID.arrangePanes.title)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(ToolbarToolID.arrangePanes.subtitle)
                        .font(.system(size: 9.5))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
            .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
    }

    // MARK: - Tool Icon

    private func toolIcon(_ tool: ToolbarToolID) -> some View {
        let isEnabled = isToolEnabled(tool)
        let iconName: String = {
            if tool == .favorite && isCurrentFolderFavorite {
                return "star.fill"
            }
            if tool == .hiddenFiles && pane.showHiddenFiles {
                return "eye.slash"
            }
            return tool.systemImage
        }()

        return ZStack {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(MFDTheme.primaryAccent.opacity(isEnabled ? 0.12 : 0.04))
                .frame(width: 26, height: 26)

            Image(systemName: iconName)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(isEnabled ? MFDTheme.primaryAccent : .secondary)
        }
    }

    // MARK: - Footer

    private var footerView: some View {
        HStack {
            Button {
                withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
                    appSettings.resetPinnedToolsToDefault()
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.system(size: 10))
                    Text("恢复默认固定")
                        .font(.system(size: 11))
                }
                .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)

            Spacer()

            Text("\(appSettings.pinnedToolbarToolIDs.count) 个已固定")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Color.primary.opacity(0.02))
    }

    // MARK: - Execution & State Helpers

    private func isToolEnabled(_ tool: ToolbarToolID) -> Bool {
        switch tool {
        case .commandPalette, .stashShelf, .arrangePanes, .workspaceTemplates, .operationHistory:
            return true
        case .favorite, .search:
            return pane.currentURL != nil
        case .aiAssistant, .aiOrganize:
            return pane.currentURL != nil && pane.isAIAssistantAvailable
        case .newFolder:
            return pane.canCreateItems
        case .hiddenFiles:
            return true
        case .terminal:
            return pane.currentURL != nil && terminalService.isAvailable
        case .paste:
            return clipboard.hasContent && pane.canCreateItems
        }
    }

    private func executeDirectAction(_ tool: ToolbarToolID) {
        switch tool {
        case .commandPalette:
            onDismiss()
            layoutManager.toggleCommandPalette()
        case .stashShelf:
            onDismiss()
            stashStore.togglePresented()
        case .aiAssistant:
            onDismiss()
            pane.toggleAIAssistant()
        case .aiOrganize:
            onDismiss()
            pane.presentAIOrganize()
        case .newFolder:
            onDismiss()
            pane.newFolder()
        case .hiddenFiles:
            pane.toggleHiddenFiles()
        case .terminal:
            onDismiss()
            openInTerminal()
        case .paste:
            onDismiss()
            paste()
        case .search:
            onDismiss()
            pane.presentSearch()
        case .favorite:
            toggleFavorite()
        default:
            break
        }
    }

    private var isCurrentFolderFavorite: Bool {
        guard let url = pane.currentURL else { return false }
        return favoritesStore.contains(url)
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

    private var saveTemplateTitle: String {
        guard let activeTemplateID,
              let template = templateStore.templates.first(where: { $0.id == activeTemplateID }) else {
            return L10n.string("Save…")
        }
        return L10n.format("Save to “%@”", template.name)
    }
}
