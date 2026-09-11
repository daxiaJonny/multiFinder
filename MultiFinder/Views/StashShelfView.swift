import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Floating glass shelf / stash bar for cross-pane file aggregation and dumping.
struct StashShelfView: View {
    @ObservedObject var stashStore = StashShelfStore.shared
    @ObservedObject var layoutManager: LayoutManager

    @State private var isTargeted = false
    @State private var hoveredItemID: UUID?

    var body: some View {
        Group {
            if stashStore.isPresented {
                if stashStore.isExpanded {
                    expandedShelf
                } else {
                    collapsedCapsule
                }
            }
        }
        .onDrop(of: [UTType.fileURL], isTargeted: $isTargeted) { providers in
            handleDrop(providers: providers)
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.82), value: stashStore.isExpanded)
        .animation(.spring(response: 0.35, dampingFraction: 0.82), value: stashStore.isPresented)
    }

    // MARK: - Expanded Glass Shelf

    private var expandedShelf: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Header
            HStack(spacing: 8) {
                Image(systemName: "tray.2.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(MFDTheme.primaryAccent)

                Text(L10n.string("Stash Shelf"))
                    .font(.system(size: 13, weight: .bold))

                if !stashStore.items.isEmpty {
                    Text("\(stashStore.count)")
                        .font(.system(size: 11, weight: .semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(
                            Capsule()
                                .fill(MFDTheme.primaryAccent.opacity(0.20))
                        )
                        .foregroundStyle(MFDTheme.primaryAccent)

                    Text("· \(stashStore.formattedTotalSize)")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button(action: stashStore.toggleExpanded) {
                    Image(systemName: "arrow.down.right.and.arrow.up.left")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help(L10n.string("Minimize to Capsule"))

                Button(action: stashStore.dismiss) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help(L10n.string("Close Shelf"))
            }

            // Body: Cards carousel or drop guide
            if stashStore.items.isEmpty {
                emptyDropZone
            } else {
                itemsCarousel
            }

            // Footer Actions
            if !stashStore.items.isEmpty {
                Divider()
                    .background(MFDTheme.subtleHairline)

                HStack(spacing: 8) {
                    Button {
                        dumpAll(operation: .copy)
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "doc.on.doc.fill")
                                .font(.system(size: 10))
                            Text(L10n.string("Copy All to Current"))
                                .font(.system(size: 11, weight: .medium))
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(MFDTheme.primaryAccent)
                        )
                        .foregroundStyle(.white)
                    }
                    .buttonStyle(.plain)
                    .help(L10n.string("Copy all stashed files into the currently focused pane"))

                    Button {
                        dumpAll(operation: .move)
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.right.doc.on.clipboard")
                                .font(.system(size: 10))
                            Text(L10n.string("Move All to Current"))
                                .font(.system(size: 11, weight: .medium))
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(Color.primary.opacity(0.08))
                        )
                        .foregroundStyle(.primary)
                    }
                    .buttonStyle(.plain)
                    .help(L10n.string("Move all stashed files into the currently focused pane"))

                    Spacer()

                    Button(action: stashStore.clear) {
                        Image(systemName: "trash")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help(L10n.string("Clear Stash"))
                }
            }
        }
        .padding(12)
        .frame(width: 420)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(
                            isTargeted
                                ? MFDTheme.primaryAccent
                                : MFDTheme.subtleHairline,
                            lineWidth: isTargeted ? 2.0 : 0.8
                        )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(MFDTheme.specularHighlightGradient, lineWidth: 1.0)
                        .blendMode(.plusLighter)
                )
        )
        .shadow(
            color: isTargeted ? MFDTheme.activeAmbientGlow : Color.black.opacity(0.35),
            radius: isTargeted ? 18 : 14,
            y: 5
        )
    }

    // MARK: - Collapsed Capsule

    private var collapsedCapsule: some View {
        Button(action: stashStore.toggleExpanded) {
            HStack(spacing: 6) {
                Image(systemName: "tray.2.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(MFDTheme.primaryAccent)

                Text(stashStore.items.isEmpty ? L10n.string("Stash (0)") : "\(stashStore.count) \(L10n.string("Items"))")
                    .font(.system(size: 11, weight: .semibold))

                if !stashStore.items.isEmpty {
                    Text("· \(stashStore.formattedTotalSize)")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }

                Image(systemName: "chevron.up")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                Capsule()
                    .fill(.ultraThinMaterial)
                    .overlay(
                        Capsule()
                            .stroke(
                                isTargeted ? MFDTheme.primaryAccent : MFDTheme.subtleHairline,
                                lineWidth: isTargeted ? 2.0 : 0.8
                            )
                    )
            )
            .shadow(color: Color.black.opacity(0.28), radius: 8, y: 3)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Empty Drop Zone

    private var emptyDropZone: some View {
        VStack(spacing: 8) {
            Image(systemName: "arrow.down.doc.fill")
                .font(.system(size: 24))
                .foregroundStyle(isTargeted ? MFDTheme.primaryAccent : .secondary.opacity(0.6))

            Text(L10n.string("Drop files here from any pane to stash"))
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)

            Text(L10n.string("Collect files across panes, then dump them all at once."))
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(
                    isTargeted ? MFDTheme.primaryAccent : Color.secondary.opacity(0.25),
                    style: StrokeStyle(lineWidth: 1.2, dash: [5, 4])
                )
        )
    }

    // MARK: - Items Carousel

    private var itemsCarousel: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(stashStore.items) { item in
                    stashCard(for: item)
                }
            }
            .padding(.vertical, 4)
            .padding(.horizontal, 2)
        }
    }

    private func stashCard(for item: StashItem) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(nsImage: item.icon)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 28, height: 28)

                Spacer()

                Button {
                    stashStore.remove(id: item.id)
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(hoveredItemID == item.id ? .primary : .tertiary)
                        .padding(4)
                        .background(Circle().fill(Color.primary.opacity(hoveredItemID == item.id ? 0.15 : 0.05)))
                }
                .buttonStyle(.plain)
            }

            Text(item.name)
                .font(.system(size: 11, weight: .medium))
                .lineLimit(1)
                .truncationMode(.middle)

            Text(item.formattedSize)
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
        }
        .padding(8)
        .frame(width: 105, height: 82)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(MFDTheme.subtleHairline, lineWidth: 0.8)
                )
        )
        .onHover { isHovering in
            hoveredItemID = isHovering ? item.id : nil
        }
        .onDrag {
            NSItemProvider(object: item.url as NSURL)
        }
    }

    // MARK: - Handlers

    private func dumpAll(operation: FileDropOperation) {
        guard let currentURL = layoutManager.focusedPane?.currentURL else { return }
        stashStore.transferAll(into: currentURL, operation: operation)
    }

    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        var droppedURLs: [URL] = []
        let group = DispatchGroup()

        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                group.enter()
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                    defer { group.leave() }
                    if let data = item as? Data,
                       let url = URL(dataRepresentation: data, relativeTo: nil) {
                        droppedURLs.append(url)
                    } else if let url = item as? URL {
                        droppedURLs.append(url)
                    }
                }
            }
        }

        group.notify(queue: .main) {
            if !droppedURLs.isEmpty {
                self.stashStore.add(urls: droppedURLs)
            }
        }
        return true
    }
}
