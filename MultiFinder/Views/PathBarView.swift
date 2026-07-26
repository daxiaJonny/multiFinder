import SwiftUI

struct PathBarView: View {
    let location: BrowserLocation
    let isFocused: Bool
    let onNavigate: (URL) -> Void
    let onNavigateToFile: (URL) -> Void
    let onRefresh: () -> Void

    @State private var isEditing = false
    @State private var pathText = ""

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
            } else if case .directory = location {
                breadcrumb
            } else {
                specialLocationHeader
            }
        }
        .background(
            isFocused
                ? Color(nsColor: .underPageBackgroundColor)
                : Color(nsColor: .windowBackgroundColor)
        )
    }

    private var breadcrumb: some View {
        HStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 1) {
                    ForEach(Array(pathComponents.enumerated()), id: \.offset) { index, component in
                        Button(action: { onNavigate(component.url) }) {
                            HStack(spacing: 3) {
                                if index == 0 {
                                    Image(systemName: "macwindow")
                                        .font(.system(size: 10))
                                }
                                Text(component.name)
                                    .font(.system(size: 12))
                                    .lineLimit(1)
                            }
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(
                                RoundedRectangle(cornerRadius: 4)
                                    .fill(index == pathComponents.count - 1 ? Color.accentColor.opacity(0.15) : .clear)
                            )
                            .foregroundStyle(index == pathComponents.count - 1 ? Color.accentColor : .secondary)
                        }
                        .buttonStyle(.plain)

                        if index < pathComponents.count - 1 {
                            Image(systemName: "chevron.right")
                                .font(.system(size: 8, weight: .semibold))
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
                .padding(.horizontal, 8)
            }

            controls(canEdit: true)
        }
        .padding(.vertical, 5)
        .onTapGesture(count: 2, perform: startEditing)
    }

    private var specialLocationHeader: some View {
        HStack(spacing: 6) {
            Image(systemName: specialLocationIcon)
                .foregroundStyle(.secondary)
            Text(location.title)
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)
            Spacer()
            controls(canEdit: false)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
    }

    private func controls(canEdit: Bool) -> some View {
        HStack(spacing: 8) {
            Button(action: onRefresh) {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 10))
            }
            .buttonStyle(.plain)
            .help("Refresh")

            if canEdit {
                Button(action: startEditing) {
                    Image(systemName: "pencil")
                        .font(.system(size: 10))
                }
                .buttonStyle(.plain)
                .help("Edit Path")
            }
        }
        .foregroundStyle(.secondary)
    }

    private var editField: some View {
        HStack(spacing: 6) {
            Image(systemName: "folder")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            TextField("Path", text: $pathText)
                .textFieldStyle(.plain)
                .font(.system(size: 12, design: .monospaced))
                .onSubmit(commitPath)
            Button(action: commitPath) {
                Image(systemName: "arrow.right.circle.fill")
            }
            .buttonStyle(.plain)
            Button(action: { isEditing = false }) {
                Image(systemName: "xmark.circle.fill")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
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

    private func startEditing() {
        guard let url = location.directoryURL else { return }
        pathText = url.path
        isEditing = true
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
