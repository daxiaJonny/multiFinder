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
    @State private var headerWidth: CGFloat = 400

    private var pathComponents: [(name: String, url: URL)] {
        guard case .directory(let url) = location else { return [] }
        let standardized = url.standardizedFileURL
        let homeURL = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL

        var components: [(String, URL)] = []
        var current = standardized

        if current.path == homeURL.path {
            return [("~", homeURL)]
        } else if current.path.hasPrefix(homeURL.path + "/") {
            while current.path != homeURL.path && current.path != "/" {
                components.insert((current.lastPathComponent, current), at: 0)
                current = current.deletingLastPathComponent()
            }
            components.insert(("~", homeURL), at: 0)
            return components
        } else {
            while current.path != "/" {
                components.insert((current.lastPathComponent, current), at: 0)
                current = current.deletingLastPathComponent()
            }
            components.insert(("/", URL(fileURLWithPath: "/")), at: 0)
            return components
        }
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
            GeometryReader { geo in
                Color.clear
                    .onAppear { headerWidth = geo.size.width }
                    .onChange(of: geo.size.width) { newWidth in headerWidth = newWidth }
            }
        )
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
        HStack(spacing: 3) {
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    breadcrumbItemsView
                }
                .onAppear {
                    if viewModel.currentURL != nil && !pathComponents.isEmpty {
                        proxy.scrollTo(pathComponents.count - 1, anchor: .trailing)
                    }
                }
                .onChange(of: pathComponents.count) { count in
                    if count > 0 {
                        proxy.scrollTo(count - 1, anchor: .trailing)
                    }
                }
            }
            .frame(minWidth: 30, maxWidth: .infinity, alignment: .leading)

            if let currentURL = viewModel.currentURL,
               let gitStatus = gitPulseStore.status(for: currentURL) {
                GitPulseBadgeView(status: gitStatus, isCompact: headerWidth < 340, onFocus: onFocus)
                    .fixedSize()
            }

            Spacer(minLength: 2)

            filterToggleButton

            adaptiveViewModePicker

            Rectangle()
                .fill(MFDTheme.subtleHairline)
                .frame(width: 1, height: 12)

            controls(canEdit: true)
        }
        .padding(.horizontal, 6)
        .onTapGesture(count: 2, perform: startEditing)
    }

    private var breadcrumbItemsView: some View {
        HStack(spacing: 2) {
            if headerWidth < 260 || pathComponents.count <= 1 {
                // Ultra-narrow mode: show current folder
                if let lastComponent = pathComponents.last {
                    breadcrumbComponentView(component: lastComponent, index: pathComponents.count - 1, isLast: true)
                }
            } else if headerWidth < 360 {
                // Narrow mode: show ~ > … > current (or ~ > current)
                if pathComponents.count == 2 {
                    breadcrumbComponentView(component: pathComponents[0], index: 0, isLast: false)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 6, weight: .bold))
                        .foregroundStyle(.tertiary)
                    breadcrumbComponentView(component: pathComponents[1], index: 1, isLast: true)
                } else if pathComponents.count > 2 {
                    if let root = pathComponents.first {
                        breadcrumbComponentView(component: root, index: 0, isLast: false)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 6, weight: .bold))
                            .foregroundStyle(.tertiary)
                    }

                    let omitted = Array(pathComponents[1 ..< (pathComponents.count - 1)])
                    omittedFoldersMenu(omitted: omitted)

                    Image(systemName: "chevron.right")
                        .font(.system(size: 6, weight: .bold))
                        .foregroundStyle(.tertiary)

                    if let last = pathComponents.last {
                        breadcrumbComponentView(component: last, index: pathComponents.count - 1, isLast: true)
                    }
                }
            } else {
                // Regular mode (headerWidth >= 360)
                if pathComponents.count <= 3 {
                    ForEach(Array(pathComponents.enumerated()), id: \.offset) { index, component in
                        let isLast = index == pathComponents.count - 1
                        breadcrumbComponentView(component: component, index: index, isLast: isLast)

                        if !isLast {
                            Image(systemName: "chevron.right")
                                .font(.system(size: 6, weight: .bold))
                                .foregroundStyle(.tertiary)
                        }
                    }
                } else {
                    // Root component (e.g. ~ or /)
                    if let root = pathComponents.first {
                        breadcrumbComponentView(component: root, index: 0, isLast: false)

                        Image(systemName: "chevron.right")
                            .font(.system(size: 6, weight: .bold))
                            .foregroundStyle(.tertiary)
                    }

                    // Omitted intermediate folders menu
                    let omitted = Array(pathComponents[1 ..< (pathComponents.count - 2)])
                    if !omitted.isEmpty {
                        omittedFoldersMenu(omitted: omitted)

                        Image(systemName: "chevron.right")
                            .font(.system(size: 6, weight: .bold))
                            .foregroundStyle(.tertiary)
                    }

                    // Parent component
                    let parentIndex = pathComponents.count - 2
                    let parentComponent = pathComponents[parentIndex]
                    breadcrumbComponentView(component: parentComponent, index: parentIndex, isLast: false)

                    Image(systemName: "chevron.right")
                        .font(.system(size: 6, weight: .bold))
                        .foregroundStyle(.tertiary)

                    // Current folder component
                    let lastIndex = pathComponents.count - 1
                    let lastComponent = pathComponents[lastIndex]
                    breadcrumbComponentView(component: lastComponent, index: lastIndex, isLast: true)
                }
            }
        }
        .padding(.horizontal, 2)
    }

    private func omittedFoldersMenu(omitted: [(name: String, url: URL)]) -> some View {
        Menu {
            ForEach(omitted.reversed(), id: \.url) { item in
                Button {
                    onFocus()
                    onNavigate(item.url)
                } label: {
                    Label(item.name, systemImage: "folder")
                }
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 4)
                .padding(.vertical, 3)
                .background(
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.primary.opacity(0.05))
                )
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help(L10n.string("Parent Folders"))
    }

    @ViewBuilder
    private func breadcrumbComponentView(component: (name: String, url: URL), index: Int, isLast: Bool) -> some View {
        Button(action: {
            onFocus()
            onNavigate(component.url)
        }) {
            if isLast {
                HStack(spacing: 4) {
                    Image(systemName: "folder.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(MFDTheme.primaryAccent)
                    Text(component.name)
                        .font(.system(size: 11, weight: .semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: headerWidth < 300 ? 80 : 130)
                }
                .fixedSize(horizontal: true, vertical: false)
                .padding(.horizontal, 7)
                .padding(.vertical, 3.5)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(isFocused ? MFDTheme.primaryAccent.opacity(0.18) : Color.primary.opacity(0.06))
                        .overlay(
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .stroke(isFocused ? MFDTheme.primaryAccent.opacity(0.35) : Color.clear, lineWidth: 1)
                        )
                )
                .foregroundStyle(isFocused ? MFDTheme.primaryAccent : .primary)
            } else if index == 0 {
                HStack(spacing: 2) {
                    if component.name == "~" {
                        Image(systemName: "house.fill")
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                    } else {
                        Image(systemName: "laptopcomputer")
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                    }
                    Text(component.name)
                        .font(.system(size: 11, weight: .medium))
                }
                .fixedSize(horizontal: true, vertical: false)
                .padding(.horizontal, 5)
                .padding(.vertical, 3)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(breadcrumbBackground(for: component.url, at: index))
                )
                .foregroundStyle(.secondary)
            } else {
                Text(component.name)
                    .font(.system(size: 11, weight: .regular))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: headerWidth < 340 ? 60 : 90)
                    .fixedSize(horizontal: true, vertical: false)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 3)
                    .background(
                        RoundedRectangle(cornerRadius: 4)
                            .fill(breadcrumbBackground(for: component.url, at: index))
                    )
                    .foregroundStyle(.secondary)
            }
        }
        .id(index)
        .buttonStyle(.plain)
        .onDrop(
            of: [UTType.fileURL],
            delegate: BreadcrumbDropDelegate(
                destination: component.url,
                targetedURL: $dropTargetURL,
                onTransferDroppedItems: onTransferDroppedItems
            )
        )
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
                        // Keep filter active
                    }

                if !viewModel.filterText.isEmpty {
                    Button {
                        viewModel.filterText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(Color(NSColor.controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 5)
                    .stroke(MFDTheme.primaryAccent.opacity(0.35), lineWidth: 1)
            )

            Spacer(minLength: 4)

            Button("Done") {
                isFilterFocused = false
            }
            .buttonStyle(.plain)
            .font(.system(size: 11))
            .foregroundStyle(MFDTheme.primaryAccent)

            adaptiveViewModePicker

            Rectangle()
                .fill(MFDTheme.subtleHairline)
                .frame(width: 1, height: 12)

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

            adaptiveViewModePicker

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

    @ViewBuilder
    private var adaptiveViewModePicker: some View {
        if headerWidth < 380 {
            Menu {
                ForEach(BrowserViewMode.allCases, id: \.self) { mode in
                    Button {
                        viewModel.viewMode = mode
                    } label: {
                        Label(mode.localizedName, systemImage: mode.systemImage)
                    }
                }
            } label: {
                Image(systemName: viewModel.viewMode.systemImage)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 22, height: 22)
                    .background(
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color.primary.opacity(0.04))
                    )
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help(L10n.string("View Mode"))
        } else {
            viewModePicker
        }
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

            if canEdit && headerWidth >= 320 {
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
