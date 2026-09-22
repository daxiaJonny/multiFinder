import AppKit
import SwiftUI

/// Finder-style list: NSTableView creates cells only for visible rows and reuses them.
struct VirtualFileTable: NSViewRepresentable {
    let items: [FileItem]
    let itemsRevision: UInt64
    let selection: Set<FileItem.ID>
    let sortOrder: [FileItemComparator]
    let gitIndex: GitChangeIndex?
    let gitGeneration: UInt64
    var showsMetadataColumns: Bool = true
    var onGoUp: (() -> Void)? = nil
    let onSelection: (Set<FileItem.ID>) -> Void
    let onSort: ([FileItemComparator]) -> Void
    let onOpen: (FileItem) -> Void
    let onBeginRename: () -> Void
    let onFocus: () -> Void
    let onQuickLook: () -> Void
    let onBeginFiltering: () -> Void
    let onDelete: () -> Void
    let onDrop: ([URL], URL) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .textBackgroundColor
        scrollView.borderType = .noBorder

        let table = VirtualFileTableView()
        table.coordinator = context.coordinator
        context.coordinator.tableView = table
        table.style = .plain
        table.rowHeight = 22
        table.usesAutomaticRowHeights = false
        table.intercellSpacing = NSSize(width: 8, height: 2)
        table.backgroundColor = .textBackgroundColor
        table.gridStyleMask = []
        table.usesAlternatingRowBackgroundColors = false
        table.allowsMultipleSelection = true
        table.allowsEmptySelection = true
        table.allowsColumnReordering = true
        table.allowsColumnResizing = true
        table.allowsColumnSelection = false
        table.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        table.headerView = NSTableHeaderView()
        table.focusRingType = .none
        table.doubleAction = #selector(Coordinator.openClickedRow)
        table.target = context.coordinator
        table.dataSource = context.coordinator
        table.delegate = context.coordinator
        table.registerForDraggedTypes([.fileURL])

        for column in Self.makeColumns(includingMetadata: context.coordinator.parent.showsMetadataColumns) {
            table.addTableColumn(column)
        }
        scrollView.documentView = table
        context.coordinator.apply(self)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.apply(self)
    }

    private static func makeColumns(includingMetadata: Bool) -> [NSTableColumn] {
        let name = column("name", title: "Name", width: 220, min: 120)
        name.resizingMask = .autoresizingMask
        guard includingMetadata else { return [name] }
        let date = column("date", title: "Date Modified", width: 150, min: 110)
        let size = column("size", title: "Size", width: 80, min: 56)
        let kind = column("kind", title: "Kind", width: 120, min: 70)
        return [name, date, size, kind]
    }

    private static func column(_ id: String, title: String, width: CGFloat, min: CGFloat) -> NSTableColumn {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
        column.title = title
        column.width = width
        column.minWidth = min
        column.sortDescriptorPrototype = NSSortDescriptor(key: id, ascending: true)
        return column
    }
}

final class VirtualFileTableView: NSTableView {
    weak var coordinator: VirtualFileTable.Coordinator?

    override func rightMouseDown(with event: NSEvent) {
        let row = row(at: convert(event.locationInWindow, from: nil))
        if row >= 0 {
            if !selectedRowIndexes.contains(row) {
                selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            }
        } else {
            deselectAll(nil)
        }
        coordinator?.parent.onFocus()
        super.rightMouseDown(with: event)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        enclosingScrollView?.menu ?? super.menu(for: event)
    }

    override func keyDown(with event: NSEvent) {
        coordinator?.parent.onFocus()
        let characters = event.charactersIgnoringModifiers ?? ""
        if characters == "/" , !event.modifierFlags.contains(.command) {
            coordinator?.parent.onBeginFiltering()
            return
        }
        if event.keyCode == 49 {
            coordinator?.parent.onQuickLook()
            return
        }
        if event.keyCode == 36 || event.keyCode == 76 {
            coordinator?.parent.onBeginRename()
            return
        }
        if event.keyCode == 51, event.modifierFlags.contains(.command) {
            coordinator?.parent.onDelete()
            return
        }
        if characters == "o", event.modifierFlags.contains(.command) {
            coordinator?.selectedItems().forEach { coordinator?.parent.onOpen($0) }
            return
        }
        if event.keyCode == 124,
           event.modifierFlags.intersection([.command, .shift, .option, .control]).isEmpty,
           coordinator?.parent.showsMetadataColumns == false,
           let item = coordinator?.selectedItems().first,
           item.isDirectory,
           !item.isPackage {
            coordinator?.parent.onOpen(item)
            return
        }
        if event.keyCode == 123,
           event.modifierFlags.intersection([.command, .shift, .option, .control]).isEmpty,
           coordinator?.parent.showsMetadataColumns == false {
            coordinator?.parent.onGoUp?()
            return
        }
        super.keyDown(with: event)
    }
}

