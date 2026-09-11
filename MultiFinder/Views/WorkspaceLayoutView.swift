import AppKit
import SwiftUI

struct WorkspaceLayoutView: View {
    @ObservedObject var layoutManager: LayoutManager
    @ObservedObject var focusedPane: FileBrowserViewModel

    private let dividerThickness: Double = 7

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
                paneLayout(
                    row: row,
                    rowIndex: rowIndex,
                    width: contentWidth,
                    height: availableHeight * row.heightWeight / totalWeight
                )

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
                FileBrowserPane(
                    pane: pane,
                    layoutManager: layoutManager,
                    isFocused: layoutManager.focusedPaneID == pane.id,
                    isHighlighted: layoutManager.highlightedPaneID == pane.id,
                    onFocus: { layoutManager.focusedPaneID = pane.id }
                )
                .padding(3)
                .frame(
                    width: availableWidth * row.paneWeights[paneIndex] / totalWeight,
                    height: height
                )

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
            Color.clear
                .frame(
                    width: axis == .vertical ? 7 : nil,
                    height: axis == .horizontal ? 7 : nil
                )

            Rectangle()
                .fill(
                    isDragging
                        ? MFDTheme.primaryAccent
                        : (isHovering ? MFDTheme.primaryAccent.opacity(0.7) : MFDTheme.subtleHairline)
                )
                .frame(
                    width: axis == .vertical ? (isHovering || isDragging ? 2 : 1) : nil,
                    height: axis == .horizontal ? (isHovering || isDragging ? 2 : 1) : nil
                )
        }
        .frame(
            width: axis == .vertical ? 7 : nil,
            height: axis == .horizontal ? 7 : nil
        )
        .contentShape(Rectangle())
        .onHover { hovering in
            isHovering = hovering
            if hovering {
                cursor.push()
            } else {
                NSCursor.pop()
            }
        }
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    isDragging = true
                    let translation = axis == .vertical
                        ? value.translation.width
                        : value.translation.height
                    onDelta(translation - previousTranslation)
                    previousTranslation = translation
                }
                .onEnded { _ in
                    isDragging = false
                    previousTranslation = 0
                    onCommit()
                }
        )
        .animation(.easeInOut(duration: 0.15), value: isHovering)
        .animation(.easeInOut(duration: 0.15), value: isDragging)
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

