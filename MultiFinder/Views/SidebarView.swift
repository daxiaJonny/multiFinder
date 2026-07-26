import SwiftUI

struct SidebarItem: Identifiable {
    let id = UUID()
    let name: String
    let icon: String
    let iconPath: String?
    let url: URL?
    let isRecents: Bool

    init(name: String, icon: String, iconPath: String? = nil, url: URL? = nil, isRecents: Bool = false) {
        self.name = name
        self.icon = icon
        self.iconPath = iconPath
        self.url = url
        self.isRecents = isRecents
    }
}

struct SidebarView: View {
    let onNavigate: (URL) -> Void
    let onRecents: () -> Void
    @ObservedObject private var favoritesStore = FavoritesStore.shared

    private var shortcuts: [SidebarItem] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [
            SidebarItem(name: "最近使用", icon: "clock.arrow.circlepath", isRecents: true),
            SidebarItem(name: "应用程序", icon: "paperplane.fill", url: URL(fileURLWithPath: "/Applications")),
            SidebarItem(name: "文稿", icon: "doc.fill", url: home.appendingPathComponent("Documents")),
            SidebarItem(name: "下载", icon: "arrow.down.circle.fill", url: home.appendingPathComponent("Downloads")),
        ]
    }

    private var locations: [SidebarItem] {
        let macName = Host.current().localizedName ?? NSUserName() + "的Mac"
        return [
            SidebarItem(name: macName, icon: "laptopcomputer", url: URL(fileURLWithPath: "/")),
        ]
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if !favoritesStore.favorites.isEmpty {
                    sectionHeader("收藏")

                    ForEach(favoritesStore.favorites) { favorite in
                        favoriteRow(favorite)
                    }

                    Spacer().frame(height: 16)
                }

                sectionHeader("个人收藏")

                ForEach(shortcuts) { item in
                    sidebarRow(item)
                }

                Spacer().frame(height: 16)

                sectionHeader("位置")

                ForEach(locations) { item in
                    sidebarRow(item)
                }

                Spacer().frame(height: 12)
            }
        }
        .contentMargins(.top, 12, for: .scrollContent)
        .contentMargins(.leading, 8, for: .scrollContent)
        .frame(minWidth: 100, maxWidth: .infinity)
        .frame(maxHeight: .infinity)
        .background(Color(nsColor: .underPageBackgroundColor))
    }

    private func favoriteRow(_ favorite: FileFavorite) -> some View {
        Button(action: { onNavigate(favorite.url) }) {
            HStack(spacing: 7) {
                Image(systemName: "star.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(.yellow)
                    .frame(width: 18)

                Text(favorite.name)
                    .font(.system(size: 13))
                    .lineLimit(1)
                    .foregroundStyle(.primary)

                Spacer()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(favorite.url.path)
        .contextMenu {
            Button("Remove from Favorites", role: .destructive) {
                favoritesStore.remove(id: favorite.id)
            }
        }
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 11, weight: .semibold))
            .foregroundColor(.secondary)
            .padding(.horizontal, 8)
            .padding(.bottom, 4)
    }

    private func sidebarRow(_ item: SidebarItem) -> some View {
        Button(action: {
            if item.isRecents {
                onRecents()
            } else if let url = item.url {
                onNavigate(url)
            }
        }) {
            HStack(spacing: 7) {
                Image(systemName: item.icon)
                    .font(.system(size: 13))
                    .foregroundColor(.accentColor)
                    .frame(width: 18)

                Text(item.name)
                    .font(.system(size: 13))
                    .lineLimit(1)
                    .foregroundColor(.primary)

                Spacer()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
