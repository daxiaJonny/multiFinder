import AppKit
import QuickLookUI

@MainActor
final class QuickLookManager: NSObject, @preconcurrency QLPreviewPanelDataSource {
    static let shared = QuickLookManager()
    private var urls: [URL] = []

    func preview(urls: [URL]) {
        guard !urls.isEmpty else { return }
        self.urls = urls
        guard let panel = QLPreviewPanel.shared() else { return }
        panel.dataSource = self
        if panel.isVisible {
            panel.reloadData()
        } else {
            panel.makeKeyAndOrderFront(nil)
        }
    }

    // MARK: - QLPreviewPanelDataSource

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        urls.count
    }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        urls[index] as QLPreviewItem
    }
}
