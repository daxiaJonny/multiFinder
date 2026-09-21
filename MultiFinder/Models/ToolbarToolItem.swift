import Foundation
import SwiftUI

enum ToolbarToolCategory: String, CaseIterable, Identifiable, Sendable {
    case ai = "AI Tools"
    case files = "File Operations"
    case search = "Search & Stash"
    case layout = "Panes & Workspace"

    var id: String { rawValue }

    var localizedTitle: String {
        switch self {
        case .ai:
            return L10n.string("AI Tools")
        case .files:
            return L10n.string("File Actions")
        case .search:
            return L10n.string("Search & Quick Access")
        case .layout:
            return L10n.string("Panes & Layout")
        }
    }
}

enum ToolbarToolID: String, CaseIterable, Identifiable, Codable, Sendable {
    case commandPalette
    case stashShelf
    case aiAssistant
    case arrangePanes
    case search
    case aiOrganize
    case newFolder
    case hiddenFiles
    case terminal
    case paste
    case operationHistory
    case workspaceTemplates
    case favorite

    var id: String { rawValue }

    var category: ToolbarToolCategory {
        switch self {
        case .aiAssistant, .aiOrganize:
            return .ai
        case .newFolder, .paste, .hiddenFiles, .terminal, .favorite:
            return .files
        case .commandPalette, .search, .stashShelf:
            return .search
        case .arrangePanes, .workspaceTemplates, .operationHistory:
            return .layout
        }
    }

    var defaultPinned: Bool {
        switch self {
        case .commandPalette, .stashShelf, .aiAssistant, .arrangePanes:
            return true
        default:
            return false
        }
    }

    var defaultOrder: Int {
        switch self {
        case .commandPalette: return 0
        case .stashShelf: return 1
        case .aiAssistant: return 2
        case .arrangePanes: return 3
        case .search: return 4
        case .aiOrganize: return 5
        case .newFolder: return 6
        case .hiddenFiles: return 7
        case .terminal: return 8
        case .paste: return 9
        case .operationHistory: return 10
        case .workspaceTemplates: return 11
        case .favorite: return 12
        }
    }

    var title: String {
        switch self {
        case .commandPalette: return L10n.string("Command Palette")
        case .stashShelf: return L10n.string("Stash Shelf")
        case .aiAssistant: return L10n.string("Ask About Current Folder")
        case .arrangePanes: return L10n.string("Arrange Panes")
        case .search: return L10n.string("Search")
        case .aiOrganize: return L10n.string("AI Organize")
        case .newFolder: return L10n.string("New Folder")
        case .hiddenFiles: return L10n.string("Toggle Hidden Files")
        case .terminal: return L10n.string("Open in Terminal")
        case .paste: return L10n.string("Paste")
        case .operationHistory: return L10n.string("Operation History")
        case .workspaceTemplates: return L10n.string("Workspace Templates")
        case .favorite: return L10n.string("Favorite")
        }
    }

    var subtitle: String {
        switch self {
        case .commandPalette: return L10n.string("Search commands and navigate")
        case .stashShelf: return L10n.string("Quick drag & drop shelf")
        case .aiAssistant: return L10n.string("Ask AI about current directory")
        case .arrangePanes: return L10n.string("Split panes and manage tabs")
        case .search: return L10n.string("Find files by name or content")
        case .aiOrganize: return L10n.string("Smart organize directory with AI")
        case .newFolder: return L10n.string("Create a new folder")
        case .hiddenFiles: return L10n.string("Show or hide dotfiles")
        case .terminal: return L10n.string("Launch directory in terminal")
        case .paste: return L10n.string("Paste files from clipboard")
        case .operationHistory: return L10n.string("View recent file tasks and retry")
        case .workspaceTemplates: return L10n.string("Save or apply window layouts")
        case .favorite: return L10n.string("Bookmark this location")
        }
    }

    var systemImage: String {
        switch self {
        case .commandPalette: return "command"
        case .stashShelf: return "tray.2.fill"
        case .aiAssistant: return "sparkles"
        case .arrangePanes: return "plus.square.on.square"
        case .search: return "magnifyingglass"
        case .aiOrganize: return "wand.and.stars"
        case .newFolder: return "folder.badge.plus"
        case .hiddenFiles: return "eye"
        case .terminal: return "terminal"
        case .paste: return "doc.on.clipboard"
        case .operationHistory: return "clock.arrow.circlepath"
        case .workspaceTemplates: return "square.grid.2x2"
        case .favorite: return "star"
        }
    }

    var shortcut: String? {
        switch self {
        case .commandPalette: return "⌘K"
        case .stashShelf: return "⌘B"
        case .aiAssistant: return "⌥⌘A"
        case .search: return "⌘F"
        case .newFolder: return "⇧⌘N"
        case .hiddenFiles: return "⇧⌘."
        case .paste: return "⌘V"
        default: return nil
        }
    }
}
