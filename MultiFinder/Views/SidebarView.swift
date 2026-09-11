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
    @State private var selectedDestination: SidebarDestination?

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

    private func iconColor(for item: SidebarItem) -> Color {
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

    private func favoriteRow(_ favorite: FileFavorite) -> some View {
        SidebarLabel(icon: "star.fill", name: favorite.name, iconColor: .yellow)
            .tag(SidebarDestination.directory(favorite.url))
            .help(favorite.url.path)
            .contextMenu {
                Button(L10n.string("Remove from Favorites"), role: .destructive) {
                    favoritesStore.remove(id: favorite.id)
                }
            }
    }

    private func sidebarRow(_ item: SidebarItem) -> some View {
        SidebarLabel(icon: item.icon, name: item.name, iconColor: iconColor(for: item))
            .tag(item.destination)
            .help(item.url?.path ?? item.name)
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
