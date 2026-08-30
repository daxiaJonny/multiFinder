import Darwin
import Foundation
import UniformTypeIdentifiers

public struct POSIXPermissions: Equatable, Hashable, Sendable {
    public let mode: UInt16

    public init(mode: UInt16) throws {
        guard mode <= 0o7777 else {
            throw FileMetadataError.invalidPermissions
        }
        self.mode = mode
    }

    public init(octalString: String) throws {
        let value = octalString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (value.count == 3 || value.count == 4),
              value.unicodeScalars.allSatisfy({ (48...55).contains($0.value) }),
              let mode = UInt16(value, radix: 8) else {
            throw FileMetadataError.invalidPermissions
        }
        try self.init(mode: mode)
    }

    public var octalString: String {
        String(format: "%04o", Int(mode))
    }

    public var symbolicString: String {
        let user = permissionTriplet(
            read: 0o400,
            write: 0o200,
            execute: 0o100,
            special: 0o4000,
            specialCharacter: "s"
        )
        let group = permissionTriplet(
            read: 0o040,
            write: 0o020,
            execute: 0o010,
            special: 0o2000,
            specialCharacter: "s"
        )
        let other = permissionTriplet(
            read: 0o004,
            write: 0o002,
            execute: 0o001,
            special: 0o1000,
            specialCharacter: "t"
        )
        return user + group + other
    }

    private func permissionTriplet(
        read: UInt16,
        write: UInt16,
        execute: UInt16,
        special: UInt16,
        specialCharacter: Character
    ) -> String {
        let readCharacter: Character = mode & read == 0 ? "-" : "r"
        let writeCharacter: Character = mode & write == 0 ? "-" : "w"
        let hasExecute = mode & execute != 0
        let hasSpecial = mode & special != 0
        let executeCharacter: Character
        if hasSpecial {
            executeCharacter = hasExecute
                ? specialCharacter
                : Character(String(specialCharacter).uppercased())
        } else {
            executeCharacter = hasExecute ? "x" : "-"
        }
        return String([readCharacter, writeCharacter, executeCharacter])
    }
}

public struct FileMetadata: Equatable, Identifiable, Sendable {
    public let url: URL
    public let name: String
    public let kind: String
    public let contentTypeIdentifier: String?
    public let byteSize: Int64
    public let creationDate: Date?
    public let modificationDate: Date?
    public let path: String
    public let ownerName: String
    public let groupName: String
    public let ownerID: UInt32
    public let groupID: UInt32
    public let permissions: POSIXPermissions
    public let tags: [String]
    public let isDirectory: Bool
    public let isSymbolicLink: Bool
    public let isPackage: Bool
    public let symbolicLinkDestination: String?

    public var id: URL { url }
    public var size: Int64 { byteSize }
    public var createdDate: Date? { creationDate }
    public var modifiedDate: Date? { modificationDate }

    public init(
        url: URL,
        name: String,
        kind: String,
        contentTypeIdentifier: String?,
        byteSize: Int64,
        creationDate: Date?,
        modificationDate: Date?,
        path: String,
        ownerName: String,
        groupName: String,
        ownerID: UInt32,
        groupID: UInt32,
        permissions: POSIXPermissions,
        tags: [String],
        isDirectory: Bool,
        isSymbolicLink: Bool,
        isPackage: Bool,
        symbolicLinkDestination: String? = nil
    ) {
        self.url = url
        self.name = name
        self.kind = kind
        self.contentTypeIdentifier = contentTypeIdentifier
        self.byteSize = byteSize
        self.creationDate = creationDate
        self.modificationDate = modificationDate
        self.path = path
        self.ownerName = ownerName
        self.groupName = groupName
        self.ownerID = ownerID
        self.groupID = groupID
        self.permissions = permissions
        self.tags = tags
        self.isDirectory = isDirectory
        self.isSymbolicLink = isSymbolicLink
        self.isPackage = isPackage
        self.symbolicLinkDestination = symbolicLinkDestination
    }
}

