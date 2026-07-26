import AppKit
import Combine

struct FileClipboardPayload {
    let urls: [URL]
    let isCut: Bool
    let changeCount: Int
}

@MainActor
final class FileClipboard: ObservableObject {
    static let shared = FileClipboard()

    @Published private(set) var pasteboardChangeCount: Int

    private static let cutType = NSPasteboard.PasteboardType("com.multifinder.file-cut")
    private let pasteboard: NSPasteboard
    private var poller: AnyCancellable?

    init(pasteboard: NSPasteboard = .general, startPolling: Bool = true) {
        self.pasteboard = pasteboard
        pasteboardChangeCount = pasteboard.changeCount
        if startPolling {
            poller = Timer.publish(every: 0.5, on: .main, in: .common)
                .autoconnect()
                .sink { [weak self] _ in
                    self?.refresh()
                }
        }
    }

    var payload: FileClipboardPayload? {
        let changeCount = pasteboard.changeCount
        guard let objects = pasteboard.readObjects(forClasses: [NSURL.self]) as? [NSURL] else { return nil }
        let urls = objects
            .map { $0 as URL }
            .filter(\.isFileURL)
            .map(\.standardizedFileURL)
        guard !urls.isEmpty, pasteboard.changeCount == changeCount else { return nil }
        return FileClipboardPayload(
            urls: urls,
            isCut: pasteboard.availableType(from: [Self.cutType]) != nil,
            changeCount: changeCount
        )
    }

    var copiedURLs: [URL] { payload?.urls ?? [] }
    var isCut: Bool { payload?.isCut == true }
    var hasContent: Bool { payload != nil }

    func copy(urls: [URL]) {
        write(urls: urls, cut: false)
    }

    func cut(urls: [URL]) {
        write(urls: urls, cut: true)
    }

    func clear() {
        pasteboard.clearContents()
        refresh()
    }

    @discardableResult
    func consumeIfUnchanged(_ payload: FileClipboardPayload, remainingURLs: [URL] = []) -> Bool {
        guard pasteboard.changeCount == payload.changeCount else { return false }

        if remainingURLs.isEmpty {
            pasteboard.clearContents()
            refresh()
            return true
        }

        return write(urls: remainingURLs, cut: payload.isCut)
    }

    func refresh() {
        let current = pasteboard.changeCount
        if pasteboardChangeCount != current {
            pasteboardChangeCount = current
        }
    }

    @discardableResult
    private func write(urls: [URL], cut: Bool) -> Bool {
        let fileURLs = urls.filter(\.isFileURL)
        guard !fileURLs.isEmpty else { return false }
        pasteboard.clearContents()
        guard pasteboard.writeObjects(fileURLs as [NSURL]) else {
            refresh()
            return false
        }
        if cut {
            pasteboard.setData(Data(), forType: Self.cutType)
        }
        refresh()
        return true
    }
}
