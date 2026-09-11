import AppKit
import SwiftUI

struct WorkspaceLayoutView: View {
    @ObservedObject var layoutManager: LayoutManager
    @ObservedObject var focusedPane: FileBrowserViewModel

    private let dividerThickness: Double = 8

    var body: some View {
        GeometryReader { geometry in
            HStack(spacing: 0) {
                if layoutManager.isSidebarVisible {
                    SidebarView(
                        currentLocation: focusedPane.location,
                        onNavigate: focusedPane.navigate,
                        onRecents: focusedPane.loadRecents
                    )
                    .frame(width: layoutManager.sidebarWidth)

                    SplitResizeHandle(axis: .vertical) { delta in
                        layoutManager.resizeSidebar(to: layoutManager.sidebarWidth + delta)
                    } onCommit: {
                        layoutManager.save()
                    }
                    .zIndex(50)
                }

                rowLayout(size: geometry.size)
            }
        }
    }

    private func rowLayout(size: CGSize) -> some View {
        let dividerSpace = dividerThickness * Double(max(layoutManager.rows.count - 1, 0))
        let availableHeight = max(size.height - dividerSpace, 1)
        let totalWeight = max(layoutManager.rows.map(\.heightWeight).reduce(0, +), 0.01)
        let sidebarSpace = layoutManager.isSidebarVisible
            ? layoutManager.sidebarWidth + dividerThickness
            : 0
        let contentWidth = max(size.width - sidebarSpace, 1)

        return VStack(spacing: 0) {
            ForEach(Array(layoutManager.rows.enumerated()), id: \.element.id) { rowIndex, row in
                let isRowFocused = row.panes.contains { $0.id == layoutManager.focusedPaneID }
                paneLayout(
                    row: row,
                    rowIndex: rowIndex,
                    width: contentWidth,
                    height: availableHeight * row.heightWeight / totalWeight
                )
                .zIndex(isRowFocused ? 10 : 1)

                if rowIndex < layoutManager.rows.count - 1 {
                    SplitResizeHandle(axis: .horizontal) { delta in
                        layoutManager.resizeRow(
                            dividerIndex: rowIndex,
                            delta: delta,
                            availableHeight: availableHeight
                        )
                    } onCommit: {
                        layoutManager.save()
                    }
                    .zIndex(50)
                }
            }
        }
        .frame(width: contentWidth, height: size.height, alignment: .topLeading)
    }

    private func paneLayout(row: PaneRow, rowIndex: Int, width: Double, height: Double) -> some View {
        let dividerSpace = dividerThickness * Double(max(row.panes.count - 1, 0))
        let availableWidth = max(width - dividerSpace, 1)
        let totalWeight = max(row.paneWeights.reduce(0, +), 0.01)

        return HStack(spacing: 0) {
            ForEach(Array(row.panes.enumerated()), id: \.element.id) { paneIndex, pane in
                let isPaneFocused = layoutManager.focusedPaneID == pane.id
                FileBrowserPane(
                    pane: pane,
                    layoutManager: layoutManager,
                    isFocused: isPaneFocused,
                    isHighlighted: layoutManager.highlightedPaneID == pane.id,
                    onFocus: { layoutManager.focusedPaneID = pane.id }
                )
                .padding(3)
                .frame(
                    width: availableWidth * row.paneWeights[paneIndex] / totalWeight,
                    height: height
                )
                .zIndex(isPaneFocused ? 10 : 1)

                if paneIndex < row.panes.count - 1 {
                    SplitResizeHandle(axis: .vertical) { delta in
                        layoutManager.resizePane(
                            rowIndex: rowIndex,
                            dividerIndex: paneIndex,
                            delta: delta,
                            availableWidth: availableWidth
                        )
                    } onCommit: {
                        layoutManager.save()
                    }
                    .zIndex(50)
                }
            }
        }
        .frame(width: width, height: height, alignment: .topLeading)
    }
}

private struct SplitResizeHandle: View {
    enum Axis {
        case vertical
        case horizontal
    }

    let axis: Axis
    let onDelta: (Double) -> Void
    let onCommit: () -> Void

    @State private var isHovering = false
    @State private var isDragging = false
    @State private var previousTranslation: Double = 0

    var body: some View {
        ZStack {
            CursorRectView(cursor: cursor)
                .allowsHitTesting(false)

            // Hit testing target (comfortably sized at 9 points)
            Color.black.opacity(0.0001)
                .frame(
                    width: axis == .vertical ? 9 : nil,
                    height: axis == .horizontal ? 9 : nil
                )

            // Visual hairline with luminous accent glow on hover / drag
            Rectangle()
                .fill(
                    isDragging
                        ? MFDTheme.primaryAccent
                        : (isHovering ? MFDTheme.primaryAccent.opacity(0.9) : MFDTheme.subtleHairline)
                )
                .frame(
                    width: axis == .vertical ? (isDragging ? 3 : (isHovering ? 2.5 : 1)) : nil,
                    height: axis == .horizontal ? (isDragging ? 3 : (isHovering ? 2.5 : 1)) : nil
                )
                .shadow(
                    color: (isHovering || isDragging) ? MFDTheme.primaryAccent.opacity(0.45) : Color.clear,
                    radius: isDragging ? 4 : 2.5,
                    x: 0,
                    y: 0
                )
        }
        .frame(
            width: axis == .vertical ? 8 : nil,
            height: axis == .horizontal ? 8 : nil
        )
        .contentShape(Rectangle())
        .onContinuousHover { phase in
            switch phase {
            case .active:
                isHovering = true
                cursor.set()
            case .ended:
                isHovering = false
                if !isDragging {
                    NSCursor.arrow.set()
                }
            }
        }
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    if !isDragging {
                        isDragging = true
                        cursor.push()
                    }
                    let translation = axis == .vertical
                        ? value.translation.width
                        : value.translation.height
                    onDelta(translation - previousTranslation)
                    previousTranslation = translation
                }
                .onEnded { _ in
                    if isDragging {
                        isDragging = false
                        NSCursor.pop()
                    }
                    previousTranslation = 0
                    onCommit()
                }
        )
        .animation(.easeInOut(duration: 0.12), value: isHovering)
        .animation(.easeInOut(duration: 0.12), value: isDragging)
        .accessibilityLabel(resizeLabel)
        .accessibilityHint("Drag to resize")
        .help(resizeLabel)
    }

    private var cursor: NSCursor {
        axis == .vertical ? .resizeLeftRight : .resizeUpDown
    }

    private var resizeLabel: String {
        axis == .vertical
            ? L10n.string("Resize Columns")
            : L10n.string("Resize Rows")
    }
}

// MARK: - Native AppKit Cursor Bridge

private struct CursorRectView: NSViewRepresentable {
    let cursor: NSCursor

    func makeNSView(context: Context) -> CursorHostingNSView {
        let view = CursorHostingNSView()
        view.cursor = cursor
        return view
    }

    func updateNSView(_ nsView: CursorHostingNSView, context: Context) {
        nsView.cursor = cursor
    }
}

private final class CursorHostingNSView: NSView {
    var cursor: NSCursor = .arrow {
        didSet {
            window?.invalidateCursorRects(for: self)
        }
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: cursor)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas {
            removeTrackingArea(area)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.cursorUpdate, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
    }

    override func cursorUpdate(with event: NSEvent) {
        cursor.set()
    }
}

