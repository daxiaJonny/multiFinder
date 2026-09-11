import AppKit
import SwiftUI

/// Rich popover displaying Git status details, modified files, and recent commit history.
struct GitPulsePopoverView: View {
    let status: GitStatusInfo
    let onDismiss: () -> Void

    @State private var recentCommits: [GitCommitInfo] = []
    @State private var isLoadingCommits = false
    @State private var selectedTab = 0 // 0: Changes, 1: Commits
    @State private var copiedText: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Header
            HStack(spacing: 8) {
                Image(systemName: "arrow.triangle.branch")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(MFDTheme.primaryAccent)

                Text(status.branch)
                    .font(.system(size: 13, weight: .bold))
                    .lineLimit(1)

                Button {
                    copyToClipboard(status.branch, message: "Branch copied")
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help(L10n.string("Copy Branch Name"))

                Spacer()

                if let upstream = status.upstream {
                    HStack(spacing: 4) {
                        Text(upstream)
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)

                        if status.aheadCount > 0 {
                            Text("↑\(status.aheadCount)")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(MFDTheme.primaryAccent)
                        }
                        if status.behindCount > 0 {
                            Text("↓\(status.behindCount)")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(.orange)
                        }
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        Capsule()
                            .fill(Color.primary.opacity(0.06))
                    )
                }
            }

            // Tab Switcher
            Picker("", selection: $selectedTab) {
                Text("\(L10n.string("Changes")) (\(status.totalChanges))").tag(0)
                Text(L10n.string("Recent Commits")).tag(1)
            }
            .pickerStyle(.segmented)

            // Content
            Group {
                if selectedTab == 0 {
                    changesList
                } else {
                    commitsList
                }
            }
            .frame(height: 180)

            Divider()
                .background(MFDTheme.subtleHairline)

            // Footer
            HStack(spacing: 8) {
                if let copied = copiedText {
                    Text(copied)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(MFDTheme.primaryAccent)
                }

                Spacer()

                Button {
                    GitPulseStore.shared.refresh(for: status.repoRootURL, force: true)
                    loadCommits()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 11))
                }
                .buttonStyle(.plain)
                .help(L10n.string("Refresh Git Status"))

                Button {
                    try? TerminalService.shared.openDirectory(status.repoRootURL)
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "terminal")
                            .font(.system(size: 10))
                        Text(L10n.string("Open in Terminal"))
                            .font(.system(size: 11))
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(Color.primary.opacity(0.08))
                    )
                }
                .buttonStyle(.plain)
                .help(L10n.string("Open repository in Terminal"))
            }
        }
        .padding(12)
        .frame(width: 380)
        .task {
            loadCommits()
        }
    }

    // MARK: - Changes List

    private var changesList: some View {
        Group {
            if status.changedFiles.isEmpty {
                VStack(spacing: 6) {
                    Spacer()
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 20))
                        .foregroundStyle(.green)
                    Text(L10n.string("Working tree clean"))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        ForEach(status.changedFiles) { file in
                            HStack(spacing: 6) {
                                Text(file.type.rawValue)
                                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                                    .frame(width: 16, height: 16)
                                    .background(
                                        RoundedRectangle(cornerRadius: 3)
                                            .fill(badgeColor(for: file.type).opacity(0.2))
                                    )
                                    .foregroundStyle(badgeColor(for: file.type))

                                Text(file.path)
                                    .font(.system(size: 11, design: .monospaced))
                                    .lineLimit(1)
                                    .truncationMode(.middle)

                                Spacer()
                            }
                            .padding(.vertical, 2)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Commits List

    private var commitsList: some View {
        Group {
            if isLoadingCommits {
                VStack {
                    Spacer()
                    ProgressView()
                        .scaleEffect(0.8)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else if recentCommits.isEmpty {
                VStack {
                    Spacer()
                    Text(L10n.string("No commit history found"))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(recentCommits) { commit in
                            HStack(alignment: .top, spacing: 6) {
                                Button {
                                    copyToClipboard(commit.hash, message: "Hash \(commit.hash) copied")
                                } label: {
                                    Text(commit.hash)
                                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                                        .padding(.horizontal, 5)
                                        .padding(.vertical, 2)
                                        .background(
                                            RoundedRectangle(cornerRadius: 4)
                                                .fill(Color.primary.opacity(0.08))
                                        )
                                        .foregroundStyle(MFDTheme.primaryAccent)
                                }
                                .buttonStyle(.plain)
                                .help(L10n.string("Copy Commit Hash"))

                                VStack(alignment: .leading, spacing: 2) {
                                    Text(commit.summary)
                                        .font(.system(size: 11, weight: .medium))
                                        .lineLimit(2)

                                    HStack(spacing: 4) {
                                        Text(commit.author)
                                            .font(.system(size: 10))
                                            .foregroundStyle(.secondary)
                                        Text("·")
                                            .foregroundStyle(.tertiary)
                                        Text(commit.relativeTime)
                                            .font(.system(size: 10))
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                Spacer()
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: - Helpers

    private func loadCommits() {
        isLoadingCommits = true
        Task {
            let commits = await GitPulseStore.shared.fetchRecentCommits(for: status.repoRootURL)
            await MainActor.run {
                self.recentCommits = commits
                self.isLoadingCommits = false
            }
        }
    }

    private func badgeColor(for type: GitFileChange.ChangeType) -> Color {
        switch type {
        case .modified: return .orange
        case .added: return .green
        case .deleted: return .red
        case .untracked: return .purple
        case .renamed: return .blue
        case .other: return .secondary
        }
    }

    private func copyToClipboard(_ text: String, message: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        withAnimation {
            copiedText = message
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            withAnimation {
                if self.copiedText == message {
                    self.copiedText = nil
                }
            }
        }
    }
}
