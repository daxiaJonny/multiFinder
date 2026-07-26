import SwiftUI

struct AIInputBar: View {
    @ObservedObject var viewModel: FileBrowserViewModel

    @State private var instruction = ""
    @FocusState private var isFieldFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "sparkles")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)

                TextField("Ask AI to find or organize files…", text: $instruction)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .focused($isFieldFocused)
                    .onSubmit(submit)
                    .disabled(viewModel.isAIPlanning)

                if viewModel.isAIPlanning {
                    ProgressView()
                        .controlSize(.small)
                    Button(action: viewModel.cancelAIPlanning) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Cancel")
                } else {
                    Button(action: submit) {
                        Image(systemName: "arrow.right.circle.fill")
                            .foregroundStyle(instruction.isEmpty ? Color.secondary : Color.accentColor)
                    }
                    .buttonStyle(.plain)
                    .disabled(instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .help("Send")
                }
            }

            if let message = viewModel.aiErrorMessage {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(2)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(Color(nsColor: .underPageBackgroundColor))
        .onAppear { isFieldFocused = true }
        .onExitCommand { viewModel.toggleAIAssistant() }
    }

    private func submit() {
        viewModel.submitAIInstruction(instruction)
    }
}
