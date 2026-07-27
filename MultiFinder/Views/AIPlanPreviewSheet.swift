import SwiftUI

struct AIPlanPreviewSheet: View {
    let preview: FileBrowserViewModel.AIPlanPreview
    @ObservedObject var viewModel: FileBrowserViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var excludedIDs: Set<Int> = []
    @State private var subsetValidation: PlanValidationResult
    @State private var revalidationError: String?

    private let operations: [AIPlanOperation]

    init(preview: FileBrowserViewModel.AIPlanPreview, viewModel: FileBrowserViewModel) {
        self.preview = preview
        self.viewModel = viewModel
        self.operations = preview.validation.operations.map(\.operation)
        _subsetValidation = State(initialValue: preview.validation)
    }

    var body: some View {
        VStack(spacing: 16) {
            HStack {
                Image(systemName: "sparkles")
                    .font(.title2)
                    .foregroundStyle(.secondary)
                Text(preview.plan.summary)
                    .font(.headline)
                    .lineLimit(2)
                Spacer()
            }

            List(preview.validation.operations) { row in
                operationRow(for: row)
            }
            .listStyle(.bordered)
            .frame(maxHeight: .infinity)

            if let revalidationError {
                Text(revalidationError)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack {
                Button("取消") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Text(summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("执行 \(includedIndices.count) 项操作") {
                    run()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canRun)
            }
        }
        .padding(20)
        .frame(width: 520, height: 460)
    }

    // MARK: - Rows

    private func operationRow(for row: OperationValidation) -> some View {
        let issues = currentIssues[row.id] ?? []
        let isIncluded = !excludedIDs.contains(row.id)
        return HStack(alignment: .top, spacing: 8) {
            Toggle("", isOn: inclusionBinding(for: row.id))
                .toggleStyle(.checkbox)
                .labelsHidden()

            Image(systemName: symbolName(for: row.operation))
                .font(.system(size: 12))
                .foregroundStyle(isIncluded && !issues.isEmpty ? Color.red : Color.secondary)
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 2) {
                operationText(for: row.operation, isConflicted: isIncluded && !issues.isEmpty)
                if isIncluded {
                    ForEach(issues.indices, id: \.self) { index in
                        Text(issues[index].message)
                            .font(.caption2)
                            .foregroundStyle(.red)
                    }
                }
            }
        }
        .opacity(isIncluded ? 1 : 0.45)
    }

    @ViewBuilder
    private func operationText(for operation: AIPlanOperation, isConflicted: Bool) -> some View {
        let color: Color = isConflicted ? .red : .primary
        switch operation {
        case .createFolder(let path):
            pathText(path, color: color)
        case .move(let source, let destination), .copy(let source, let destination):
            arrowText(from: source, to: destination, color: color)
        case .rename(let source, let newName):
            arrowText(from: source, to: newName, color: color)
        case .trash(let source):
            pathText(source, color: color)
        }
    }

    private func pathText(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 12))
            .lineLimit(1)
            .truncationMode(.middle)
            .foregroundStyle(color)
    }

    private func arrowText(from old: String, to new: String, color: Color) -> some View {
        HStack(spacing: 6) {
            Text(old)
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(color)
            Image(systemName: "arrow.right")
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
            Text(new)
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(color)
        }
        .font(.system(size: 12))
    }

    private func symbolName(for operation: AIPlanOperation) -> String {
        switch operation {
        case .createFolder: return "folder.badge.plus"
        case .move: return "arrow.right.square"
        case .copy: return "doc.on.doc"
        case .rename: return "pencil"
        case .trash: return "trash"
        }
    }

    // MARK: - Subset validation

    private var includedIndices: [Int] {
        operations.indices.filter { !excludedIDs.contains($0) }
    }

    private var includedOperations: [AIPlanOperation] {
        includedIndices.map { operations[$0] }
    }

    private var currentIssues: [Int: [OperationIssue]] {
        var issues: [Int: [OperationIssue]] = [:]
        for (subsetIndex, originalIndex) in includedIndices.enumerated()
        where subsetValidation.operations.indices.contains(subsetIndex) {
            issues[originalIndex] = subsetValidation.operations[subsetIndex].issues
        }
        return issues
    }

    private func inclusionBinding(for id: Int) -> Binding<Bool> {
        Binding(
            get: { !excludedIDs.contains(id) },
            set: { isIncluded in
                if isIncluded {
                    excludedIDs.remove(id)
                } else {
                    excludedIDs.insert(id)
                }
                revalidate()
            }
        )
    }

    private func revalidate() {
        do {
            subsetValidation = try PlanValidator.validate(includedOperations, scopeRoot: preview.scopeRoot)
            revalidationError = nil
        } catch {
            subsetValidation = PlanValidationResult(operations: [])
            revalidationError = error.localizedDescription
        }
    }

    private var canRun: Bool {
        !includedOperations.isEmpty && revalidationError == nil && subsetValidation.isExecutable
    }

    private var summary: String {
        "已选择 \(includedIndices.count) / \(operations.count) 项"
    }

    private func run() {
        guard canRun else { return }
        viewModel.executeAIPlan(includedOperations, scopeRoot: preview.scopeRoot)
        dismiss()
    }
}
