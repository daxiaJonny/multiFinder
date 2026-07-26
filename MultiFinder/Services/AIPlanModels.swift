import Foundation

struct AIPlanRequest: Sendable, Equatable {
    let instruction: String
    let scopeRoot: URL
}

protocol AIPlanner: Sendable {
    func plan(_ request: AIPlanRequest) async throws -> AIPlan
}

struct AIPlan: Codable, Sendable, Equatable {
    enum Kind: String, Codable, Sendable {
        case search
        case organize

        init(from decoder: Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            guard let kind = Kind(rawValue: raw) else {
                throw DecodingError.dataCorrupted(DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "The plan kind “\(raw)” is not supported."
                ))
            }
            self = kind
        }
    }

    let kind: Kind
    let summary: String
    let search: AISearchCriteria?
    let operations: [AIPlanOperation]?
}

struct AISearchCriteria: Codable, Sendable, Hashable {
    var nameContains: [String]?
    var extensions: [String]?
    var modifiedAfter: Date?
    var modifiedBefore: Date?
    var minSize: Int64?
    var maxSize: Int64?
    var recursive: Bool?

    init(
        nameContains: [String]? = nil,
        extensions: [String]? = nil,
        modifiedAfter: Date? = nil,
        modifiedBefore: Date? = nil,
        minSize: Int64? = nil,
        maxSize: Int64? = nil,
        recursive: Bool? = nil
    ) {
        self.nameContains = nameContains
        self.extensions = extensions
        self.modifiedAfter = modifiedAfter
        self.modifiedBefore = modifiedBefore
        self.minSize = minSize
        self.maxSize = maxSize
        self.recursive = recursive
    }

    private enum CodingKeys: String, CodingKey {
        case nameContains, extensions, modifiedAfter, modifiedBefore, minSize, maxSize, recursive
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        nameContains = try container.decodeIfPresent([String].self, forKey: .nameContains)
        extensions = try container.decodeIfPresent([String].self, forKey: .extensions)
        modifiedAfter = try Self.decodeDate(from: container, forKey: .modifiedAfter)
        modifiedBefore = try Self.decodeDate(from: container, forKey: .modifiedBefore)
        minSize = try container.decodeIfPresent(Int64.self, forKey: .minSize)
        maxSize = try container.decodeIfPresent(Int64.self, forKey: .maxSize)
        recursive = try container.decodeIfPresent(Bool.self, forKey: .recursive)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(nameContains, forKey: .nameContains)
        try container.encodeIfPresent(extensions, forKey: .extensions)
        try container.encodeIfPresent(modifiedAfter.map(Self.isoDayString), forKey: .modifiedAfter)
        try container.encodeIfPresent(modifiedBefore.map(Self.isoDayString), forKey: .modifiedBefore)
        try container.encodeIfPresent(minSize, forKey: .minSize)
        try container.encodeIfPresent(maxSize, forKey: .maxSize)
        try container.encodeIfPresent(recursive, forKey: .recursive)
    }

    static func isoDate(from string: String) -> Date? {
        let dayFormatter = ISO8601DateFormatter()
        dayFormatter.formatOptions = [.withFullDate]
        if let date = dayFormatter.date(from: string) {
            return date
        }
        return ISO8601DateFormatter().date(from: string)
    }

    static func isoDayString(from date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate]
        return formatter.string(from: date)
    }

    private static func decodeDate(
        from container: KeyedDecodingContainer<CodingKeys>,
        forKey key: CodingKeys
    ) throws -> Date? {
        guard let string = try container.decodeIfPresent(String.self, forKey: key) else {
            return nil
        }
        guard let date = isoDate(from: string) else {
            throw DecodingError.dataCorruptedError(
                forKey: key,
                in: container,
                debugDescription: "The date “\(string)” is not a valid ISO date (expected YYYY-MM-DD)."
            )
        }
        return date
    }
}

enum AIPlanOperation: Codable, Sendable, Hashable {
    case createFolder(path: String)
    case move(source: String, destination: String)
    case copy(source: String, destination: String)
    case rename(source: String, newName: String)
    case trash(source: String)

    private enum CodingKeys: String, CodingKey {
        case op, path, source, destination, newName
    }

