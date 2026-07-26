import SwiftUI

struct BatchRenameSheet: View {
    let items: [FileItem]
    @ObservedObject var viewModel: FileBrowserViewModel
    @Environment(\.dismiss) private var dismiss

    private enum ModeSelection: String, CaseIterable, Identifiable {
        case findReplace = "Replace Text"
        case addText = "Add Text"
        case sequence = "Sequence"

        var id: String { rawValue }
    }

    @State private var modeSelection: ModeSelection = .findReplace
    @State private var findText = ""
    @State private var replaceText = ""
    @State private var useRegex = false
    @State private var caseSensitive = true
    @State private var prefixText = ""
    @State private var suffixText = ""
    @State private var sequenceFormat = "name-{n}"
    @State private var startNumber = 1
    @State private var numberPadding = 1

    var body: some View {
        VStack(spacing: 16) {
            HStack {
                Image(systemName: "square.and.pencil")
                    .font(.title2)
                    .foregroundStyle(.secondary)
                Text("Rename \(items.count) Items")
                    .font(.headline)
                Spacer()
            }

            Picker("Mode", selection: $modeSelection) {
                ForEach(ModeSelection.allCases) { selection in
                    Text(selection.rawValue).tag(selection)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            modeFields

            if let configurationIssue {
                Text(configurationIssue)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            previewList

            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Text(summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Apply") { apply() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!BatchRenameEngine.canApply(rows, mode: mode))
            }
        }
        .padding(20)
        .frame(width: 480, height: 460)
    }

    @ViewBuilder
    private var modeFields: some View {
        switch modeSelection {
        case .findReplace:
            VStack(spacing: 8) {
                TextField("Find:", text: $findText)
                    .textFieldStyle(.roundedBorder)
                TextField("Replace with:", text: $replaceText)
                    .textFieldStyle(.roundedBorder)
                HStack {
                    Toggle("Regular expression", isOn: $useRegex)
                    Toggle("Case sensitive", isOn: $caseSensitive)
                    Spacer()
                }
                .font(.system(size: 12))
            }
        case .addText:
            VStack(spacing: 8) {
                TextField("Prefix:", text: $prefixText)
                    .textFieldStyle(.roundedBorder)
                TextField("Suffix (before extension):", text: $suffixText)
                    .textFieldStyle(.roundedBorder)
            }
        case .sequence:
            VStack(spacing: 8) {
                TextField("Format (use {n} for the number):", text: $sequenceFormat)
                    .textFieldStyle(.roundedBorder)
                HStack {
                    Stepper("Start at \(startNumber)", value: $startNumber, in: 0...9999)
                    Spacer()
                    Stepper("Padding: \(numberPadding)", value: $numberPadding, in: 1...10)
                }
                .font(.system(size: 12))
            }
        }
    }

    private var previewList: some View {
        List(rows) { row in
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(row.originalName)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(row.isNoOp ? .secondary : .primary)
                    Image(systemName: "arrow.right")
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                    Text(row.isNoOp ? "unchanged" : row.newName)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(rowColor(for: row))
                }
                .font(.system(size: 12))
                if let issue = row.issue {
                    Text(issue)
                        .font(.caption2)
                        .foregroundStyle(.red)
                }
            }
        }
        .listStyle(.bordered)
        .frame(maxHeight: .infinity)
    }

    private func rowColor(for row: BatchRenamePreviewRow) -> Color {
        if row.issue != nil { return .red }
        return row.isNoOp ? .secondary : .primary
    }

    private var mode: BatchRenameMode {
        switch modeSelection {
        case .findReplace:
            return .findReplace(
                find: findText,
                replace: replaceText,
                useRegex: useRegex,
                caseSensitive: caseSensitive
            )
        case .addText:
            return .addText(prefix: prefixText, suffix: suffixText)
        case .sequence:
            return .sequence(format: sequenceFormat, start: startNumber, padding: numberPadding)
        }
    }

    private var directory: URL? {
        items.first?.url.deletingLastPathComponent()
    }

    private var rows: [BatchRenamePreviewRow] {
        let existingNames = directory.flatMap {
            try? FileManager.default.contentsOfDirectory(atPath: $0.path)
        } ?? []
        return BatchRenameEngine.preview(
            urls: items.map(\.url),
            mode: mode,
            existingNames: Set(existingNames)
        )
    }

    private var configurationIssue: String? {
        BatchRenameEngine.configurationIssue(for: mode)
    }

    private var summary: String {
        "\(rows.filter(\.isRenamed).count) of \(items.count) will be renamed"
    }

    private func apply() {
        guard let directory else { return }
        let currentRows = rows
        guard BatchRenameEngine.canApply(currentRows, mode: mode) else { return }
        let pairs = currentRows.filter(\.isRenamed).map { row in
            BatchRenamePair(
                source: row.source,
                destination: directory.appendingPathComponent(row.newName)
            )
        }
        viewModel.batchRename(pairs)
        dismiss()
    }
}
