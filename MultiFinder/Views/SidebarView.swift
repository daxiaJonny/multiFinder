import AppKit
import SwiftUI

enum SidebarDestination: Hashable, Sendable {
    case recents
    case directory(URL)
}

struct SidebarItem: Identifiable, Hashable {
    let id: String
    let name: String
    let icon: String
    let iconPath: String?
    let url: URL?
    let isRecents: Bool

    init(
        name: String,
        icon: String,
        iconPath: String? = nil,
        url: URL? = nil,
        isRecents: Bool = false,
        id: String? = nil
    ) {
        self.name = name
        self.icon = icon
        self.iconPath = iconPath
        self.url = url?.standardizedFileURL
        self.isRecents = isRecents
        self.id = id ?? (isRecents ? "recents" : url?.standardizedFileURL.absoluteString ?? name)
    }

    var destination: SidebarDestination {
        if isRecents {
            return .recents
        }
        return .directory(url ?? URL(fileURLWithPath: "/"))
    }
}

struct SidebarView: View {
    let currentLocation: BrowserLocation
    let onNavigate: (URL) -> Void
    let onRecents: () -> Void

    @ObservedObject private var favoritesStore: FavoritesStore
    @ObservedObject private var volumeStore: VolumeStore
    @ObservedObject private var preferences = SidebarPreferences.shared
    @State private var selectedDestination: SidebarDestination?
    @State private var editingTarget: SidebarAppearanceEditorTarget?

    init(
        currentLocation: BrowserLocation,
        onNavigate: @escaping (URL) -> Void,
        onRecents: @escaping () -> Void,
        favoritesStore: FavoritesStore = .shared,
        volumeStore: VolumeStore = .shared
    ) {
        self.currentLocation = currentLocation
        self.onNavigate = onNavigate
        self.onRecents = onRecents
        _favoritesStore = ObservedObject(wrappedValue: favoritesStore)
        _volumeStore = ObservedObject(wrappedValue: volumeStore)
        _selectedDestination = State(initialValue: Self.destination(for: currentLocation))
    }

