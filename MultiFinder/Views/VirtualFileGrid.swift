import AppKit
import SwiftUI

/// Finder-style icon view: NSCollectionView creates tiles only for visible items.
struct VirtualFileGrid: NSViewRepresentable {
    let items: [FileItem]
    let itemsRevision: UInt64
    var tableRevision: UInt64 = 0
    let selection: Set<FileItem.ID>
    let gitIndex: GitChangeIndex?
    let gitGeneration: UInt64
    var scrollsHorizontally: Bool = false
    let onSelection: (Set<FileItem.ID>) -> Void
    let onOpen: (FileItem) -> Void
    let onFocus: () -> Void
    let onQuickLook: () -> Void
    let onBeginFiltering: () -> Void
    let onDelete: () -> Void
    let onDrop: ([URL], URL) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeNSView(context: Context) -> NSScrollView {
        let layout = NSCollectionViewFlowLayout()
        let horizontal = context.coordinator.parent.scrollsHorizontally
        layout.scrollDirection = horizontal ? .horizontal : .vertical
        layout.itemSize = horizontal ? NSSize(width: 108, height: 132) : NSSize(width: 96, height: 112)
        layout.minimumInteritemSpacing = 12
        layout.minimumLineSpacing = horizontal ? 8 : 14
        layout.sectionInset = NSEdgeInsets(top: horizontal ? 8 : 14, left: 14, bottom: horizontal ? 8 : 14, right: 14)

        let collection = VirtualFileCollectionView()
        collection.coordinator = context.coordinator
        context.coordinator.collectionView = collection
        collection.collectionViewLayout = layout
        collection.isSelectable = true
        collection.allowsMultipleSelection = true
        collection.backgroundColors = [.textBackgroundColor]
        collection.dataSource = context.coordinator
        collection.delegate = context.coordinator
        collection.register(
            FileGridCollectionItem.self,
            forItemWithIdentifier: FileGridCollectionItem.reuseIdentifier
        )
        collection.registerForDraggedTypes([.fileURL])

        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = !context.coordinator.parent.scrollsHorizontally
        scrollView.hasHorizontalScroller = context.coordinator.parent.scrollsHorizontally
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .textBackgroundColor
        scrollView.documentView = collection
        context.coordinator.apply(self)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.apply(self)
    }
}

final class VirtualFileCollectionView: NSCollectionView {
    weak var coordinator: VirtualFileGrid.Coordinator?

    override func keyDown(with event: NSEvent) {
        coordinator?.parent.onFocus()
        let characters = event.charactersIgnoringModifiers ?? ""
        if characters == "/", !event.modifierFlags.contains(.command) {
            coordinator?.parent.onBeginFiltering()
            return
        }
        if event.keyCode == 49 {
            coordinator?.parent.onQuickLook()
            return
        }
        if event.keyCode == 36 || event.keyCode == 76 {
            if let item = coordinator?.selectedItems().first {
                coordinator?.parent.onOpen(item)
            }
            return
        }
        if event.keyCode == 51, event.modifierFlags.contains(.command) {
            coordinator?.parent.onDelete()
            return
        }
        super.keyDown(with: event)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        enclosingScrollView?.menu ?? super.menu(for: event)
    }
}

extension VirtualFileGrid {
    @MainActor
    final class Coordinator: NSObject, NSCollectionViewDataSource, NSCollectionViewDelegate {
        var parent: VirtualFileGrid
        weak var collectionView: VirtualFileCollectionView?
        private var items: [FileItem] = []
        private var indexByID: [FileItem.ID: Int] = [:]
        private var gitIndex: GitChangeIndex?
        private var appliedItemsRevision: UInt64 = .max
        private var appliedTableRevision: UInt64 = .max
        private var appliedGitGeneration: UInt64 = .max
        private var isApplyingSelection = false

        init(parent: VirtualFileGrid) {
            self.parent = parent
        }

        func apply(_ parent: VirtualFileGrid) {
            self.parent = parent
            guard let collectionView else { return }
            if parent.itemsRevision == appliedItemsRevision,
               parent.tableRevision == appliedTableRevision,
               parent.gitGeneration == appliedGitGeneration {
                applySelection(parent.selection, in: collectionView)
                return
            }
            let idsChanged = !items.elementsEqual(parent.items) { $0.id == $1.id }
            let gitChanged = parent.gitGeneration != appliedGitGeneration
            items = parent.items
            if idsChanged {
                indexByID = Dictionary(items.enumerated().map { ($0.element.id, $0.offset) }, uniquingKeysWith: { first, _ in first })
            }
            gitIndex = parent.gitIndex
            appliedItemsRevision = parent.itemsRevision
            appliedTableRevision = parent.tableRevision
            appliedGitGeneration = parent.gitGeneration
            if idsChanged || gitChanged {
                collectionView.reloadData()
            } else {
                collectionView.reloadItems(at: collectionView.indexPathsForVisibleItems())
            }
            applySelection(parent.selection, in: collectionView)
        }

        func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int {
            items.count
        }

        func collectionView(
            _ collectionView: NSCollectionView,
            itemForRepresentedObjectAt indexPath: IndexPath
        ) -> NSCollectionViewItem {
            let item = collectionView.makeItem(
                withIdentifier: FileGridCollectionItem.reuseIdentifier,
                for: indexPath
            )
            guard let cell = item as? FileGridCollectionItem, items.indices.contains(indexPath.item) else {
                return item
            }
            let file = items[indexPath.item]
            cell.update(
                item: file,
                gitChange: gitIndex?.changeType(for: file.url),
                onOpen: { [weak self] in self?.parent.onOpen(file) }
            )
            return cell
        }

