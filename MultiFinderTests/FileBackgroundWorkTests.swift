import Foundation
import XCTest
@testable import MultiFinder

final class FileBackgroundWorkTests: XCTestCase {
    func testCancellingCallerStopsRunningWorker() async throws {
        let started = expectation(description: "worker started")
        let caller = Task {
            try await FileBackgroundWork.run {
                started.fulfill()
                let deadline = Date().addingTimeInterval(3)
                while Date() < deadline {
                    try Task.checkCancellation()
                    Thread.sleep(forTimeInterval: 0.001)
                }
                return true
            }
        }
        await fulfillment(of: [started], timeout: 2)
        caller.cancel()
        do {
            _ = try await caller.value
            XCTFail("The background worker must observe cancellation")
        } catch is CancellationError {
        }
    }

    func testCancellationDiscardsNonCooperativeWorkerResult() async throws {
        let started = expectation(description: "worker started")
        let release = DispatchSemaphore(value: 0)
        let caller = Task {
            try await FileBackgroundWork.run {
                started.fulfill()
                _ = release.wait(timeout: .now() + 3)
                return 42
            }
        }
        await fulfillment(of: [started], timeout: 2)
        caller.cancel()
        release.signal()
        do {
            _ = try await caller.value
            XCTFail("Cancelled work must not publish a completed value")
        } catch is CancellationError {
        }
    }
}