    var body: some View {
        GeometryReader { geometry in
            List(selection: $selectedDestination) {
                if !favoritesStore.favorites.isEmpty {
                    Section(header: sectionHeader(L10n.string("Favorites"))) {
                        ForEach(favoritesStore.favorites) { favorite in
                            favoriteRow(favorite)
                        }
                    }
                }

                Section(header: sectionHeader(L10n.string("Personal Favorites"))) {
                    sidebarRow(
                        SidebarItem(
                            name: L10n.string("Recents"),
                            icon: "clock.arrow.circlepath",
                            isRecents: true
                        )
                    )

                    ForEach(standardPlaces) { item in
                        sidebarRow(item)
                    }
                }

                if let iCloudDriveURL {
                    Section(header: sectionHeader(L10n.string("iCloud Drive"))) {
                        sidebarRow(
                            SidebarItem(
                                name: L10n.string("iCloud Drive"),
                                icon: "icloud.fill",
                                url: iCloudDriveURL,
                                id: "icloud-drive"
                            )
                        )
                    }
                }

                Section(header: sectionHeader(L10n.string("Locations"))) {
                    ForEach(volumeStore.volumes) { volume in
                        volumeRow(volume, showCapacity: geometry.size.width >= 220)
                    }

                    if let errorMessage = volumeStore.errorMessage {
                        volumeErrorRow(errorMessage)
                    }
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .frame(minWidth: 100, maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            selectedDestination = Self.destination(for: currentLocation)
        }
        .onChange(of: currentLocation) { _, newLocation in
            selectedDestination = Self.destination(for: newLocation)
        }
        .onChange(of: selectedDestination) { _, newDestination in
            guard let newDestination, newDestination != Self.destination(for: currentLocation) else {
                return
            }

            switch newDestination {
            case .recents:
                onRecents()
            case .directory(let url):
                onNavigate(url)
            }
        }
        .sheet(item: $editingTarget) { target in
            SidebarAppearanceEditorSheet(target: target)
        }
    }

    private var standardPlaces: [SidebarItem] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let candidates = [
            SidebarItem(name: L10n.string("Home"), icon: "house.fill", url: home, id: "home"),
            SidebarItem(
                name: L10n.string("Desktop"),
                icon: "menubar.dock.rectangle",
                url: home.appendingPathComponent("Desktop", isDirectory: true),
                id: "desktop"
            ),
            SidebarItem(
                name: L10n.string("Applications"),
                icon: "square.grid.2x2.fill",
                url: URL(fileURLWithPath: "/Applications", isDirectory: true),
                id: "applications"
            ),
            SidebarItem(
                name: L10n.string("Documents"),
                icon: "doc.fill",
                url: home.appendingPathComponent("Documents", isDirectory: true),
                id: "documents"
            ),
            SidebarItem(
                name: L10n.string("Downloads"),
                icon: "arrow.down.circle.fill",
                url: home.appendingPathComponent("Downloads", isDirectory: true),
                id: "downloads"
            ),
            SidebarItem(
                name: L10n.string("Movies"),
                icon: "film.fill",
                url: home.appendingPathComponent("Movies", isDirectory: true),
                id: "movies"
            ),
            SidebarItem(
                name: L10n.string("Music"),
                icon: "music.note",
                url: home.appendingPathComponent("Music", isDirectory: true),
                id: "music"
            ),
            SidebarItem(
                name: L10n.string("Pictures"),
                icon: "photo.fill",
                url: home.appendingPathComponent("Pictures", isDirectory: true),
                id: "pictures"
            ),
        ]

        return candidates.filter { item in
            guard let url = item.url else { return false }
            return isDirectory(url)
        }
    }

    private var iCloudDriveURL: URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let localURL = home
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Mobile Documents", isDirectory: true)
            .appendingPathComponent("com~apple~CloudDocs", isDirectory: true)
        let candidates = [
            FileManager.default.url(forUbiquityContainerIdentifier: nil),
            localURL,
        ].compactMap { $0?.standardizedFileURL }

        return candidates.first(where: isDirectory)
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
    }

    private func defaultIconColor(for item: SidebarItem) -> Color {
        if item.isRecents { return MFDTheme.secondaryAccent }
        switch item.id {
        case "home": return .blue
        case "desktop": return Color(red: 0.20, green: 0.65, blue: 0.95)
        case "applications": return .indigo
        case "documents": return Color(red: 0.35, green: 0.45, blue: 0.95)
        case "downloads": return Color(red: 0.15, green: 0.75, blue: 0.65)
        case "movies": return .purple
        case "music": return .pink
        case "pictures": return .orange
        case "icloud-drive": return .cyan
        default: return MFDTheme.primaryAccent
        }
    }

    private func iconColor(for item: SidebarItem) -> Color {
        if let customColor = preferences.customColors[item.id],
           let color = SidebarColorOption.color(for: customColor) {
            return color
        }
        return defaultIconColor(for: item)
    }

    private func iconName(for item: SidebarItem) -> String {
        preferences.customIcons[item.id] ?? item.icon
    }

    private func favoriteRow(_ favorite: FileFavorite) -> some View {
        let icon = favorite.customIcon ?? "star.fill"
        let color = SidebarColorOption.color(for: favorite.customColor) ?? .yellow

        return SidebarLabel(icon: icon, name: favorite.name, iconColor: color)
            .tag(SidebarDestination.directory(favorite.url))
            .help(favorite.url.path)
            .contextMenu {
                Menu("设置颜色") {
                    ForEach(SidebarColorOption.all) { option in
                        Button {
                            favoritesStore.updateColor(id: favorite.id, color: option.id)
                        } label: {
                            Text(favorite.customColor == option.id ? "✓ \(option.emoji) \(option.name)" : "   \(option.emoji) \(option.name)")
                        }
                    }
                    Divider()
                    Button("默认颜色 (金黄)") {
                        favoritesStore.updateColor(id: favorite.id, color: nil)
                    }
                }

                Menu("设置图标") {
                    ForEach(SidebarIconOption.all) { option in
                        Button {
                            favoritesStore.updateIcon(id: favorite.id, icon: option.systemName)
                        } label: {
                            Text(favorite.customIcon == option.systemName ? "✓ \(option.emoji)  \(option.name)" : "   \(option.emoji)  \(option.name)")
                        }
                    }
                    Divider()
                    Button("默认图标 (⭐️ 星标)") {
                        favoritesStore.updateIcon(id: favorite.id, icon: nil)
                    }
                }

                Button("自定义外观…") {
                    editingTarget = SidebarAppearanceEditorTarget(
                        id: favorite.id.uuidString,
                        name: favorite.name,
                        currentIcon: icon,
                        currentColor: color,
                        currentColorValue: favorite.customColor,
                        onSave: { newIcon, newColor in
                            favoritesStore.updateAppearance(id: favorite.id, icon: newIcon, color: newColor)
                        },
                        onReset: {
                            favoritesStore.updateAppearance(id: favorite.id, icon: nil, color: nil)
                        }
                    )
                }

                Divider()

                Button(L10n.string("Remove from Favorites"), role: .destructive) {
                    favoritesStore.remove(id: favorite.id)
                }
            }
    }

    private func sidebarRow(_ item: SidebarItem) -> some View {
        let icon = iconName(for: item)
        let color = iconColor(for: item)

        return SidebarLabel(icon: icon, name: item.name, iconColor: color)
            .tag(item.destination)
            .help(item.url?.path ?? item.name)
            .contextMenu {
                Menu("设置颜色") {
                    ForEach(SidebarColorOption.all) { option in
                        Button {
                            preferences.setColor(option.id, for: item.id)
                        } label: {
                            Text(preferences.customColors[item.id] == option.id ? "✓ \(option.emoji) \(option.name)" : "   \(option.emoji) \(option.name)")
                        }
                    }
                    Divider()
                    Button("还原为默认颜色") {
                        preferences.setColor(nil, for: item.id)
                    }
                }

                Menu("设置图标") {
                    ForEach(SidebarIconOption.all) { option in
                        Button {
                            preferences.setIcon(option.systemName, for: item.id)
                        } label: {
                            Text(preferences.customIcons[item.id] == option.systemName ? "✓ \(option.emoji)  \(option.name)" : "   \(option.emoji)  \(option.name)")
                        }
                    }
                    Divider()
                    Button("还原为默认图标") {
                        preferences.setIcon(nil, for: item.id)
                    }
                }

                Button("自定义外观…") {
                    editingTarget = SidebarAppearanceEditorTarget(
                        id: item.id,
                        name: item.name,
                        currentIcon: icon,
                        currentColor: color,
                        currentColorValue: preferences.customColors[item.id],
                        onSave: { newIcon, newColor in
                            preferences.setIcon(newIcon, for: item.id)
                            preferences.setColor(newColor, for: item.id)
                        },
                        onReset: {
                            preferences.reset(for: item.id)
                        }
                    )
                }

                Divider()

                Button("还原为默认外观") {
                    preferences.reset(for: item.id)
                }
            }
    }

    private func volumeRow(_ volume: VolumeStore.MountedVolume, showCapacity: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: volumeIcon(for: volume))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.tint)
                .frame(width: 18)

