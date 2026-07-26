import Foundation
import Darwin

@MainActor
final class DirectoryMonitor {
    private var source: DispatchSourceFileSystemObject?
    private var fileDescriptor: Int32 = -1

    func watch(_ url: URL, onChange: @escaping @MainActor () -> Void) {
        cancel()

        let descriptor = open(url.path, O_EVTONLY)
        guard descriptor >= 0 else { return }

        fileDescriptor = descriptor
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .delete, .rename, .attrib, .extend, .link, .revoke],
            queue: DispatchQueue.global(qos: .utility)
        )
        source.setEventHandler {
            Task { @MainActor in
                onChange()
            }
        }
        source.setCancelHandler {
            close(descriptor)
        }
        self.source = source
        source.resume()
    }

    func cancel() {
        source?.cancel()
        source = nil
        fileDescriptor = -1
    }

    deinit {
        source?.cancel()
    }
}
