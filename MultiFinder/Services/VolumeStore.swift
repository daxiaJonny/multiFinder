import AppKit
import Combine
import Foundation

struct VolumeResourceValues: Equatable, Sendable {
    let localizedName: String?
    let name: String?
    let isBrowsable: Bool?
    let isLocal: Bool?
    let isRemovable: Bool?
    let isEjectable: Bool?
    let isRootFileSystem: Bool?
    let totalCapacity: Int?
    let availableCapacity: Int?

    init(
        localizedName: String? = nil,
        name: String? = nil,
        isBrowsable: Bool? = nil,
        isLocal: Bool? = nil,
        isRemovable: Bool? = nil,
        isEjectable: Bool? = nil,
        isRootFileSystem: Bool? = nil,
        totalCapacity: Int? = nil,
        availableCapacity: Int? = nil
    ) {
        self.localizedName = localizedName
        self.name = name
        self.isBrowsable = isBrowsable
        self.isLocal = isLocal
        self.isRemovable = isRemovable
        self.isEjectable = isEjectable
        self.isRootFileSystem = isRootFileSystem
        self.totalCapacity = totalCapacity
        self.availableCapacity = availableCapacity
    }
}

private final class VolumeNotificationObserverStore {
    private let notificationCenter: NotificationCenter
    private var observers: [NSObjectProtocol] = []

    init(notificationCenter: NotificationCenter, onChange: @escaping @Sendable () -> Void) {
        self.notificationCenter = notificationCenter
        let notificationNames: [Notification.Name] = [
            NSWorkspace.didMountNotification,
            NSWorkspace.didUnmountNotification,
            NSWorkspace.didRenameVolumeNotification,
        ]
        observers = notificationNames.map { name in
            notificationCenter.addObserver(forName: name, object: nil, queue: .main) { _ in
                onChange()
            }
        }
    }

    deinit {
        observers.forEach(notificationCenter.removeObserver)
    }
}

@MainActor
final class VolumeStore: ObservableObject {
    struct MountedVolume: Identifiable, Hashable, Sendable {
        let url: URL
        let name: String
        let isLocal: Bool
        let isRemovable: Bool
        let isEjectable: Bool
        let isRootFileSystem: Bool
        let totalCapacity: Int?
        let availableCapacity: Int?

        var id: URL { url }

        var isNetwork: Bool {
            !isLocal
        }

        var canEject: Bool {
            isEjectable || isRemovable
        }

        var capacityDescription: String? {
            guard let availableCapacity, availableCapacity >= 0 else { return nil }

            let formatter = ByteCountFormatter()
            formatter.countStyle = .file
            let available = formatter.string(fromByteCount: Int64(availableCapacity))

            guard let totalCapacity, totalCapacity > 0 else {
                return L10n.format("%@ available", available)
            }

            let total = formatter.string(fromByteCount: Int64(totalCapacity))
            return L10n.format("%@ available of %@", available, total)
        }
    }

    typealias MountedVolumeProvider = () -> [URL]
    typealias ResourceValuesProvider = (URL) throws -> VolumeResourceValues
    typealias EjectHandler = @Sendable (URL, @escaping @Sendable (String?) -> Void) -> Void

    static let shared = VolumeStore()

    @Published private(set) var volumes: [MountedVolume] = []
    @Published private(set) var ejectingVolumeIDs: Set<URL> = []
    @Published private(set) var errorMessage: String?

    private let mountedVolumeProvider: MountedVolumeProvider
    private let resourceValuesProvider: ResourceValuesProvider
    private let notificationCenter: NotificationCenter
    private let ejectHandler: EjectHandler
    private var notificationObserverStore: VolumeNotificationObserverStore?

    init(
        fileManager: FileManager = .default,
        workspace: NSWorkspace = .shared,
        resourceValuesProvider: ResourceValuesProvider? = nil,
        ejectHandler: EjectHandler? = nil
    ) {
        mountedVolumeProvider = {
            fileManager.mountedVolumeURLs(
                includingResourceValuesForKeys: Array(Self.resourceKeys),
                options: [.skipHiddenVolumes]
            ) ?? []
        }
        self.resourceValuesProvider = resourceValuesProvider ?? Self.systemResourceValues
        notificationCenter = workspace.notificationCenter
        self.ejectHandler = ejectHandler ?? Self.systemEjectHandler
        observeWorkspaceChanges()
        refresh()
    }

    init(
        mountedVolumeProvider: @escaping MountedVolumeProvider,
        resourceValuesProvider: @escaping ResourceValuesProvider,
        notificationCenter: NotificationCenter = NotificationCenter(),
        ejectHandler: EjectHandler? = nil
    ) {
        self.mountedVolumeProvider = mountedVolumeProvider
        self.resourceValuesProvider = resourceValuesProvider
        self.notificationCenter = notificationCenter
        self.ejectHandler = ejectHandler ?? Self.noopEjectHandler
        observeWorkspaceChanges()
        refresh()
    }