            Text(volume.name)
                .font(.system(size: 13))
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer(minLength: 4)

            if showCapacity, let capacityDescription = volume.capacityDescription {
                Text(capacityDescription)
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            if volumeStore.isEjecting(volume) {
                ProgressView()
                    .controlSize(.small)
                    .frame(width: 18, height: 18)
                    .help(L10n.format("Ejecting %@...", volume.name))
                    .accessibilityLabel(L10n.format("Ejecting %@...", volume.name))
            } else if volume.canEject {
                Button {
                    volumeStore.eject(volume)
                } label: {
                    Image(systemName: "eject.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .frame(width: 18, height: 18)
                }
                .buttonStyle(.borderless)
                .help(L10n.format("Eject %@", volume.name))
                .accessibilityLabel(L10n.format("Eject %@", volume.name))
            }
        }
        .font(.system(size: 13))
        .lineLimit(1)
        .frame(minHeight: 24)
        .tag(SidebarDestination.directory(volume.url))
        .help(volumeHelp(for: volume))
        .contextMenu {
            if volume.canEject {
                Button {
                    volumeStore.eject(volume)
                } label: {
                    Label(L10n.format("Eject %@", volume.name), systemImage: "eject.fill")
                }
                .disabled(volumeStore.isEjecting(volume))
            }
        }
    }

    private func volumeErrorRow(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 7) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .frame(width: 18)

            Text(message)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(3)

            Spacer(minLength: 0)

