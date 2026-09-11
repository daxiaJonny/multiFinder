import SwiftUI

/// Compact Git branch capsule rendered in PathBarView breadcrumb bar.
struct GitPulseBadgeView: View {
    let status: GitStatusInfo
    var isCompact: Bool = false
    let onFocus: () -> Void

    @State private var isPopoverPresented = false

    var body: some View {
        Button {
            onFocus()
            isPopoverPresented.toggle()
        } label: {
            HStack(spacing: 3) {
                Image(systemName: "arrow.triangle.branch")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(status.isClean ? .green : .orange)

                Text(status.badgeTitle)
                    .font(.system(size: 10, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: isCompact ? 55 : 85, alignment: .leading)

                if status.totalChanges > 0 {
                    HStack(spacing: 1) {
                        Text("*")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.orange)
                        Text("\(status.totalChanges)")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                }

                if status.aheadCount > 0 {
                    Text("↑\(status.aheadCount)")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(MFDTheme.primaryAccent)
                }
            }
            .fixedSize(horizontal: true, vertical: false)
            .padding(.horizontal, 6)
            .padding(.vertical, 2.5)
            .background(
                Capsule()
                    .fill(Color.primary.opacity(0.06))
                    .overlay(
                        Capsule()
                            .stroke(
                                status.isClean
                                    ? Color.green.opacity(0.25)
                                    : Color.orange.opacity(0.35),
                                lineWidth: 0.8
                            )
                    )
            )
            .foregroundStyle(.primary)
        }
        .buttonStyle(.plain)
        .popover(isPresented: $isPopoverPresented, arrowEdge: .bottom) {
            GitPulsePopoverView(status: status) {
                isPopoverPresented = false
            }
        }
        .help(tooltipText)
    }

    private var tooltipText: String {
        var parts: [String] = ["Git Branch: \(status.branch)"]
        if status.totalChanges > 0 {
            parts.append("\(status.totalChanges) uncommitted changes")
        } else {
            parts.append("Clean working tree")
        }
        if status.aheadCount > 0 {
            parts.append("Ahead: \(status.aheadCount)")
        }
        if status.behindCount > 0 {
            parts.append("Behind: \(status.behindCount)")
        }
        parts.append("Click to inspect commits and changes")
        return parts.joined(separator: " · ")
    }
}
