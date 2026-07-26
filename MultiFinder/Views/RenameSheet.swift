import SwiftUI

struct RenameSheet: View {
    let item: FileItem
    @ObservedObject var viewModel: FileBrowserViewModel
    @State private var newName: String
    @Environment(\.dismiss) private var dismiss

    init(item: FileItem, viewModel: FileBrowserViewModel) {
        self.item = item
        self.viewModel = viewModel
        _newName = State(initialValue: item.name)
    }

    var body: some View {
        VStack(spacing: 16) {
            HStack {
                Image(nsImage: IconCache.shared.icon(for: item.url.path))
                    .resizable()
                    .frame(width: 32, height: 32)
                Text("Rename")
                    .font(.headline)
                Spacer()
            }

            TextField("Name:", text: $newName)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 13))
                .onSubmit { performRename() }

            if let validationError {
                Text(validationError)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Rename") { performRename() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(validationError != nil || newName == item.name)
            }
        }
        .padding(20)
        .frame(width: 340)
    }

    private func performRename() {
        guard validationError == nil, newName != item.name else {
            dismiss()
            return
        }
        viewModel.rename(item: item, to: newName)
        dismiss()
    }

    private var validationError: String? {
        FileOperationService.validationError(forFileName: newName)
    }
}