    func refresh() {
        var refreshedVolumes: [MountedVolume] = []
        var failedVolumeNames: [String] = []
        var seenURLs: Set<URL> = []

        for url in mountedVolumeProvider() {
            let normalizedURL = url.standardizedFileURL
            guard normalizedURL.isFileURL, seenURLs.insert(normalizedURL).inserted else { continue }

            do {
                let values = try resourceValuesProvider(normalizedURL)
                guard values.isBrowsable != false else { continue }

                let fallbackName = normalizedURL.path == "/"
                    ? L10n.string("Mac")
                    : normalizedURL.lastPathComponent
                let name = values.localizedName
                    ?? values.name
                    ?? fallbackName

                refreshedVolumes.append(
                    MountedVolume(
                        url: normalizedURL,
                        name: name,
                        isLocal: values.isLocal ?? true,
                        isRemovable: values.isRemovable ?? false,
                        isEjectable: values.isEjectable ?? false,
                        isRootFileSystem: values.isRootFileSystem ?? (normalizedURL.path == "/"),
                        totalCapacity: values.totalCapacity,
                        availableCapacity: values.availableCapacity
                    )
                )
            } catch {
                let fallbackName = normalizedURL.lastPathComponent.isEmpty
                    ? normalizedURL.path
                    : normalizedURL.lastPathComponent
                failedVolumeNames.append(fallbackName)
            }
        }

        volumes = refreshedVolumes.sorted { lhs, rhs in
            if lhs.isRootFileSystem != rhs.isRootFileSystem {
                return lhs.isRootFileSystem
            }

            let nameComparison = lhs.name.localizedStandardCompare(rhs.name)
            if nameComparison != .orderedSame {
                return nameComparison == .orderedAscending
            }
            return lhs.url.path.localizedStandardCompare(rhs.url.path) == .orderedAscending
        }

        if failedVolumeNames.isEmpty {
            errorMessage = nil
        } else {
            errorMessage = L10n.format(
                "Could not read volume information for %@.",
                failedVolumeNames.joined(separator: ", ")
            )
        }
    }

    func isEjecting(_ volume: MountedVolume) -> Bool {
        ejectingVolumeIDs.contains(volume.id)
    }

    func eject(_ volume: MountedVolume) {
        guard volume.canEject, !isEjecting(volume) else { return }

        let volumeID = volume.id
        ejectingVolumeIDs.insert(volumeID)
        errorMessage = nil

        ejectHandler(volume.url) { [weak self] errorDescription in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.ejectingVolumeIDs.remove(volumeID)

                if let errorDescription, !errorDescription.isEmpty {
                    self.errorMessage = L10n.format(
                        "Could not eject %@: %@",
                        volume.name,
                        errorDescription
                    )
                } else {
                    self.refresh()
                }
            }
        }
    }

    func clearError() {
        errorMessage = nil
    }

    private func observeWorkspaceChanges() {
        notificationObserverStore = VolumeNotificationObserverStore(
            notificationCenter: notificationCenter
        ) { [weak self] in
            Task { @MainActor [weak self] in
                self?.refresh()
            }
        }
    }

    private static let resourceKeys: Set<URLResourceKey> = [
        .volumeLocalizedNameKey,
        .volumeNameKey,
        .volumeIsBrowsableKey,
        .volumeIsLocalKey,
        .volumeIsRemovableKey,
        .volumeIsEjectableKey,
        .volumeIsRootFileSystemKey,
        .volumeTotalCapacityKey,
        .volumeAvailableCapacityKey,
    ]

    private static func systemResourceValues(for url: URL) throws -> VolumeResourceValues {
        let values = try url.resourceValues(forKeys: resourceKeys)
        return VolumeResourceValues(
            localizedName: values.volumeLocalizedName,
            name: values.volumeName,
            isBrowsable: values.volumeIsBrowsable,
            isLocal: values.volumeIsLocal,
            isRemovable: values.volumeIsRemovable,
            isEjectable: values.volumeIsEjectable,
            isRootFileSystem: values.volumeIsRootFileSystem,
            totalCapacity: values.volumeTotalCapacity,
            availableCapacity: values.volumeAvailableCapacity
        )
    }

    private static let noopEjectHandler: EjectHandler = { _, completion in
        completion("Eject is unavailable for this volume.")
    }

    private static let systemEjectHandler: EjectHandler = { url, completion in
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try NSWorkspace.shared.unmountAndEjectDevice(at: url)
                completion(nil)
            } catch {
                completion(error.localizedDescription)
            }
        }
    }
}