public enum FileMetadataError: LocalizedError, Sendable {
    case invalidURL
    case itemNotFound(URL)
    case cannotReadMetadata(URL, reason: String)
    case cannotReadTags(URL, reason: String)
    case cannotWriteTags(URL, reason: String)
    case cannotReadPermissions(URL, reason: String)
    case cannotWritePermissions(URL, reason: String)
    case invalidPermissions
    case invalidTag(String)
    case symbolicLinkWriteNotAllowed(URL)
    case unsupportedWriteTarget(URL)

    public var errorDescription: String? {
        switch self {
        case .invalidURL:
            return String(localized: "The item URL is not a local file URL.")
        case .itemNotFound(let url):
            return String(
                format: String(localized: "The item %@ could not be found."),
                locale: Locale.current,
                url.path
            )
        case .cannotReadMetadata(let url, let reason):
            return String(
                format: String(localized: "Unable to read metadata for %@: %@"),
                locale: Locale.current,
                url.path,
                reason
            )
        case .cannotReadTags(let url, let reason):
            return String(
                format: String(localized: "Unable to read tags for %@: %@"),
                locale: Locale.current,
                url.path,
                reason
            )
        case .cannotWriteTags(let url, let reason):
            return String(
                format: String(localized: "Unable to write tags for %@: %@"),
                locale: Locale.current,
                url.path,
                reason
            )
        case .cannotReadPermissions(let url, let reason):
            return String(
                format: String(localized: "Unable to read permissions for %@: %@"),
                locale: Locale.current,
                url.path,
                reason
            )
        case .cannotWritePermissions(let url, let reason):
            return String(
                format: String(localized: "Unable to write permissions for %@: %@"),
                locale: Locale.current,
                url.path,
                reason
            )
        case .invalidPermissions:
            return String(localized: "Permissions must be three or four octal digits from 000 to 7777.")
        case .invalidTag(let tag):
            return String(
                format: String(localized: "The tag %@ is not valid."),
                locale: Locale.current,
                tag
            )
        case .symbolicLinkWriteNotAllowed(let url):
            return String(
                format: String(localized: "Tags and permissions cannot be changed on the symbolic link %@."),
                locale: Locale.current,
                url.lastPathComponent
            )
        case .unsupportedWriteTarget(let url):
            return String(
                format: String(localized: "Tags and permissions cannot be changed for %@."),
                locale: Locale.current,
                url.lastPathComponent
            )
        }
    }
}

public struct FileMetadataService: Sendable {
    public init() {}

    public func metadata(for url: URL) throws -> FileMetadata {
        let normalizedURL = try existingURL(url)
        let metadata = try lstatMetadata(at: normalizedURL, operation: .metadata)
        let isSymbolicLink = isSymbolicLink(metadata.st_mode)
        let isDirectory = !isSymbolicLink && isDirectory(metadata.st_mode)
        let resourceValues = try? normalizedURL.resourceValues(forKeys: [
            .contentTypeKey,
            .isPackageKey
        ])
        let isPackage = isDirectory && (
            resourceValues?.isPackage == true || Self.packageExtensions.contains(normalizedURL.pathExtension.lowercased())
        )
        let attributes = try fileAttributes(at: normalizedURL)
        let permissions = try POSIXPermissions(mode: UInt16(metadata.st_mode & 0o7777))
        let tags = (try? readTags(at: normalizedURL)) ?? []
        let contentType = resourceValues?.contentType
        let kind = Self.kindName(
            for: normalizedURL,
            isDirectory: isDirectory,
            isPackage: isPackage,
            contentType: contentType
        )

        return FileMetadata(
            url: normalizedURL,
            name: normalizedURL.lastPathComponent,
            kind: kind,
            contentTypeIdentifier: contentType?.identifier,
            byteSize: Int64(max(metadata.st_size, 0)),
            creationDate: attributes[.creationDate] as? Date,
            modificationDate: attributes[.modificationDate] as? Date,
            path: normalizedURL.path,
            ownerName: attributes[.ownerAccountName] as? String ?? String(metadata.st_uid),
            groupName: attributes[.groupOwnerAccountName] as? String ?? String(metadata.st_gid),
            ownerID: UInt32(metadata.st_uid),
            groupID: UInt32(metadata.st_gid),
            permissions: permissions,
            tags: tags,
            isDirectory: isDirectory,
            isSymbolicLink: isSymbolicLink,
            isPackage: isPackage,
            symbolicLinkDestination: isSymbolicLink ? try? FileManager().destinationOfSymbolicLink(atPath: normalizedURL.path) : nil
        )
    }