            Button {
                volumeStore.clearError()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .frame(width: 18, height: 18)
            }
            .buttonStyle(.borderless)
            .help(L10n.string("Dismiss"))
        }
        .padding(.vertical, 2)
        .listRowSeparator(.hidden)
    }

    private func volumeIcon(for volume: VolumeStore.MountedVolume) -> String {
        if volume.isNetwork {
            return "network"
        }
        if volume.isRemovable || volume.isEjectable {
            return "externaldrive.fill"
        }
        return volume.isRootFileSystem ? "internaldrive.fill" : "externaldrive.fill"
    }

    private func volumeHelp(for volume: VolumeStore.MountedVolume) -> String {
        if let capacityDescription = volume.capacityDescription {
            return L10n.format("%@\n%@", volume.url.path, capacityDescription)
        }
        return volume.url.path
    }

    private func isDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
            && isDirectory.boolValue
    }

    private static func destination(for location: BrowserLocation) -> SidebarDestination? {
        switch location {
        case .recents:
            return .recents
        case .directory(let url):
            return .directory(url.standardizedFileURL)
        case .search, .aiSearch:
            return nil
        }
    }
}

private struct SidebarLabel: View {
    let icon: String
    let name: String
    var iconColor: Color = MFDTheme.primaryAccent

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(iconColor)
                .font(.system(size: 13, weight: .medium))
                .frame(width: 18)

            Text(name)
                .font(.system(size: 13))
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer(minLength: 0)
        }
        .frame(minHeight: 24)
    }
}

// MARK: - Sidebar Color & Icon Models

struct SidebarColorOption: Identifiable, Hashable {
    let id: String
    let name: String
    let emoji: String
    let hex: String
    let color: Color

    static let all: [SidebarColorOption] = [
        SidebarColorOption(id: "yellow", name: "金黄", emoji: "🟡", hex: "#EAB308", color: .yellow),
        SidebarColorOption(id: "orange", name: "橙色", emoji: "🟠", hex: "#F97316", color: .orange),
        SidebarColorOption(id: "red", name: "红色", emoji: "🔴", hex: "#EF4444", color: .red),
        SidebarColorOption(id: "pink", name: "粉红", emoji: "🌸", hex: "#EC4899", color: .pink),
        SidebarColorOption(id: "purple", name: "紫色", emoji: "🟣", hex: "#8B5CF6", color: .purple),
        SidebarColorOption(id: "blue", name: "经典蓝", emoji: "🔵", hex: "#3B82F6", color: .blue),
        SidebarColorOption(id: "cyan", name: "天青", emoji: "🩵", hex: "#06B6D4", color: .cyan),
        SidebarColorOption(id: "mint", name: "薄荷绿", emoji: "🟢", hex: "#10B981", color: .mint),
        SidebarColorOption(id: "brown", name: "暖棕", emoji: "🟤", hex: "#B45309", color: .brown),
        SidebarColorOption(id: "gray", name: "石板灰", emoji: "⚪️", hex: "#94A3B8", color: .gray),
    ]

    static func color(for keyOrHex: String?) -> Color? {
        guard let value = keyOrHex?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        if let option = all.first(where: { $0.id == value }) {
            return option.color
        }
        if value.hasPrefix("#") {
            return parseHex(value)
        }
        return nil
    }

    private static func parseHex(_ hex: String) -> Color? {
        var hexSanitized = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if hexSanitized.hasPrefix("#") {
            hexSanitized.removeFirst()
        }
        guard hexSanitized.count == 6 || hexSanitized.count == 8 else { return nil }
        var rgbValue: UInt64 = 0
        guard Scanner(string: hexSanitized).scanHexInt64(&rgbValue) else { return nil }

        let r, g, b, a: Double
        if hexSanitized.count == 6 {
            r = Double((rgbValue & 0xFF0000) >> 16) / 255.0
            g = Double((rgbValue & 0x00FF00) >> 8) / 255.0
            b = Double(rgbValue & 0x0000FF) / 255.0
            a = 1.0
        } else {
            r = Double((rgbValue & 0xFF000000) >> 24) / 255.0
            g = Double((rgbValue & 0x00FF0000) >> 16) / 255.0
            b = Double((rgbValue & 0x0000FF00) >> 8) / 255.0
            a = Double(rgbValue & 0x000000FF) / 255.0
        }
        return Color(red: r, green: g, blue: b, opacity: a)
    }
}

