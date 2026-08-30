import Foundation
import XCTest
@testable import MultiFinder

@MainActor
final class VolumeStoreTests: XCTestCase {
    private enum FixtureError: Error {
        case missingResource
    }

    private final class EjectRecorder: @unchecked Sendable {
        var requestedURLs: [URL] = []
        var completion: (@Sendable (String?) -> Void)?
    }

    func testRefreshUsesInjectedResourceValuesAndSortsMountedVolumes() throws {
        let rootURL = URL(fileURLWithPath: "/")
        let archiveURL = URL(fileURLWithPath: "/Volumes/Archive")
        let networkURL = URL(fileURLWithPath: "/Volumes/Office NAS")
        let duplicateArchiveURL = URL(fileURLWithPath: "/Volumes/Archive/../Archive")
        let resources: [URL: VolumeResourceValues] = [
            rootURL: VolumeResourceValues(
                name: "Macintosh HD",
                isLocal: true,
                isRootFileSystem: true,
                totalCapacity: 1_000,
                availableCapacity: 400
            ),
            archiveURL: VolumeResourceValues(
                name: "Archive",
                isLocal: true,
                isRemovable: true,
                isEjectable: true,
                totalCapacity: 2_000,
                availableCapacity: 1_500
            ),
            networkURL: VolumeResourceValues(
                localizedName: "Office NAS",
                isLocal: false
            ),
        ]

        let store = VolumeStore(
            mountedVolumeProvider: { [rootURL, archiveURL, networkURL, duplicateArchiveURL] },
            resourceValuesProvider: { url in
                guard let values = resources[url] else { throw FixtureError.missingResource }
                return values
            }
        )

        XCTAssertEqual(store.volumes.map(\.name), ["Macintosh HD", "Archive", "Office NAS"])
        XCTAssertEqual(store.volumes.map(\.url), [rootURL, archiveURL, networkURL])

        let archive = try XCTUnwrap(store.volumes.first { $0.url == archiveURL })
        XCTAssertTrue(archive.isLocal)
        XCTAssertTrue(archive.isRemovable)
        XCTAssertTrue(archive.isEjectable)
        XCTAssertTrue(archive.canEject)
        XCTAssertEqual(archive.totalCapacity, 2_000)
        XCTAssertEqual(archive.availableCapacity, 1_500)

        let network = try XCTUnwrap(store.volumes.first { $0.url == networkURL })
        XCTAssertTrue(network.isNetwork)
        XCTAssertFalse(network.canEject)
    }

    func testRefreshSkipsUnreadableVolumesAndSurfacesReadableError() {
        let goodURL = URL(fileURLWithPath: "/Volumes/Good")
        let brokenURL = URL(fileURLWithPath: "/Volumes/Broken")

        let store = VolumeStore(
            mountedVolumeProvider: { [goodURL, brokenURL] },
            resourceValuesProvider: { url in
                guard url == goodURL else { throw FixtureError.missingResource }
                return VolumeResourceValues(name: "Good", isLocal: true)
            }
        )

        XCTAssertEqual(store.volumes.map(\.url), [goodURL])
        XCTAssertTrue(store.errorMessage?.contains("Broken") == true)
    }

    func testMountUnmountAndRenameNotificationsRefreshInjectedDiscovery() async {
        let firstURL = URL(fileURLWithPath: "/Volumes/First")
        let secondURL = URL(fileURLWithPath: "/Volumes/Second")
        let renamedURL = URL(fileURLWithPath: "/Volumes/Renamed")
        var mountedURLs = [firstURL]
        var resources: [URL: VolumeResourceValues] = [
            firstURL: VolumeResourceValues(name: "First", isLocal: true),
            secondURL: VolumeResourceValues(name: "Second", isLocal: true),
            renamedURL: VolumeResourceValues(name: "Renamed", isLocal: true),
        ]
        let notificationCenter = NotificationCenter()

        let store = VolumeStore(
            mountedVolumeProvider: { mountedURLs },
            resourceValuesProvider: { url in
                guard let values = resources[url] else { throw FixtureError.missingResource }
                return values
            },
            notificationCenter: notificationCenter
        )

        XCTAssertEqual(store.volumes.map(\.url), [firstURL])

        mountedURLs = [secondURL]
        notificationCenter.post(name: NSWorkspace.didMountNotification, object: nil)
        await flushMainActor()
        XCTAssertEqual(store.volumes.map(\.url), [secondURL])

        mountedURLs = [renamedURL]
        resources[renamedURL] = VolumeResourceValues(name: "Renamed", isLocal: true)
        notificationCenter.post(name: NSWorkspace.didRenameVolumeNotification, object: nil)
        await flushMainActor()
        XCTAssertEqual(store.volumes.map(\.name), ["Renamed"])

        mountedURLs = []
        notificationCenter.post(name: NSWorkspace.didUnmountNotification, object: nil)
        await flushMainActor()
        XCTAssertTrue(store.volumes.isEmpty)
    }

    func testEjectRunsThroughInjectedHandlerAndReportsCompletionError() async throws {
        let volumeURL = URL(fileURLWithPath: "/Volumes/Archive")
        let recorder = EjectRecorder()
        let store = VolumeStore(
            mountedVolumeProvider: { [volumeURL] },
            resourceValuesProvider: { _ in
                VolumeResourceValues(
                    name: "Archive",
                    isLocal: true,
                    isRemovable: true,
                    isEjectable: true
                )
            },
            ejectHandler: { url, completion in
                recorder.requestedURLs.append(url)
                recorder.completion = completion
            }
        )
        let volume = try XCTUnwrap(store.volumes.first)

        store.eject(volume)
        XCTAssertTrue(store.isEjecting(volume))
        XCTAssertEqual(recorder.requestedURLs, [volumeURL])

        recorder.completion?("Device is busy")
        await flushMainActor()

        XCTAssertFalse(store.isEjecting(volume))
        XCTAssertTrue(store.errorMessage?.contains("Archive") == true)
        XCTAssertTrue(store.errorMessage?.contains("Device is busy") == true)
    }

    func testSuccessfulEjectRefreshesVolumesAndNonEjectableVolumesAreIgnored() async throws {
        let removableURL = URL(fileURLWithPath: "/Volumes/Removable")
        let internalURL = URL(fileURLWithPath: "/Volumes/Internal")
        let recorder = EjectRecorder()
        let store = VolumeStore(
            mountedVolumeProvider: { [removableURL, internalURL] },
            resourceValuesProvider: { url in
                VolumeResourceValues(
                    name: url == removableURL ? "Removable" : "Internal",
                    isLocal: true,
                    isRemovable: url == removableURL,
                    isEjectable: url == removableURL
                )
            },
            ejectHandler: { url, completion in
                recorder.requestedURLs.append(url)
                recorder.completion = completion
            }
        )
        let removable = try XCTUnwrap(store.volumes.first { $0.url == removableURL })
        let internalVolume = try XCTUnwrap(store.volumes.first { $0.url == internalURL })

        store.eject(internalVolume)
        XCTAssertTrue(recorder.requestedURLs.isEmpty)

        store.eject(removable)
        XCTAssertTrue(store.isEjecting(removable))
        recorder.completion?(nil)
        await flushMainActor()

        XCTAssertFalse(store.isEjecting(removable))
        XCTAssertNil(store.errorMessage)
        XCTAssertEqual(store.volumes.count, 2)
    }

    private func flushMainActor() async {
        await Task.yield()
        await Task.yield()
    }
}
