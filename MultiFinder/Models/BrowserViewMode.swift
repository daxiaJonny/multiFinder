import Foundation

enum BrowserViewMode: String, CaseIterable, Codable, Sendable {
    case list
    case icon
    case column
    case gallery

    var localizedName: String {
        switch self {
        case .list:
            return L10n.string("List")
        case .icon:
            return L10n.string("Icons")
        case .column:
            return L10n.string("Columns")
        case .gallery:
            return L10n.string("Gallery")
        }
    }

    var systemImage: String {
        switch self {
        case .list:
            return "list.bullet"
        case .icon:
            return "square.grid.3x3"
        case .column:
            return "rectangle.split.3x1"
        case .gallery:
            return "rectangle.stack"
        }
    }
}
