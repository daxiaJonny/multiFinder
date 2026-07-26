import Combine
import Foundation

struct WorkspaceTemplate: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    let name: String
    let layoutState: LayoutState
    let savedAt: Date

    init(
        id: UUID = UUID(),
        name: String,
        layoutState: LayoutState,
        savedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.layoutState = layoutState
        self.savedAt = savedAt
    }

    var paneCount: Int {
        layoutState.rows.reduce(0) { $0 + $1.panes.count }
    }
}

@MainActor
final class WorkspaceTemplateStore: ObservableObject {
    static let shared = WorkspaceTemplateStore()
    static let defaultStorageKey = "com.multifinder.workspaceTemplates"

    @Published private(set) var templates: [WorkspaceTemplate]

    private let userDefaults: UserDefaults
    private let storageKey: String

    init(
        userDefaults: UserDefaults = .standard,
        storageKey: String = WorkspaceTemplateStore.defaultStorageKey
    ) {
        self.userDefaults = userDefaults
        self.storageKey = storageKey

        guard let data = userDefaults.data(forKey: storageKey) else {
            templates = []
            return
        }

        do {
            let decoded = try JSONDecoder().decode([WorkspaceTemplate].self, from: data)
            templates = Self.sanitized(decoded)
            if templates != decoded {
                persist()
            }
        } catch {
            templates = []
            userDefaults.removeObject(forKey: storageKey)
        }
    }

    @discardableResult
    func save(name: String, layoutState: LayoutState) -> WorkspaceTemplate? {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty, LayoutManager.isUsable(layoutState) else { return nil }

        let normalizedName = String(trimmedName.prefix(80))
        if let index = templates.firstIndex(where: {
            $0.name.localizedCaseInsensitiveCompare(normalizedName) == .orderedSame
        }) {
            let template = WorkspaceTemplate(
                id: templates[index].id,
                name: normalizedName,
                layoutState: layoutState
            )
            templates[index] = template
            persist()
            return template
        }

        let template = WorkspaceTemplate(name: normalizedName, layoutState: layoutState)
        templates.append(template)
        persist()
        return template
    }

    @discardableResult
    func remove(id: WorkspaceTemplate.ID) -> Bool {
        guard let index = templates.firstIndex(where: { $0.id == id }) else { return false }
        templates.remove(at: index)
        persist()
        return true
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(templates) else { return }
        userDefaults.set(data, forKey: storageKey)
    }

    private nonisolated static func sanitized(_ templates: [WorkspaceTemplate]) -> [WorkspaceTemplate] {
        var seenNames: Set<String> = []
        return templates.compactMap { template in
            let name = template.name.trimmingCharacters(in: .whitespacesAndNewlines)
            let normalizedName = String(name.prefix(80))
            let key = normalizedName.lowercased()
            guard !name.isEmpty,
                  LayoutManager.isUsable(template.layoutState),
                  seenNames.insert(key).inserted else { return nil }

            guard normalizedName == template.name else {
                return WorkspaceTemplate(
                    id: template.id,
                    name: normalizedName,
                    layoutState: template.layoutState,
                    savedAt: template.savedAt
                )
            }
            return template
        }
    }
}