        func collectionView(_ collectionView: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) {
            publishSelection(from: collectionView)
        }

        func collectionView(_ collectionView: NSCollectionView, didDeselectItemsAt indexPaths: Set<IndexPath>) {
            publishSelection(from: collectionView)
        }

        func collectionView(
            _ collectionView: NSCollectionView,
            pasteboardWriterForItemAt indexPath: IndexPath
        ) -> (any NSPasteboardWriting)? {
            guard items.indices.contains(indexPath.item) else { return nil }
            return items[indexPath.item].url as NSURL
        }

        func collectionView(
            _ collectionView: NSCollectionView,
            validateDrop draggingInfo: any NSDraggingInfo,
            proposedIndexPath proposedDropIndexPath: AutoreleasingUnsafeMutablePointer<NSIndexPath>,
            dropOperation proposedDropOperation: UnsafeMutablePointer<NSCollectionView.DropOperation>
        ) -> NSDragOperation {
            let index = proposedDropIndexPath.pointee.item
            guard proposedDropOperation.pointee == .on,
                  items.indices.contains(index),
                  items[index].isDirectory,
                  !items[index].isPackage else { return [] }
            return draggingInfo.draggingSourceOperationMask.contains(.move) ? .move : .copy
        }

        func collectionView(
            _ collectionView: NSCollectionView,
            acceptDrop draggingInfo: any NSDraggingInfo,
            indexPath: IndexPath,
            dropOperation: NSCollectionView.DropOperation
        ) -> Bool {
            guard dropOperation == .on, items.indices.contains(indexPath.item) else { return false }
            let objects = draggingInfo.draggingPasteboard.readObjects(
                forClasses: [NSURL.self],
                options: [.urlReadingFileURLsOnly: true]
            ) as? [URL]
            guard let urls = objects, !urls.isEmpty else { return false }
            parent.onDrop(urls, items[indexPath.item].url)
            return true
        }

        func selectedItems() -> [FileItem] {
            guard let collectionView else { return [] }
            return collectionView.selectionIndexPaths.compactMap { path in
                items.indices.contains(path.item) ? items[path.item] : nil
            }
        }

        private func publishSelection(from collectionView: NSCollectionView) {
            guard !isApplyingSelection else { return }
            parent.onFocus()
            parent.onSelection(Set(collectionView.selectionIndexPaths.compactMap { path in
                items.indices.contains(path.item) ? items[path.item].id : nil
            }))
        }

        private func applySelection(_ selection: Set<FileItem.ID>, in collectionView: NSCollectionView) {
            let paths = Set(selection.compactMap { id -> IndexPath? in
                indexByID[id].map { IndexPath(item: $0, section: 0) }
            })
            guard paths != collectionView.selectionIndexPaths else { return }
            isApplyingSelection = true
            collectionView.selectionIndexPaths = paths
            isApplyingSelection = false
        }
    }
}

private final class FileGridCollectionItem: NSCollectionViewItem {
    static let reuseIdentifier = NSUserInterfaceItemIdentifier("FileGridCollectionItem")
    private let iconView = NSImageView()
    private let nameLabel = NSTextField(wrappingLabelWithString: "")
    private let badge = NSTextField(labelWithString: "")
    private var loadToken = UUID()
    private var onOpen: () -> Void = {}

    override func loadView() {
        let container = NSView()
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.translatesAutoresizingMaskIntoConstraints = false
        nameLabel.alignment = .center
        nameLabel.maximumNumberOfLines = 2
        nameLabel.lineBreakMode = .byTruncatingMiddle
        nameLabel.font = .systemFont(ofSize: 11)
        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        badge.font = .systemFont(ofSize: 9, weight: .bold)
        badge.alignment = .center
        badge.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(iconView)
        container.addSubview(badge)
        container.addSubview(nameLabel)
        NSLayoutConstraint.activate([
            iconView.topAnchor.constraint(equalTo: container.topAnchor, constant: 6),
            iconView.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 72),
            iconView.heightAnchor.constraint(equalToConstant: 72),
            badge.topAnchor.constraint(equalTo: iconView.topAnchor),
            badge.leadingAnchor.constraint(equalTo: iconView.leadingAnchor),
            badge.widthAnchor.constraint(equalToConstant: 14),
            badge.heightAnchor.constraint(equalToConstant: 14),
            nameLabel.topAnchor.constraint(equalTo: iconView.bottomAnchor, constant: 4),
            nameLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 2),
            nameLabel.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -2)
        ])
        view = container
    }

    func update(item: FileItem, gitChange: GitFileChange.ChangeType?, onOpen: @escaping () -> Void) {
        self.onOpen = onOpen
        nameLabel.stringValue = item.name
        iconView.image = IconCache.shared.icon(for: item)
        if let gitChange {
            badge.stringValue = gitChange == .untracked ? "?" : String(describing: gitChange).prefix(1).uppercased()
            badge.isHidden = false
        } else {
            badge.isHidden = true
        }
        let token = UUID()
        loadToken = token
        let url = item.url
        let isDirectory = item.isDirectory
        let isPackage = item.isPackage
        let date = item.modificationDate
        Task { @MainActor in
            let image = await ThumbnailCache.shared.image(
                for: url,
                size: CGSize(width: 72, height: 72),
                modificationDate: date,
                isDirectory: isDirectory,
                isPackage: isPackage
            )
            guard loadToken == token else { return }
            iconView.image = image
        }
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            onOpen()
            return
        }
        super.mouseDown(with: event)
    }
}