    public func metadata(for urls: [URL]) throws -> [FileMetadata] {
        try urls.map { try metadata(for: $0) }
    }

    public func tags(for url: URL) throws -> [String] {
        try readTags(at: existingURL(url))
    }

    public func permissions(for url: URL) throws -> POSIXPermissions {
        let normalizedURL = try existingURL(url)
        do {
            let metadata = try lstatMetadata(at: normalizedURL, operation: .permissions)
            return try POSIXPermissions(mode: UInt16(metadata.st_mode & 0o7777))
        } catch let error as FileMetadataError {
            throw error
        } catch {
            throw FileMetadataError.cannotReadPermissions(
                normalizedURL,
                reason: Self.reason(for: error)
            )
        }
    }

    @discardableResult
    public func setTags(_ tags: [String], for url: URL) throws -> FileMetadata {
        let updated = try setTags(tags, for: [url])
        return updated[0]
    }

    @discardableResult
    public func setTags(_ tags: [String], for urls: [URL]) throws -> [FileMetadata] {
        let sanitizedTags = try Self.sanitizedTags(tags)
        let normalizedURLs = try urls.map { try writableURL($0) }
        for url in normalizedURLs {
            do {
                try (url as NSURL).setResourceValue(
                    sanitizedTags,
                    forKey: URLResourceKey.tagNamesKey
                )
            } catch {
                throw FileMetadataError.cannotWriteTags(url, reason: Self.reason(for: error))
            }
        }
        return try normalizedURLs.map { try metadata(for: $0) }
    }

    @discardableResult
    public func setPOSIXPermissions(
        _ permissions: POSIXPermissions,
        for url: URL
    ) throws -> FileMetadata {
        let updated = try setPOSIXPermissions(permissions, for: [url])
        return updated[0]
    }

    @discardableResult
    public func setPOSIXPermissions(
        _ permissions: POSIXPermissions,
        for urls: [URL]
    ) throws -> [FileMetadata] {
        // Reconstructing the value validates the public input even if the
        // implementation later gains additional permission-bit rules.
        let validatedPermissions = try POSIXPermissions(mode: permissions.mode)
        let normalizedURLs = try urls.map { try writableURL($0) }

        for url in normalizedURLs {
            let result = url.withUnsafeFileSystemRepresentation { path -> (Int32, Int32) in
                guard let path else { return (-1, EINVAL) }
                let result = Darwin.chmod(path, mode_t(validatedPermissions.mode))
                return (result, result == 0 ? 0 : errno)
            }
            guard result.0 == 0 else {
                throw FileMetadataError.cannotWritePermissions(
                    url,
                    reason: Self.reason(forPOSIXErrorCode: result.1)
                )
            }
        }
        return try normalizedURLs.map { try metadata(for: $0) }
    }

    @discardableResult
    public func setPOSIXPermissions(
        _ octalString: String,
        for url: URL
    ) throws -> FileMetadata {
        try setPOSIXPermissions(POSIXPermissions(octalString: octalString), for: url)
    }

