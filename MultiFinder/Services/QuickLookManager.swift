import AppKit
import QuickLookUI

@MainActor
final class QuickLookManager: NSObject, @preconcurrency QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    static let shared = QuickLookManager()

    private var urls: [URL] = []
    private var ownerID: UUID?
    private weak var ownerWindow: NSWindow?

    func togglePreview(urls: [URL], ownerID: UUID) {
        guard let panel = QLPreviewPanel.shared() else { return }

        if panel.isVisible, self.ownerID == ownerID {
            closePreview(ownerID: ownerID)
            return
        }

        let previewURLs = validPreviewURLs(urls)
        guard !previewURLs.isEmpty else {
            closePreview()
            return
        }

        let presentingWindow = NSApp.keyWindow
        self.urls = previewURLs
        self.ownerID = ownerID
        ownerWindow = presentingWindow
        panel.dataSource = self
        panel.delegate = self
        panel.reloadData()
        if !panel.isVisible {
            panel.makeKeyAndOrderFront(nil)
        }
    }

    func updatePreview(urls: [URL], ownerID: UUID) {
        guard self.ownerID == ownerID else { return }
        guard let panel = QLPreviewPanel.shared(), panel.isVisible else {
            closePreview(ownerID: ownerID)
            return
        }

        let previewURLs = validPreviewURLs(urls)
        guard !previewURLs.isEmpty else {
            closePreview(ownerID: ownerID)
            return
        }

        self.urls = previewURLs
        panel.dataSource = self
        panel.delegate = self
        panel.reloadData()
    }

    func closePreview(ownerID: UUID? = nil) {
        if let ownerID, self.ownerID != ownerID {
            return
        }

        let panel = QLPreviewPanel.shared()
        let windowToRestore = ownerWindow
        clearState(for: panel)
        panel?.close()
        restoreFocus(to: windowToRestore)
    }

    private func clearState(for panel: QLPreviewPanel?) {
        urls.removeAll(keepingCapacity: true)
        ownerID = nil
        ownerWindow = nil
        panel?.dataSource = nil
        panel?.delegate = nil
    }

    private func restoreFocus(to window: NSWindow?) {
        guard let window else { return }
        DispatchQueue.main.async {
            guard window.isVisible else { return }
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
        }
    }

    private func validPreviewURLs(_ urls: [URL]) -> [URL] {
        var seen: Set<URL> = []
        return urls.compactMap { url in
            let standardizedURL = url.standardizedFileURL
            guard seen.insert(standardizedURL).inserted,
                  FileManager.default.fileExists(atPath: standardizedURL.path) else {
                return nil
            }
            return standardizedURL
        }
    }

    // MARK: - QLPreviewPanelDelegate

    func windowWillClose(_ notification: Notification) {
        guard let panel = notification.object as? QLPreviewPanel else { return }
        let windowToRestore = ownerWindow
        clearState(for: panel)
        restoreFocus(to: windowToRestore)
    }

    // MARK: - QLPreviewPanelDataSource

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        urls.count
    }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        guard urls.indices.contains(index) else { return nil }
        return urls[index] as QLPreviewItem
    }
}