    var opName: String {
        switch self {
        case .createFolder: return "createFolder"
        case .move: return "move"
        case .copy: return "copy"
        case .rename: return "rename"
        case .trash: return "trash"
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let op = try container.decode(String.self, forKey: .op)
        switch op {
        case "createFolder":
            self = .createFolder(path: try container.decode(String.self, forKey: .path))
        case "move":
            self = .move(
                source: try container.decode(String.self, forKey: .source),
                destination: try container.decode(String.self, forKey: .destination)
            )
        case "copy":
            self = .copy(
                source: try container.decode(String.self, forKey: .source),
                destination: try container.decode(String.self, forKey: .destination)
            )
        case "rename":
            self = .rename(
                source: try container.decode(String.self, forKey: .source),
                newName: try container.decode(String.self, forKey: .newName)
            )
        case "trash":
            self = .trash(source: try container.decode(String.self, forKey: .source))
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .op,
                in: container,
                debugDescription: "The operation “\(op)” is not supported."
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(opName, forKey: .op)
        switch self {
        case .createFolder(let path):
            try container.encode(path, forKey: .path)
        case .move(let source, let destination), .copy(let source, let destination):
            try container.encode(source, forKey: .source)
            try container.encode(destination, forKey: .destination)
        case .rename(let source, let newName):
            try container.encode(source, forKey: .source)
            try container.encode(newName, forKey: .newName)
        case .trash(let source):
            try container.encode(source, forKey: .source)
        }
    }
}

struct AIPlanParseError: LocalizedError, Sendable, Equatable {
    let message: String

    var errorDescription: String? { message }
}

extension AIPlan {
    static func parse(from text: String) throws -> AIPlan {
        let json = try extractJSONObject(from: text)
        let plan: AIPlan
        do {
            plan = try JSONDecoder().decode(AIPlan.self, from: Data(json.utf8))
        } catch let error as DecodingError {
            throw AIPlanParseError(message: message(for: error))
        } catch {
            throw AIPlanParseError(message: "The AI plan could not be read: \(error.localizedDescription)")
        }

        switch plan.kind {
        case .search:
            guard plan.search != nil else {
                throw AIPlanParseError(message: "The search plan is missing its “search” criteria.")
            }
        case .organize:
            guard let operations = plan.operations, !operations.isEmpty else {
                throw AIPlanParseError(message: "The organize plan does not contain any operations.")
            }
        }
        return plan
    }

    private static func extractJSONObject(from text: String) throws -> String {
        guard let start = text.firstIndex(of: "{") else {
            throw AIPlanParseError(message: "The AI response did not contain a JSON plan.")
        }
        var depth = 0
        var inString = false
        var isEscaped = false
        var index = start
        while index < text.endIndex {
            let character = text[index]
            if isEscaped {
                isEscaped = false
            } else if inString {
                if character == "\\" {
                    isEscaped = true
                } else if character == "\"" {
                    inString = false
                }
            } else {
                switch character {
                case "\"":
                    inString = true
                case "{":
                    depth += 1
                case "}":
                    depth -= 1
                    if depth == 0 {
                        return String(text[start...index])
                    }
                default:
                    break
                }
            }
            index = text.index(after: index)
        }
        throw AIPlanParseError(message: "The AI response contained an incomplete JSON plan.")
    }

    private static func message(for error: DecodingError) -> String {
        switch error {
        case .keyNotFound(let key, let context):
            return "The plan is missing the required field “\(fieldPath(context.codingPath, key))”."
        case .valueNotFound(_, let context):
            return "The plan field “\(fieldPath(context.codingPath))” has no value."
        case .typeMismatch(_, let context):
            return "The plan field “\(fieldPath(context.codingPath))” has the wrong type."
        case .dataCorrupted(let context):
            return context.debugDescription.isEmpty
                ? "The AI response is not valid JSON."
                : context.debugDescription
        @unknown default:
            return "The AI plan could not be read."
        }
    }

    private static func fieldPath(_ path: [CodingKey], _ key: CodingKey? = nil) -> String {
        let components = (path + [key].compactMap { $0 }).map { component in
            component.intValue.map { "[\($0)]" } ?? component.stringValue
        }
        return components.joined(separator: ".").replacingOccurrences(of: ".[", with: "[")
    }
}
