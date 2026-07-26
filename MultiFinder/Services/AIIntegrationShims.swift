import Foundation

// TEMPORARY integration shims — delete this entire file when wiring the real
// implementations:
// - `PlaceholderAIPlanner` stands in for `CursorCLIPlanner.shared` (Agent B).
//   Swap the two defaults in `FileBrowserViewModel.init` (`aiPlanner:` and
//   `aiPlannerAvailable:`) to the real planner and its availability probe.
// - `aiOrganizeDetailed` stands in for the real queued operation (Agent D),
//   which uses the same name and signature on `FileOperationService`.

struct PlaceholderAIPlanner: AIPlanner {
    var isAvailable: Bool { true }

    func plan(_ request: AIPlanRequest) async throws -> AIPlan {
        throw AIPlannerNotConnectedError()
    }
}

struct AIPlannerNotConnectedError: LocalizedError, Sendable {
    var errorDescription: String? { "The AI planner is not connected yet." }
}

extension FileOperationService {
    func aiOrganizeDetailed(
        _ operations: [AIPlanOperation],
        scopeRoot: URL,
        completion: ((FileOperationResult) -> Void)? = nil
    ) {
        completion?(FileOperationResult(
            status: .failed,
            outcomes: [],
            errorMessage: "AI organize execution is not connected yet."
        ))
    }
}