extension VirtualFileTable {
    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        var parent: VirtualFileTable
        weak var tableView: VirtualFileTableView?
        private var items: [FileItem] = []
        private var gitIndex: GitChangeIndex?
        private var appliedItemsRevision: UInt64 = .max
        private var appliedGitGeneration: UInt64 = .max
        private var isApplyingSelection = false

        init(parent: VirtualFileTable) {
            self.parent = parent
        }

        func apply(_ parent: VirtualFileTable) {
            self.parent = parent
            guard let tableView else { return }
            if parent.itemsRevision == appliedItemsRevision, parent.gitGeneration == appliedGitGeneration {
                applySelection(parent.selection, in: tableView)
                applySortIndicator(parent.sortOrder, in: tableView)
                return
            }
            let idsChanged = !items.elementsEqual(parent.items) { $0.id == $1.id }
            let contentChanged = items != parent.items
            let gitChanged = gitIndex != parent.gitIndex
            items = parent.items
            gitIndex = parent.gitIndex
            appliedItemsRevision = parent.itemsRevision
            appliedGitGeneration = parent.gitGeneration
            if idsChanged {
                let origin = tableView.enclosingScrollView?.contentView.bounds.origin
                tableView.reloadData()
                if let origin {
                    tableView.enclosingScrollView?.contentView.setBoundsOrigin(origin)
                    tableView.enclosingScrollView?.reflectScrolledClipView(tableView.enclosingScrollView!.contentView)
                }
            } else if contentChanged || gitChanged {
                let rows = tableView.rows(in: tableView.visibleRect)
                if rows.length > 0 {
                    let range = rows.location..<(rows.location + rows.length)
                    tableView.reloadData(
                        forRowIndexes: IndexSet(integersIn: range),
                        columnIndexes: IndexSet(integersIn: 0..<tableView.numberOfColumns)
                    )
                }
            }
            applySelection(parent.selection, in: tableView)
            applySortIndicator(parent.sortOrder, in: tableView)
        }

        func numberOfRows(in tableView: NSTableView) -> Int { items.count }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard items.indices.contains(row), let tableColumn else { return nil }
            let item = items[row]
            let identifier = tableColumn.identifier
            if identifier.rawValue == "name" {
                let cell = (tableView.makeView(withIdentifier: identifier, owner: self) as? NameCell) ?? NameCell()
                cell.identifier = identifier
                cell.update(item: item, gitChange: gitIndex?.changeType(for: item.url))
                return cell
            }
            let cell = (tableView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView) ?? NSTableCellView()
            cell.identifier = identifier
            if cell.textField == nil {
                let label = NSTextField(labelWithString: "")
                label.lineBreakMode = .byTruncatingTail
                label.textColor = .secondaryLabelColor
                label.translatesAutoresizingMaskIntoConstraints = false
                cell.addSubview(label)
                cell.textField = label
                NSLayoutConstraint.activate([
                    label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                    label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -2),
                    label.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
                ])
            }
            cell.textField?.stringValue = Self.detailText(for: item, column: identifier.rawValue)
            return cell
        }

        func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> (any NSPasteboardWriting)? {
            guard items.indices.contains(row) else { return nil }
            return items[row].url as NSURL
        }

        func tableView(
            _ tableView: NSTableView,
            validateDrop info: any NSDraggingInfo,
            proposedRow row: Int,
            proposedDropOperation operation: NSTableView.DropOperation
        ) -> NSDragOperation {
            guard operation == .on, items.indices.contains(row), items[row].isDirectory, !items[row].isPackage else {
                return []
            }
            guard !Self.droppedURLs(from: info).isEmpty else { return [] }
            tableView.setDropRow(row, dropOperation: .on)
            return info.draggingSourceOperationMask.contains(.move) ? .move : .copy
        }

        func tableView(
            _ tableView: NSTableView,
            acceptDrop info: any NSDraggingInfo,
            row: Int,
            dropOperation: NSTableView.DropOperation
        ) -> Bool {
            guard dropOperation == .on, items.indices.contains(row) else { return false }
            let urls = Self.droppedURLs(from: info)
            guard !urls.isEmpty else { return false }
            parent.onDrop(urls, items[row].url)
            return true
        }

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !isApplyingSelection, let tableView else { return }
            parent.onFocus()
            parent.onSelection(Set(tableView.selectedRowIndexes.compactMap { index in
                items.indices.contains(index) ? items[index].id : nil
            }))
        }

        func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
            guard let descriptor = tableView.sortDescriptors.first,
                  let field = SortField(columnID: descriptor.key) else { return }
            parent.onSort([
                FileItemComparator(field: field, order: descriptor.ascending ? .forward : .reverse)
            ])
        }

        @objc func openClickedRow() {
            guard let tableView, tableView.clickedRow >= 0, items.indices.contains(tableView.clickedRow) else { return }
            parent.onFocus()
            parent.onOpen(items[tableView.clickedRow])
        }

        func clickedItem() -> FileItem? {
            guard let tableView, items.indices.contains(tableView.clickedRow) else { return nil }
            return items[tableView.clickedRow]
        }

        func selectedItems() -> [FileItem] {
            guard let tableView else { return [] }
            return tableView.selectedRowIndexes.compactMap { items.indices.contains($0) ? items[$0] : nil }
        }

        private func applySelection(_ selection: Set<FileItem.ID>, in tableView: NSTableView) {
            let indexes = IndexSet(items.indices.filter { selection.contains(items[$0].id) })
            guard indexes != tableView.selectedRowIndexes else { return }
            isApplyingSelection = true
            tableView.selectRowIndexes(indexes, byExtendingSelection: false)
            isApplyingSelection = false
        }

        private func applySortIndicator(_ sortOrder: [FileItemComparator], in tableView: NSTableView) {
            guard let comparator = sortOrder.first else { return }
            let descriptor = NSSortDescriptor(
                key: comparator.field.columnID,
                ascending: comparator.order != .reverse
            )
            if tableView.sortDescriptors.first?.key == descriptor.key,
               tableView.sortDescriptors.first?.ascending == descriptor.ascending {
                return
            }
            tableView.sortDescriptors = [descriptor]
        }

        private static func detailText(for item: FileItem, column: String) -> String {
            switch column {
            case "date":
                return Self.dateFormatter.string(from: item.modificationDate)
            case "size":
                return item.isDirectory ? "--" : Self.sizeFormatter.string(fromByteCount: item.size)
            case "kind":
                return item.kind
            default:
                return ""
            }
        }

        private static func droppedURLs(from info: any NSDraggingInfo) -> [URL] {
            let objects = info.draggingPasteboard.readObjects(
                forClasses: [NSURL.self],
                options: [.urlReadingFileURLsOnly: true]
            ) as? [URL]
            return objects ?? []
        }

        private static let dateFormatter: DateFormatter = {
            let formatter = DateFormatter()
            formatter.dateStyle = .short
            formatter.timeStyle = .short
            return formatter
        }()

        private static let sizeFormatter: ByteCountFormatter = {
            let formatter = ByteCountFormatter()
            formatter.countStyle = .file
            return formatter
        }()
    }
}