struct SidebarIconOption: Identifiable, Hashable {
    let id: String
    let name: String
    let emoji: String
    let systemName: String

    static let all: [SidebarIconOption] = [
        SidebarIconOption(id: "star", name: "星标", emoji: "⭐️", systemName: "star.fill"),
        SidebarIconOption(id: "folder", name: "文件夹", emoji: "📁", systemName: "folder.fill"),
        SidebarIconOption(id: "code", name: "代码工程", emoji: "💻", systemName: "chevron.left.forwardslash.chevron.right"),
        SidebarIconOption(id: "terminal", name: "终端", emoji: "🖥", systemName: "terminal.fill"),
        SidebarIconOption(id: "rocket", name: "火箭项目", emoji: "🚀", systemName: "rocket.fill"),
        SidebarIconOption(id: "box", name: "仓库依赖", emoji: "📦", systemName: "shippingbox.fill"),
        SidebarIconOption(id: "tag", name: "标签分类", emoji: "🏷", systemName: "tag.fill"),
        SidebarIconOption(id: "bookmark", name: "书签", emoji: "🔖", systemName: "bookmark.fill"),
        SidebarIconOption(id: "lightbulb", name: "创意想法", emoji: "💡", systemName: "lightbulb.fill"),
        SidebarIconOption(id: "bolt", name: "核心快速", emoji: "⚡️", systemName: "bolt.fill"),
        SidebarIconOption(id: "target", name: "目标成就", emoji: "🎯", systemName: "target"),
        SidebarIconOption(id: "note", name: "笔记周报", emoji: "📝", systemName: "note.text"),
        SidebarIconOption(id: "palette", name: "设计素材", emoji: "🎨", systemName: "paintpalette.fill"),
        SidebarIconOption(id: "heart", name: "特别喜爱", emoji: "❤️", systemName: "heart.fill"),
        SidebarIconOption(id: "coffee", name: "日常休闲", emoji: "☕️", systemName: "cup.and.saucer.fill"),
        SidebarIconOption(id: "flame", name: "紧急热门", emoji: "🔥", systemName: "flame.fill"),
        SidebarIconOption(id: "wrench", name: "工具配置", emoji: "🛠", systemName: "wrench.and.screwdriver.fill"),
        SidebarIconOption(id: "globe", name: "网络网站", emoji: "🌐", systemName: "globe"),
    ]
}

// MARK: - Sidebar Preferences Store

@MainActor
final class SidebarPreferences: ObservableObject {
    static let shared = SidebarPreferences()
    private let userDefaults: UserDefaults
    private let colorsKey = "com.multifinder.sidebar.customColors"
    private let iconsKey = "com.multifinder.sidebar.customIcons"

    @Published private(set) var customColors: [String: String]
    @Published private(set) var customIcons: [String: String]

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
        self.customColors = userDefaults.dictionary(forKey: colorsKey) as? [String: String] ?? [:]
        self.customIcons = userDefaults.dictionary(forKey: iconsKey) as? [String: String] ?? [:]
    }

    func setColor(_ color: String?, for itemId: String) {
        if let color, !color.isEmpty {
            customColors[itemId] = color
        } else {
            customColors.removeValue(forKey: itemId)
        }
        userDefaults.set(customColors, forKey: colorsKey)
    }

    func setIcon(_ icon: String?, for itemId: String) {
        if let icon, !icon.isEmpty {
            customIcons[itemId] = icon
        } else {
            customIcons.removeValue(forKey: itemId)
        }
        userDefaults.set(customIcons, forKey: iconsKey)
    }

    func reset(for itemId: String) {
        customColors.removeValue(forKey: itemId)
        customIcons.removeValue(forKey: itemId)
        userDefaults.set(customColors, forKey: colorsKey)
        userDefaults.set(customIcons, forKey: iconsKey)
    }
}

// MARK: - Sidebar Appearance Editor Sheet

struct SidebarAppearanceEditorTarget: Identifiable {
    let id: String
    let name: String
    let currentIcon: String
    let currentColor: Color
    let currentColorValue: String?
    let onSave: (String?, String?) -> Void
    let onReset: () -> Void
}

struct SidebarAppearanceEditorSheet: View {
    let target: SidebarAppearanceEditorTarget
    @Environment(\.dismiss) private var dismiss