    public static func sanitizedTags(_ tags: [String]) throws -> [String] {
        var result: [String] = []
        var seen = Set<String>()

        for rawTag in tags {
            let tag = rawTag.trimmingCharacters(in: .whitespacesAndNewlines)
            if tag.isEmpty { continue }
            guard tag.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else {
                throw FileMetadataError.invalidTag(tag)
            }
            guard tag.utf8.count <= 255 else {
                throw FileMetadataError.invalidTag(tag)
            }
            if seen.insert(tag).inserted {
                result.append(tag)
            }
        }
        return result
    }

    private enum ReadOperation {
        case metadata
        case permissions
    }

    private static let packageExtensions: Set<String> = [
        "app", "appex", "bundle", "framework", "kext", "mdimporter", "plugin", "qlgenerator", "xpc"
    ]

    private func readTags(at url: URL) throws -> [String] {
        do {
            let values = try url.resourceValues(forKeys: [.tagNamesKey])
            return try Self.sanitizedTags(values.tagNames ?? [])
        } catch {
            throw FileMetadataError.cannotReadTags(url, reason: Self.reason(for: error))
        }
    }

    private func existingURL(_ url: URL) throws -> URL {
        guard url.isFileURL else {
            throw FileMetadataError.invalidURL
        }
        let normalizedURL = url.standardizedFileURL
        _ = try lstatMetadata(at: normalizedURL, operation: .metadata)
        return normalizedURL
    }

    private func writableURL(_ url: URL) throws -> URL {
        let normalizedURL = try existingURL(url)
        let metadata = try lstatMetadata(at: normalizedURL, operation: .metadata)
        if isSymbolicLink(metadata.st_mode) {
            throw FileMetadataError.symbolicLinkWriteNotAllowed(normalizedURL)
        }
        guard isDirectory(metadata.st_mode) || isRegularFile(metadata.st_mode) else {
            throw FileMetadataError.unsupportedWriteTarget(normalizedURL)
        }
        return normalizedURL
    }

    private func fileAttributes(at url: URL) throws -> [FileAttributeKey: Any] {
        do {
            return try FileManager().attributesOfItem(atPath: url.path)
        } catch {
            throw FileMetadataError.cannotReadMetadata(url, reason: Self.reason(for: error))
        }
    }

    private func lstatMetadata(at url: URL, operation: ReadOperation) throws -> stat {
        var metadata = stat()
        let result = url.withUnsafeFileSystemRepresentation { path -> (Int32, Int32) in
            guard let path else { return (-1, EINVAL) }
            let result = Darwin.lstat(path, &metadata)
            return (result, result == 0 ? 0 : errno)
        }

        guard result.0 == 0 else {
            let error = Self.reason(forPOSIXErrorCode: result.1)
            switch operation {
            case .metadata:
                throw FileMetadataError.cannotReadMetadata(url, reason: error)
            case .permissions:
                throw FileMetadataError.cannotReadPermissions(url, reason: error)
            }
        }
        return metadata
    }

    private static func kindName(
        for url: URL,
        isDirectory: Bool,
        isPackage: Bool,
        contentType: UTType?
    ) -> String {
        if isPackage {
            return String(localized: "Package")
        }
        if isDirectory {
            return String(localized: "Folder")
        }
        if let description = contentType?.localizedDescription, !description.isEmpty {
            return description
        }
        return url.pathExtension.isEmpty
            ? String(localized: "File")
            : String(
                format: String(localized: "%@ File"),
                locale: Locale.current,
                url.pathExtension.uppercased()
            )
    }

    private static func reason(for error: Error) -> String {
        (error as NSError).localizedDescription
    }

    private static func reason(forPOSIXErrorCode code: Int32) -> String {
        guard let message = strerror(code) else {
            return String(localized: "Unknown file system error.")
        }
        return String(cString: message)
    }

    private func isDirectory(_ mode: mode_t) -> Bool {
        (mode & S_IFMT) == S_IFDIR
    }

    private func isRegularFile(_ mode: mode_t) -> Bool {
        (mode & S_IFMT) == S_IFREG
    }

    private func isSymbolicLink(_ mode: mode_t) -> Bool {
        (mode & S_IFMT) == S_IFLNK
    }
}
