import CoreServices
import Foundation

/// File-level FSEvents, so a saved file updates that file instead of the whole folder.
@MainActor
final class DirectoryMonitor {
    private final class EventBox {
        var onChange: ([URL]) -> Void = { _ in }
    }

    private var stream: FSEventStreamRef?
    private let eventBox = EventBox()

    func watch(_ url: URL, onChange: @escaping @MainActor ([URL]) -> Void) {
        cancel()
        eventBox.onChange = { urls in
            Task { @MainActor in
                onChange(urls)
            }
        }

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(eventBox).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        let flags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes
        )
        guard let stream = FSEventStreamCreate(
            nil,
            { _, info, _, eventPaths, _, _ in
                guard let info else { return }
                let box = Unmanaged<DirectoryMonitor.EventBox>.fromOpaque(info).takeUnretainedValue()
                let paths = unsafeBitCast(eventPaths, to: NSArray.self)
                let urls = paths.compactMap { value -> URL? in
                    guard let path = value as? String else { return nil }
                    return URL(fileURLWithPath: path)
                }
                box.onChange(urls)
            },
            &context,
            [url.path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.3,
            flags
        ) else { return }

        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, .main)
        FSEventStreamStart(stream)
    }

    func cancel() {
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
        stream = nil
    }

    deinit {
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
    }
}
