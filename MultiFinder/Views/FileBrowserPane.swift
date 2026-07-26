import SwiftUI
import UniformTypeIdentifiers

struct FileBrowserPane: View {
    @ObservedObject var viewModel: FileBrowserViewModel
    @ObservedObject var layoutManager: LayoutManager
    let isFocused: Bool
    let isHighlighted: Bool
    let onFocus: () -> Void

    @State private var renameTarget: FileItem?
    @State private var isDropTargeted = false
    @ObservedObject private var operationService = FileOperationService.shared

    var body: some View {
        VStack(spacing: 0) {
            PathBarView(
                location: viewModel.location,
                isFocused: isFocused,
                onNavigate: { url in
                    onFocus()
                    viewModel.navigate(to: url)
                },
                onNavigateToFile: { url in
                    onFocus()
                    viewModel.navigateToFile(url)
                },
                onRefresh: {
                    onFocus()
                    viewModel.refresh()
                }
            )

            Divider()

            FileListView(
                viewModel: viewModel,
                onFocus: onFocus,
                onQuickLook: {
                    QuickLookManager.shared.preview(urls: viewModel.selectedItemURLs)
                },
                onRename: { item in
                    renameTarget = item
                }
            )
            .simultaneousGesture(TapGesture().onEnded { _ in onFocus() })

            Divider()

            statusBar
        }
        .frame(minWidth: 170, minHeight: 130)
        .overlay(
            RoundedRectangle(cornerRadius: 0)
                .stroke(
                    paneBorderColor,
                    lineWidth: paneBorderWidth
                )
                .shadow(
                    color: isHighlighted ? Color.accentColor.opacity(0.7) : .clear,
                    radius: isHighlighted ? 7 : 0
                )
        )
        .animation(.easeInOut(duration: 0.2), value: isHighlighted)
        .onDrop(of: [UTType.fileURL], isTargeted: $isDropTargeted) { providers in
            handleDrop(providers: providers)
        }
        .sheet(item: $renameTarget) { item in
            RenameSheet(item: item, viewModel: viewModel)
        }
        .alert("Error", isPresented: showErrorBinding) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(viewModel.errorMessage ?? "")
        }
        .contextMenu {
            paneContextMenu
        }
        .onChange(of: viewModel.location) { _, _ in
            layoutManager.save()
        }
        .onChange(of: viewModel.sortOrder) { _, _ in
            layoutManager.save()
        }
        .onChange(of: viewModel.showHiddenFiles) { _, _ in
            layoutManager.save()
        }
    }

    // MARK: - Pane Context Menu (split operations)

    @ViewBuilder
    private var paneContextMenu: some View {
        Button("Split Right") {
            layoutManager.addPaneRight(of: viewModel.id)
        }

        Button("Split Left") {
            layoutManager.addPaneLeft(of: viewModel.id)
        }

        Divider()

        Button("Add Row Above") {
            layoutManager.addRowAbove(of: viewModel.id)
        }

        Button("Add Row Below") {
            layoutManager.addRowBelow(of: viewModel.id)
        }

        Divider()

        Button("Remove Pane", role: .destructive) {
            layoutManager.removePane(viewModel.id)
        }
        .disabled(layoutManager.totalPaneCount <= 1)
    }

    // MARK: - Status Bar

    private var statusBar: some View {
        HStack {
            Text("\(viewModel.items.count) item\(viewModel.items.count == 1 ? "" : "s")")
            Spacer()
            if !viewModel.selectedItems.isEmpty {
                Text("\(viewModel.selectedItems.count) selected")
            }
            if viewModel.isLoading {
                ProgressView()
                    .controlSize(.small)
            }
            if let operation = operationService.activeOperation {
                ProgressView(value: operation.fractionCompleted)
                    .frame(width: 70)
                Button(action: operationService.cancelCurrent) {
                    Image(systemName: "xmark.circle")
                }
                .buttonStyle(.plain)
                .help("Cancel Operation")
            }
        }
        .font(.system(size: 11))
        .foregroundColor(.secondary)
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(Color(nsColor: .underPageBackgroundColor))
    }

    // MARK: - Helpers

    private var showErrorBinding: Binding<Bool> {
        Binding(
            get: { viewModel.errorMessage != nil },
            set: { if !$0 { viewModel.errorMessage = nil } }
        )
    }

    private var paneBorderColor: Color {
        if isDropTargeted || isHighlighted { return .accentColor }
        return isFocused ? Color.accentColor.opacity(0.4) : Color(nsColor: .separatorColor)
    }

    private var paneBorderWidth: Double {
        isDropTargeted || isHighlighted ? 3 : (isFocused ? 1.5 : 0.5)
    }

    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        guard viewModel.canCreateItems else { return false }
        onFocus()
        var handled = false
        for provider in providers {
            guard provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) else { continue }
            handled = true
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { data, _ in
                guard let data = data as? Data,
                      let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
                DispatchQueue.main.async {
                    viewModel.copyItems(from: [url])
                }
            }
        }
        return handled
    }
}
