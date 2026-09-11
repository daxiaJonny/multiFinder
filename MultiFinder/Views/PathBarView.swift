import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct PathBarView: View {
    @ObservedObject var viewModel: FileBrowserViewModel
    let location: BrowserLocation
    let isFocused: Bool
    @FocusState.Binding var isFilterFocused: Bool
    let onFocus: () -> Void
    let onNavigate: (URL) -> Void
    let onNavigateToFile: (URL) -> Void
    let onRefresh: () -> Void
    let canRemovePane: Bool
    let onRemovePane: () -> Void
    let onTransferDroppedItems: ([URL], URL, FileDropOperation) -> Void

    @State private var isEditing = false
    @State private var pathText = ""
    @State private var dropTargetURL: URL?
    @FocusState private var isPathFieldFocused: Bool
    @ObservedObject private var gitPulseStore = GitPulseStore.shared

    private var pathComponents: [(name: String, url: URL)] {
        guard case .directory(let url) = location else { return [] }
        var components: [(String, URL)] = []
        var current = url.standardizedFileURL
        while current.path != "/" {
            components.insert((current.lastPathComponent, current), at: 0)
            current = current.deletingLastPathComponent()
        }
        components.insert(("/", URL(fileURLWithPath: "/")), at: 0)
        return components
    }

    var body: some View {
        Group {
            if isEditing {
                editField
            } else if isFilterFocused || viewModel.isFiltering {
                filterHeader
            } else if case .directory = location {
                breadcrumbHeader
            } else {
                specialLocationHeader
            }
        }
        .frame(height: 36)
        .background(
            ZStack {
                if isFocused {
                    MFDTheme.paneHeaderBackground
                    LinearGradient(
                        colors: [MFDTheme.primaryAccent.opacity(0.12), Color.clear],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                } else {
                    MFDTheme.paneHeaderBackground.opacity(0.60)
                }
            }
        )
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(isFocused ? MFDTheme.primaryAccent.opacity(0.25) : MFDTheme.subtleHairline)
                .frame(height: 0.5)
        }
    }

    // MARK: - Breadcrumb Header

    private var breadcrumbHeader: some View {
        HStack(spacing: 6) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 3) {
                    ForEach(Array(pathComponents.enumerated()), id: \.offset) { index, component in
                        let isLast = index == pathComponents.count - 1
                        Button(action: {
                            onFocus()
                            onNavigate(component.url)
                        }) {
                            if isLast {
                                HStack(spacing: 5) {
                                    Image(systemName: "folder.fill")
                                        .font(.system(size: 11))
                                        .foregroundStyle(MFDTheme.primaryAccent)
                                    Text(component.name)
                                        .font(.system(size: 12, weight: .semibold))
                                        .lineLimit(1)
                                }
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(
                                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                                        .fill(isFocused ? MFDTheme.primaryAccent.opacity(0.18) : Color.primary.opacity(0.06))
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                                .stroke(isFocused ? MFDTheme.primaryAccent.opacity(0.35) : Color.clear, lineWidth: 1)
                                        )
                                )
                                .foregroundStyle(isFocused ? MFDTheme.primaryAccent : .primary)
                            } else {
                                HStack(spacing: 3) {
                                    if index == 0 {
                                        Image(systemName: "laptopcomputer")
                                            .font(.system(size: 10))
                                            .foregroundStyle(.secondary)
                                    }
                                    Text(component.name)
                                        .font(.system(size: 11, weight: .regular))
                                        .lineLimit(1)
                                }
                                .padding(.horizontal, 6)
                                .padding(.vertical, 3)
                                .background(
                                    RoundedRectangle(cornerRadius: 4)
                                        .fill(breadcrumbBackground(for: component.url, at: index))
                                )
                                .foregroundStyle(.secondary)
                            }
                        }
                        .buttonStyle(.plain)
                        .onDrop(
                            of: [UTType.fileURL],
                            delegate: BreadcrumbDropDelegate(
                                destination: component.url,
                                targetedURL: $dropTargetURL,
                                onTransferDroppedItems: onTransferDroppedItems
                            )
                        )

                        if index < pathComponents.count - 1 {
                            Image(systemName: "chevron.right")
                                .font(.system(size: 7, weight: .bold))
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
                .padding(.horizontal, 4)
            }

            Spacer(minLength: 6)

            if let currentURL = viewModel.currentURL,
               let gitStatus = gitPulseStore.status(for: currentURL) {
                GitPulseBadgeView(status: gitStatus, onFocus: onFocus)
            }

            filterToggleButton

            viewModePicker

            Rectangle()
                .fill(MFDTheme.subtleHairline)
                .frame(width: 1, height: 14)

            controls(canEdit: true)
        }
        .padding(.horizontal, 8)
        .onTapGesture(count: 2, perform: startEditing)
    }

    // MARK: - Filter Header

    private var filterHeader: some View {
        HStack(spacing: 6) {
            if let currentFolder = pathComponents.last {
                HStack(spacing: 4) {
                    Image(systemName: "folder.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(MFDTheme.primaryAccent)
                    Text(currentFolder.name)
                        .font(.system(size: 11, weight: .semibold))
                        .lineLimit(1)
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(
                    RoundedRectangle(cornerRadius: 5)
                        .fill(MFDTheme.breadcrumbPillBackground)
                )
            } else if case .recents = location {
                HStack(spacing: 4) {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.system(size: 10))
                        .foregroundStyle(MFDTheme.primaryAccent)
                    Text(location.title)
                        .font(.system(size: 11, weight: .semibold))
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(
                    RoundedRectangle(cornerRadius: 5)
                        .fill(MFDTheme.breadcrumbPillBackground)
                )
            }

            HStack(spacing: 4) {
                Image(systemName: "line.3.horizontal.decrease")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)

                TextField("Filter by file name", text: $viewModel.filterText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11))
                    .focused($isFilterFocused)
                    .onSubmit {
                        isFilterFocused = false
                    }
                    .onKeyPress(.escape) {
                        viewModel.clearFilter()
                        isFilterFocused = false
                        return .handled
                    }

                if viewModel.isFiltering {
                    Button {
                        viewModel.clearFilter()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Clear Filter")
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(Color(nsColor: .controlBackgroundColor))
                    .overlay(
                        RoundedRectangle(cornerRadius: 5)
                            .stroke(MFDTheme.primaryAccent.opacity(0.5), lineWidth: 1)
                    )
            )

            Spacer(minLength: 4)

            viewModePicker

            controls(canEdit: false)
        }
        .padding(.horizontal, 6)
    }

    // MARK: - Special Location Header

    private var specialLocationHeader: some View {
        HStack(spacing: 6) {
            Image(systemName: specialLocationIcon)
                .foregroundStyle(MFDTheme.primaryAccent)
                .font(.system(size: 11))
            Text(location.title)
                .font(.system(size: 11, weight: .medium))
                .lineLimit(1)
                .foregroundStyle(isFocused ? .primary : .secondary)

            Spacer(minLength: 4)

            filterToggleButton

            viewModePicker

            controls(canEdit: false)
        }
        .padding(.horizontal, 8)
    }

    // MARK: - Subcomponents

    private var filterToggleButton: some View {
        Button {
            onFocus()
            isFilterFocused = true
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 10, weight: .semibold))
                if viewModel.isFiltering {
                    Text(viewModel.filterText)
                        .font(.system(size: 10, weight: .semibold))
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(viewModel.isFiltering ? MFDTheme.primaryAccent.opacity(0.18) : MFDTheme.breadcrumbPillBackground)
                    .overlay(
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .stroke(viewModel.isFiltering ? MFDTheme.primaryAccent.opacity(0.5) : Color.primary.opacity(0.06), lineWidth: 0.8)
                    )
            )
            .foregroundStyle(viewModel.isFiltering ? MFDTheme.primaryAccent : .secondary)
        }
        .buttonStyle(.plain)
        .help("Filter files (/)")
    }

    private var viewModePicker: some View {
        Picker("View", selection: $viewModel.viewMode) {
            ForEach(BrowserViewMode.allCases, id: \.self) { mode in
                Image(systemName: mode.systemImage)
                    .accessibilityLabel(mode.localizedName)
                    .tag(mode)
            }
        }
        .pickerStyle(.segmented)
        .controlSize(.small)
        .labelsHidden()
        .fixedSize()
        .help("View Mode")
    }

    private func controls(canEdit: Bool) -> some View {
        HStack(spacing: 2) {
            Button(action: onRefresh) {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 10))
                    .frame(width: 20, height: 20)
            }
            .buttonStyle(.plain)
            .help("Refresh")

            if canEdit {
                Button(action: startEditing) {
                    Image(systemName: "pencil")
                        .font(.system(size: 10))
                        .frame(width: 20, height: 20)
                }
                .buttonStyle(.plain)
                .help("Edit Path")
            }

            if canRemovePane {
                Button(action: onRemovePane) {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                        .frame(width: 20, height: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Remove Pane")
                .help("Remove Pane")
            }
        }
        .foregroundStyle(.secondary)
    }

    private var editField: some View {
        HStack(spacing: 6) {
            Image(systemName: "folder")
                .font(.system(size: 11))
                .foregroundStyle(MFDTheme.primaryAccent)

            TextField("Path", text: $pathText)
                .textFieldStyle(.plain)
                .font(.system(size: 11, design: .monospaced))
                .focused($isPathFieldFocused)
                .onSubmit(commitPath)
                .onKeyPress("a", phases: .down) { keyPress in
                    guard keyPress.modifiers == .control,
                          TextEditingCommandRouter.perform(#selector(NSText.selectAll(_:))) else {
                        return .ignored
                    }
                    return .handled
                }

            Button(action: commitPath) {
                Image(systemName: "arrow.right.circle.fill")
                    .foregroundStyle(MFDTheme.primaryAccent)
            }
            .buttonStyle(.plain)
            .help("Open Path")

            Button(action: { isEditing = false }) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Cancel Editing")
        }
        .padding(.horizontal, 8)
        .onExitCommand { isEditing = false }
    }

    private var specialLocationIcon: String {
        switch location {
        case .recents: return "clock.arrow.circlepath"
        case .search: return "magnifyingglass"
        case .aiSearch: return "sparkles"
        case .directory: return "folder"
        }
    }

    private func breadcrumbBackground(for url: URL, at index: Int) -> Color {
        if dropTargetURL == url {
            return MFDTheme.primaryAccent.opacity(0.3)
        }
        let isLast = index == pathComponents.count - 1
        return isLast ? MFDTheme.primaryAccent.opacity(0.12) : Color.clear
    }

    private func startEditing() {
        guard let url = location.directoryURL else { return }
        pathText = url.path
        isEditing = true
        isPathFieldFocused = true
    }

    private func commitPath() {
        defer { isEditing = false }
        let trimmed = pathText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let expandedPath = (trimmed as NSString).expandingTildeInPath
        let targetURL = URL(fileURLWithPath: expandedPath)
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: expandedPath, isDirectory: &isDirectory) {
            isDirectory.boolValue ? onNavigate(targetURL) : onNavigateToFile(targetURL)
        } else {
            onNavigateToFile(targetURL)
        }
    }
}

private struct BreadcrumbDropDelegate: DropDelegate {
    let destination: URL
    @Binding var targetedURL: URL?
    let onTransferDroppedItems: ([URL], URL, FileDropOperation) -> Void

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [.fileURL])
    }

    func dropEntered(info: DropInfo) {
        guard validateDrop(info: info) else { return }
        targetedURL = destination
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        guard validateDrop(info: info) else {
            return DropProposal(operation: .forbidden)
        }
        return DropProposal(operation: currentOperation == .copy ? .copy : .move)
    }

    func dropExited(info: DropInfo) {
        if targetedURL == destination {
            targetedURL = nil
        }
    }

    func performDrop(info: DropInfo) -> Bool {
        let providers = info.itemProviders(for: [.fileURL])
        guard !providers.isEmpty else { return false }
        let operation = currentOperation
        targetedURL = nil

        DroppedFileURLLoader.load(providers) { urls in
            onTransferDroppedItems(urls, destination, operation)
        }
        return true
    }

    private var currentOperation: FileDropOperation {
        FileDropModifierKeys.currentOperation
    }
}