private final class NameCell: NSTableCellView {
    private let badge = NSTextField(labelWithString: "")
    private var badgeWidth: NSLayoutConstraint?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        let icon = NSImageView()
        let label = NSTextField(labelWithString: "")
        label.lineBreakMode = .byTruncatingMiddle
        icon.translatesAutoresizingMaskIntoConstraints = false
        badge.translatesAutoresizingMaskIntoConstraints = false
        label.translatesAutoresizingMaskIntoConstraints = false
        badge.font = .systemFont(ofSize: 9, weight: .bold)
        badge.alignment = .center
        badge.wantsLayer = true
        badge.layer?.cornerRadius = 7
        addSubview(icon)
        addSubview(badge)
        addSubview(label)
        imageView = icon
        textField = label
        let width = badge.widthAnchor.constraint(equalToConstant: 0)
        badgeWidth = width
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 16),
            icon.heightAnchor.constraint(equalToConstant: 16),
            badge.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 4),
            badge.centerYAnchor.constraint(equalTo: centerYAnchor),
            badge.heightAnchor.constraint(equalToConstant: 14),
            width,
            label.leadingAnchor.constraint(equalTo: badge.trailingAnchor, constant: 4),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            label.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    required init?(coder: NSCoder) { nil }

    func update(item: FileItem, gitChange: GitFileChange.ChangeType?) {
        imageView?.image = IconCache.shared.icon(for: item)
        textField?.stringValue = item.name
        if let gitChange {
            badge.stringValue = Self.symbol(for: gitChange)
            badge.textColor = Self.color(for: gitChange)
            badge.isHidden = false
            badgeWidth?.constant = 14
        } else {
            badge.stringValue = ""
            badge.isHidden = true
            badgeWidth?.constant = 0
        }
    }

    private static func symbol(for change: GitFileChange.ChangeType) -> String {
        switch change {
        case .modified: return "M"
        case .added: return "A"
        case .deleted: return "D"
        case .renamed: return "R"
        case .untracked: return "?"
        case .other: return "•"
        }
    }

    private static func color(for change: GitFileChange.ChangeType) -> NSColor {
        switch change {
        case .modified: return .systemOrange
        case .added: return .systemGreen
        case .deleted: return .systemRed
        case .renamed: return .systemBlue
        case .untracked, .other: return .secondaryLabelColor
        }
    }
}

private extension SortField {
    init?(columnID: String?) {
        switch columnID {
        case "name": self = .name
        case "date": self = .date
        case "size": self = .size
        case "kind": self = .kind
        default: return nil
        }
    }

    var columnID: String {
        switch self {
        case .name: return "name"
        case .date: return "date"
        case .size: return "size"
        case .kind: return "kind"
        }
    }
}
