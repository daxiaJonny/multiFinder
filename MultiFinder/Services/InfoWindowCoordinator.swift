import AppKit
import SwiftUI

@MainActor
final class InfoWindowCoordinator: NSObject, NSWindowDelegate {
    static let shared = InfoWindowCoordinator()

    private var controllers: [UUID: NSWindowController] = [:]

    func present(
        urls: [URL],
        onRename: InfoPanelRenameHandler? = nil
    ) {
        let urls = uniqueExistingURLs(urls)
        guard !urls.isEmpty else { return }

        let id = UUID()
        let rootView = InfoPanel(
            urls: urls,
            onRename: onRename,
            onClose: { [weak self] in
                self?.controllers[id]?.close()
            }
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 580, height: 650),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.identifier = NSUserInterfaceItemIdentifier(id.uuidString)
        window.title = windowTitle(for: urls)
        window.contentViewController = NSHostingController(rootView: rootView)
        window.minSize = NSSize(width: 520, height: 520)
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.delegate = self
        window.center()

        let offset = CGFloat(controllers.count % 6) * 18
        window.setFrameOrigin(NSPoint(
            x: window.frame.origin.x + offset,
            y: window.frame.origin.y - offset
        ))

        let controller = NSWindowController(window: window)
        controllers[id] = controller
        controller.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              let identifier = window.identifier?.rawValue,
              let id = UUID(uuidString: identifier) else { return }
        controllers.removeValue(forKey: id)
    }

    private func uniqueExistingURLs(_ urls: [URL]) -> [URL] {
        var seen = Set<URL>()
        return urls.compactMap { url in
            let standardizedURL = url.standardizedFileURL
            guard seen.insert(standardizedURL).inserted,
                  FileManager.default.fileExists(atPath: standardizedURL.path) else {
                return nil
            }
            return standardizedURL
        }
    }

    private func windowTitle(for urls: [URL]) -> String {
        urls.count == 1
            ? L10n.format("%@ Info", urls[0].lastPathComponent)
            : L10n.format("%lld Items Info", Int64(urls.count))
    }
}
