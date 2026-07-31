import SwiftUI

struct AIInputBar: View {
    @ObservedObject var viewModel: FileBrowserViewModel

    @State private var question = ""
    @FocusState private var isFieldFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            if hasConversationContent {
                Divider()

                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(viewModel.aiConversation) { exchange in
                            exchangeView(exchange)
                        }

                        if let pendingQuestion = viewModel.aiPendingQuestion {
                            pendingView(pendingQuestion)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                }
                .frame(minHeight: 70, maxHeight: 220)
            }

            if let message = viewModel.aiAssistantErrorMessage {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(3)
                    .padding(.horizontal, 10)
                    .padding(.bottom, 6)
            }

            Divider()
            composer
        }
        .background(Color(nsColor: .underPageBackgroundColor))
        .onAppear { isFieldFocused = true }
        .onExitCommand { viewModel.toggleAIAssistant() }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "sparkles")
                .foregroundStyle(.secondary)
            Text(viewModel.currentURL?.lastPathComponent ?? L10n.string("Current Folder"))
                .font(.system(size: 11, weight: .medium))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()

            if !viewModel.aiConversation.isEmpty {
                Button(action: viewModel.clearAIConversation) {
                    Image(systemName: "trash")
                }
                .buttonStyle(.plain)
                .help("Clear Conversation")
            }

            Button(action: viewModel.toggleAIAssistant) {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
            .help("Close")
        }
        .font(.system(size: 10))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    private var composer: some View {
        HStack(spacing: 6) {
            Image(systemName: "bubble.left")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            TextField("Ask about the current folder…", text: $question)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .focused($isFieldFocused)
                .onSubmit(submit)
                .disabled(viewModel.isAIAnswering)

            if viewModel.isAIAnswering {
                ProgressView()
                    .controlSize(.small)
                Button(action: viewModel.cancelAIAnswering) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Cancel")
            } else {
                Button(action: submit) {
                    Image(systemName: "arrow.up.circle.fill")
                        .foregroundStyle(questionIsEmpty ? Color.secondary : Color.accentColor)
                }
                .buttonStyle(.plain)
                .disabled(questionIsEmpty)
                .help("Ask")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
    }

    private var hasConversationContent: Bool {
        !viewModel.aiConversation.isEmpty || viewModel.aiPendingQuestion != nil
    }

    private var questionIsEmpty: Bool {
        question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func exchangeView(_ exchange: AIAssistantExchange) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "person.crop.circle")
                    .foregroundStyle(.tertiary)
                Text(exchange.question)
                    .foregroundStyle(.secondary)
            }
            .font(.system(size: 11))

            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "sparkles")
                    .foregroundStyle(Color.accentColor)
                markdownText(exchange.answer)
            }
            .font(.system(size: 12))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func pendingView(_ pendingQuestion: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            ProgressView()
                .controlSize(.small)
            Text(pendingQuestion)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
    }

    private func markdownText(_ text: String) -> some View {
        let attributed = (try? AttributedString(markdown: text)) ?? AttributedString(text)
        return Text(attributed)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func submit() {
        let submitted = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !submitted.isEmpty else { return }
        question = ""
        viewModel.submitAIQuestion(submitted)
    }
}

struct FileSearchSheet: View {
    @ObservedObject var viewModel: FileBrowserViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var query = ""
    @State private var searchCurrentFolder: Bool
    @FocusState private var isFieldFocused: Bool

    init(viewModel: FileBrowserViewModel) {
        self.viewModel = viewModel
        _searchCurrentFolder = State(initialValue: viewModel.currentURL != nil)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.title2)
                    .foregroundStyle(.secondary)
                Text("Search")
                    .font(.headline)
            }

            TextField("Enter a file name or file contents", text: $query)
                .textFieldStyle(.roundedBorder)
                .focused($isFieldFocused)
                .onSubmit(runSearch)

            if let currentURL = viewModel.currentURL {
                Toggle("Search Current Folder Only", isOn: $searchCurrentFolder)
                    .toggleStyle(.checkbox)
                Text(currentURL.path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Search", action: runSearch)
                    .keyboardShortcut(.defaultAction)
                    .disabled(query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 440)
        .onAppear { isFieldFocused = true }
    }

    private func runSearch() {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let scope = searchCurrentFolder ? viewModel.currentURL : nil
        dismiss()
        viewModel.search(for: trimmed, in: scope)
    }
}

struct AIOrganizeFlowSheet: View {
    @ObservedObject var viewModel: FileBrowserViewModel

    var body: some View {
        if let preview = viewModel.aiPlanPreview {
            AIPlanPreviewSheet(preview: preview, viewModel: viewModel)
        } else {
            AIOrganizePromptView(viewModel: viewModel)
        }
    }
}

private struct AIOrganizePromptView: View {
    @ObservedObject var viewModel: FileBrowserViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var instruction = ""
    @FocusState private var isFieldFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 8) {
                Image(systemName: "wand.and.stars")
                    .font(.title2)
                    .foregroundStyle(.secondary)
                Text("Organize Current Folder")
                    .font(.headline)
            }

            if let currentURL = viewModel.currentURL {
                Label(currentURL.path, systemImage: "folder")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            TextField("Describe how you want to organize these files", text: $instruction, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(3...6)
                .focused($isFieldFocused)
                .disabled(viewModel.isAIPlanning)

            if let message = viewModel.aiOrganizeErrorMessage {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(3)
            }

            HStack {
                Button("Cancel") {
                    viewModel.cancelAIPlanning()
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                if viewModel.isAIPlanning {
                    ProgressView()
                        .controlSize(.small)
                    Button("Stop", action: viewModel.cancelAIPlanning)
                } else {
                    Button(action: submit) {
                        Label("Review Organize Plan", systemImage: "sparkles")
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .padding(20)
        .frame(width: 500)
        .onAppear { isFieldFocused = true }
    }

    private func submit() {
        viewModel.submitAIOrganizeInstruction(instruction)
    }
}