    @State private var selectedIcon: String
    @State private var selectedColorKey: String?
    @State private var customColor: Color
    @State private var customSFText: String = ""

    init(target: SidebarAppearanceEditorTarget) {
        self.target = target
        _selectedIcon = State(initialValue: target.currentIcon)
        _selectedColorKey = State(initialValue: target.currentColorValue)
        _customColor = State(initialValue: target.currentColor)
    }

    private var activeColor: Color {
        if let key = selectedColorKey, let c = SidebarColorOption.color(for: key) {
            return c
        }
        return customColor
    }

    var body: some View {
        VStack(spacing: 16) {
            // Header
            HStack {
                Text("自定义外观")
                    .font(.headline)
                Spacer()
                Button("完成") {
                    let finalColor = selectedColorKey ?? customColorHex
                    target.onSave(selectedIcon, finalColor)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }

            // Preview Box
            HStack(spacing: 12) {
                Image(systemName: selectedIcon)
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(activeColor)
                    .font(.system(size: 22, weight: .semibold))
                    .frame(width: 32, height: 32)
                Text(target.name)
                    .font(.system(size: 15, weight: .medium))
                Spacer()
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(MFDTheme.subtleHairline, lineWidth: 1))

            Divider()

            // Color Selector
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("选择颜色")
                        .font(.subheadline).bold()
                    Spacer()
                    ColorPicker("自定义", selection: $customColor, supportsOpacity: false)
                        .labelsHidden()
                        .onChange(of: customColor) { _, _ in
                            selectedColorKey = nil
                        }
                }

                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 5), spacing: 8) {
                    ForEach(SidebarColorOption.all) { option in
                        Button {
                            selectedColorKey = option.id
                            customColor = option.color
                        } label: {
                            HStack(spacing: 4) {
                                Circle()
                                    .fill(option.color)
                                    .frame(width: 14, height: 14)
                                Text(option.name)
                                    .font(.system(size: 11))
                            }
                            .padding(.horizontal, 6)
                            .padding(.vertical, 4)
                            .frame(maxWidth: .infinity)
                            .background(
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(selectedColorKey == option.id ? option.color.opacity(0.18) : Color.clear)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 6)
                                    .stroke(selectedColorKey == option.id ? option.color : Color.clear, lineWidth: 1.2)
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            Divider()

            // Icon Selector
            VStack(alignment: .leading, spacing: 8) {
                Text("选择图标")
                    .font(.subheadline).bold()

                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 6), spacing: 8) {
                    ForEach(SidebarIconOption.all) { option in
                        Button {
                            selectedIcon = option.systemName
                        } label: {
                            VStack(spacing: 4) {
                                Image(systemName: option.systemName)
                                    .font(.system(size: 16))
                                    .foregroundStyle(selectedIcon == option.systemName ? activeColor : .primary)
                                    .frame(height: 20)
                                Text(option.name)
                                    .font(.system(size: 9))
                                    .foregroundColor(.secondary)
                                    .lineLimit(1)
                            }
                            .frame(maxWidth: .infinity, minHeight: 46)
                            .background(
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(selectedIcon == option.systemName ? activeColor.opacity(0.12) : Color.clear)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 6)
                                    .stroke(selectedIcon == option.systemName ? activeColor : Color.clear, lineWidth: 1.2)
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }

                HStack(spacing: 8) {
                    TextField("SF Symbol 名称 (如 swift, cpu, flame)", text: $customSFText)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 11))
                    Button("应用") {
                        let trimmed = customSFText.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !trimmed.isEmpty {
                            selectedIcon = trimmed
                        }
                    }
                    .disabled(customSFText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                .padding(.top, 4)
            }

            Divider()

            // Footer
            HStack {
                Button("还原默认") {
                    target.onReset()
                    dismiss()
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                Spacer()
                Button("取消") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
            }
        }
        .padding(18)
        .frame(width: 380)
    }

    private var customColorHex: String {
        let nsColor = NSColor(customColor).usingColorSpace(.sRGB) ?? NSColor.systemBlue
        let r = Int(round(max(0, min(1, nsColor.redComponent)) * 255.0))
        let g = Int(round(max(0, min(1, nsColor.greenComponent)) * 255.0))
        let b = Int(round(max(0, min(1, nsColor.blueComponent)) * 255.0))
        return String(format: "#%02X%02X%02X", r, g, b)
    }
}
