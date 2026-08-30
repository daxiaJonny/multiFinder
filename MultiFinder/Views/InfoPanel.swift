import AppKit
import SwiftUI

public typealias InfoPanelRenameHandler = @MainActor (_ url: URL, _ newName: String) -> Void
public typealias InfoPanelCloseHandler = @MainActor () -> Void

@MainActor
public struct InfoPanel: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model: InfoPanelModel
    private let onClose: InfoPanelCloseHandler?

    public init(
        urls: [URL],
        metadataService: FileMetadataService = FileMetadataService(),
        directorySizeCalculator: DirectorySizeCalculator = DirectorySizeCalculator(),
        onRename: InfoPanelRenameHandler? = nil,
        onClose: InfoPanelCloseHandler? = nil
    ) {
        self.onClose = onClose
        _model = StateObject(
            wrappedValue: InfoPanelModel(
                urls: urls,
                metadataService: metadataService,
                directorySizeCalculator: directorySizeCalculator,
                onRename: onRename
            )
        )
    }

    public var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            content

            Divider()
            footer
        }
        .frame(minWidth: 520, idealWidth: 580, minHeight: 520, idealHeight: 650)
        .task {
            model.loadIfNeeded()
        }
        .onDisappear {
            model.cancel()
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            if let image = model.icon {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 56, height: 56)
                    .accessibilityHidden(true)
            } else {
                Image(systemName: model.isMultiple ? "doc.on.doc" : "doc")
                    .font(.system(size: 38, weight: .regular))
                    .foregroundStyle(.secondary)
                    .frame(width: 56, height: 56)
                    .accessibilityHidden(true)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(model.title)
                    .font(.title3.weight(.semibold))
                    .lineLimit(2)
                if let subtitle = model.subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
    }

    @ViewBuilder
    private var content: some View {
        if let errorMessage = model.errorMessage, model.metadata.isEmpty {
            VStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.title2)
                    .foregroundStyle(.secondary)
                Text(errorMessage)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                Button("Retry") {
                    model.reload()
                }
                .keyboardShortcut(.defaultAction)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(24)
        } else if model.metadata.isEmpty {
            VStack(spacing: 12) {
                ProgressView()
                    .controlSize(.small)
                Text("Reading item information...")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    overviewSection
                    detailsSection
                    sizeSection
                    permissionsSection
                    tagsSection
                    flagsSection
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(20)
            }
        }
    }

    private var overviewSection: some View {
        inspectorSection("Overview") {
            if !model.isMultiple, model.onRename != nil {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    rowLabel("Name")
                    TextField("Name", text: $model.nameDraft)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit {
                            if model.applyName() {
                                closePanel()
                            }
                        }
                    Button("Rename") {
                        if model.applyName() {
                            closePanel()
                        }
                    }
                    .disabled(!model.canApplyName)
                }
            } else {
                inspectorRow("Name") {
                    Text(model.displayName)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
            }

            inspectorRow(model.isMultiple ? "Selected" : "Kind") {
                Text(model.isMultiple ? model.selectedCountText : model.kindText)
                    .foregroundStyle(.primary)
            }

            if model.isMultiple {
                inspectorRow("Kind") {
                    Text(model.commonKindText)
                        .foregroundStyle(.primary)
                }
            }
        }
    }

    private var detailsSection: some View {
        inspectorSection("Details") {
            if !model.isMultiple {
                inspectorRow("Created") {
                    Text(model.creationDateText)
                }
                inspectorRow("Modified") {
                    Text(model.modificationDateText)
                }
            } else {
                inspectorRow("Location") {
                    Text(model.commonParentText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
            }

            inspectorRow("Path") {
                Text(model.pathText)
                    .lineLimit(3)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }

            if !model.isMultiple, let contentType = model.contentTypeIdentifier {
                inspectorRow("Content Type") {
                    Text(contentType)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }

            if !model.isMultiple {
                inspectorRow("Owner") {
                    Text(model.ownerText)
                }
                inspectorRow("Group") {
                    Text(model.groupText)
                }
            }
        }
    }

    private var sizeSection: some View {
        inspectorSection("Size") {
            inspectorRow(model.isMultiple ? "Total Size" : "Size") {
                VStack(alignment: .leading, spacing: 3) {
                    Text(model.sizeText)
                    if let progressText = model.sizeProgressText {
                        HStack(spacing: 8) {
                            if model.isCalculatingSize {
                                ProgressView()
                                    .controlSize(.small)
                            }
                            Text(progressText)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    if let sizeError = model.sizeError {
                        Text(sizeError)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .textSelection(.enabled)
                    }
                }
            }

            if let result = model.sizeResult, !model.isMultiple, model.isDirectory {
                inspectorRow("Contains") {
                    Text(L10n.format("%lld items", Int64(result.itemCount)))
                }
            }

            if model.isCalculatingSize {
                HStack {
                    Spacer(minLength: 0)
                    Button("Cancel") {
                        model.cancelSizeCalculation()
                    }
                    .controlSize(.small)
                }
            } else if model.sizeResult?.skippedItemCount ?? 0 > 0 {
                inspectorRow("Skipped") {
                    Text(L10n.format("%lld items", Int64(model.sizeResult?.skippedItemCount ?? 0)))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var permissionsSection: some View {
        inspectorSection("Permissions") {
            inspectorRow("POSIX") {
                HStack(spacing: 8) {
                    TextField(
                        model.permissionsAreMixed ? "Multiple values" : "0644",
                        text: permissionBinding
                    )
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 92)
                    .monospacedDigit()

                    Text(model.symbolicPermissionsText)
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(.secondary)

                    Button("Apply") {
                        model.applyPermissions()
                    }
                    .disabled(!model.canApplyPermissions)
                }
            }
            if let permissionsError = model.permissionsError {
                Text(permissionsError)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
        }
    }

    private var tagsSection: some View {
        inspectorSection("Tags") {
            inspectorRow("Tags") {
                HStack(spacing: 8) {
                    TextField(
                        model.tagsAreMixed ? "Multiple values" : "Tags, separated by commas",
                        text: tagBinding
                    )
                    .textFieldStyle(.roundedBorder)

                    Button("Apply") {
                        model.applyTags()
                    }
                    .disabled(!model.canApplyTags)
                }
            }
            if let tagsError = model.tagsError {
                Text(tagsError)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
        }
    }

    private var flagsSection: some View {
        inspectorSection("Flags") {
            inspectorRow("Status") {
                Text(model.flagsText)
                    .foregroundStyle(.secondary)
            }

            if !model.isMultiple, let destination = model.symbolicLinkDestination {
                inspectorRow("Link Target") {
                    Text(destination)
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
            }
        }
    }

    private var footer: some View {
        HStack {
            if model.isApplyingChanges {
                ProgressView()
                    .controlSize(.small)
                Text("Applying...")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Button("Done") {
                closePanel()
            }
            .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    private var tagBinding: Binding<String> {
        Binding(
            get: { model.tagDraft },
            set: {
                model.tagDraft = $0
                model.tagDraftIsDirty = true
                model.tagsError = nil
            }
        )
    }

    private func closePanel() {
        model.cancel()
        if let onClose {
            onClose()
        } else {
            dismiss()
        }
    }

    private var permissionBinding: Binding<String> {
        Binding(
            get: { model.permissionDraft },
            set: {
                model.permissionDraft = $0
                model.permissionDraftIsDirty = true
                model.permissionsError = nil
            }
        )
    }

    private func inspectorSection<Content: View>(
        _ title: LocalizedStringKey,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(title)
                .font(.headline)
            VStack(alignment: .leading, spacing: 8, content: content)
        }
    }

    private func inspectorRow<Content: View>(
        _ label: LocalizedStringKey,
        @ViewBuilder value: () -> Content
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            rowLabel(label)
            value()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func rowLabel(_ label: LocalizedStringKey) -> some View {
        Text(label)
            .foregroundStyle(.secondary)
            .frame(width: 92, alignment: .trailing)
    }
}

@MainActor
private final class InfoPanelModel: ObservableObject {
    let metadataService: FileMetadataService
    let directorySizeCalculator: DirectorySizeCalculator
    let onRename: InfoPanelRenameHandler?
    let urls: [URL]

    @Published private(set) var metadata: [FileMetadata] = []
    @Published private(set) var errorMessage: String?
    @Published private(set) var sizeResult: DirectorySizeResult?
    @Published private(set) var sizeProgress: DirectorySizeProgress?
    @Published private(set) var sizeError: String?
    @Published private(set) var isCalculatingSize = false
    @Published private(set) var isApplyingChanges = false
    @Published var nameDraft = ""
    @Published var tagDraft = ""
    @Published var permissionDraft = ""
    @Published var tagDraftIsDirty = false
    @Published var permissionDraftIsDirty = false
    @Published var tagsError: String?
    @Published var permissionsError: String?

    private var hasLoaded = false
    private var metadataTask: Task<Void, Never>?
    private var sizeTask: Task<Void, Never>?
    private var mutationTask: Task<Void, Never>?

    init(
        urls: [URL],
        metadataService: FileMetadataService,
        directorySizeCalculator: DirectorySizeCalculator,
        onRename: InfoPanelRenameHandler?
    ) {
        var seen = Set<URL>()
        self.urls = urls
            .filter(\.isFileURL)
            .map(\.standardizedFileURL)
            .filter { seen.insert($0).inserted }
        self.metadataService = metadataService
        self.directorySizeCalculator = directorySizeCalculator
        self.onRename = onRename
    }

    var isMultiple: Bool {
        urls.count > 1
    }

    var title: String {
        if isMultiple {
            return L10n.format("%lld Items", Int64(urls.count))
        }
        return metadata.first?.name ?? urls.first?.lastPathComponent ?? String(localized: "Get Info")
    }

    var subtitle: String? {
        guard isMultiple == false else { return nil }
        return metadata.first?.path
    }

    var icon: NSImage? {
        guard let url = urls.first else { return nil }
        let image = NSWorkspace.shared.icon(forFile: url.path)
        image.size = NSSize(width: 56, height: 56)
        return image
    }

    var displayName: String {
        if isMultiple {
            return L10n.format("%lld selected items", Int64(urls.count))
        }
        return metadata.first?.name ?? urls.first?.lastPathComponent ?? ""
    }

    var selectedCountText: String {
        L10n.format("%lld items", Int64(urls.count))
    }

    var isDirectory: Bool {
        metadata.first?.isDirectory == true
    }

    var kindText: String {
        metadata.first?.kind ?? String(localized: "Unknown")
    }

    var commonKindText: String {
        guard let first = metadata.first?.kind,
              metadata.dropFirst().allSatisfy({ $0.kind == first }) else {
            return String(localized: "Multiple kinds")
        }
        return first
    }

    var commonParentText: String {
        guard let first = metadata.first?.url.deletingLastPathComponent().path,
              metadata.dropFirst().allSatisfy({
                  $0.url.deletingLastPathComponent().path == first
              }) else {
            return String(localized: "Multiple locations")
        }
        return first
    }

    var pathText: String {
        if isMultiple {
            return commonParentText
        }
        return metadata.first?.path ?? urls.first?.path ?? ""
    }

    var contentTypeIdentifier: String? {
        metadata.first?.contentTypeIdentifier
    }

    var creationDateText: String {
        dateText(metadata.first?.creationDate)
    }

    var modificationDateText: String {
        dateText(metadata.first?.modificationDate)
    }

    var ownerText: String {
        guard let item = metadata.first else { return "" }
        return "\(item.ownerName) (UID \(item.ownerID))"
    }

    var groupText: String {
        guard let item = metadata.first else { return "" }
        return "\(item.groupName) (GID \(item.groupID))"
    }

    var sizeText: String {
        guard let sizeResult else {
            if isCalculatingSize { return String(localized: "Calculating...") }
            return String(localized: "Not available")
        }
        return Self.byteCountText(sizeResult.byteCount)
    }

    var sizeProgressText: String? {
        guard isCalculatingSize, let sizeProgress else { return nil }
        if sizeProgress.processedItemCount == 1 {
            return String(localized: "1 item inspected")
        }
        return L10n.format(
            "%lld items inspected",
            Int64(sizeProgress.processedItemCount)
        )
    }

    var tagsAreMixed: Bool {
        guard let first = metadata.first?.tags else { return false }
        return metadata.dropFirst().contains { $0.tags != first }
    }

    var permissionsAreMixed: Bool {
        guard let first = metadata.first?.permissions else { return false }
        return metadata.dropFirst().contains { $0.permissions != first }
    }

    var symbolicPermissionsText: String {
        guard let first = metadata.first?.permissions else { return "" }
        guard metadata.dropFirst().allSatisfy({ $0.permissions == first }) else {
            return String(localized: "Multiple values")
        }
        return first.symbolicString
    }

    @Published private(set) var renameWasSubmitted = false

    var canApplyName: Bool {
        guard !renameWasSubmitted,
              !isMultiple,
              onRename != nil,
              let currentName = metadata.first?.name else {
            return false
        }
        let name = nameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        return name != currentName && Self.isValidFileName(name)
    }

    var canApplyTags: Bool {
        guard tagDraftIsDirty, !metadata.isEmpty else { return false }
        return (try? parsedTags()) != nil
    }

    var canApplyPermissions: Bool {
        guard permissionDraftIsDirty, !metadata.isEmpty else { return false }
        return (try? POSIXPermissions(octalString: permissionDraft)) != nil
    }

    var flagsText: String {
        guard let first = metadata.first else { return "" }
        let firstFlags = Self.flags(for: first)
        guard metadata.dropFirst().allSatisfy({ Self.flags(for: $0) == firstFlags }) else {
            return String(localized: "Mixed")
        }
        return firstFlags.isEmpty ? String(localized: "None") : firstFlags.joined(separator: ", ")
    }

    var symbolicLinkDestination: String? {
        metadata.first?.symbolicLinkDestination
    }

    func loadIfNeeded() {
        guard !hasLoaded else { return }
        load()
    }

    func load() {
        guard !urls.isEmpty else {
            errorMessage = String(localized: "No items were selected.")
            hasLoaded = true
            return
        }

        cancelTasks()
        hasLoaded = true
        errorMessage = nil
        metadata = []
        sizeResult = nil
        sizeProgress = nil
        sizeError = nil
        isCalculatingSize = false

        let service = metadataService
        let urls = self.urls
        metadataTask = Task { @MainActor [weak self] in
            do {
                let values = try await Task.detached(priority: .userInitiated) {
                    try service.metadata(for: urls)
                }.value
                try Task.checkCancellation()
                guard let self else { return }
                metadata = values
                prepareDrafts()
                startSizeCalculation()
            } catch is CancellationError {
                return
            } catch {
                self?.errorMessage = error.localizedDescription
            }
        }
    }

    func reload() {
        hasLoaded = false
        load()
    }

    func cancel() {
        cancelTasks()
    }

    func cancelSizeCalculation() {
        sizeTask?.cancel()
        sizeTask = nil
        isCalculatingSize = false
    }

    @discardableResult
    func applyName() -> Bool {
        guard canApplyName, let item = metadata.first, let onRename else { return false }
        let name = nameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        nameDraft = name
        renameWasSubmitted = true
        onRename(item.url, name)
        return true
    }

    func applyTags() {
        guard canApplyTags else { return }
        let tags: [String]
        do {
            tags = try parsedTags()
        } catch {
            tagsError = error.localizedDescription
            return
        }
        beginMutation()

        let service = metadataService
        let urls = self.urls
        mutationTask = Task { @MainActor [weak self] in
            do {
                let updated = try await Task.detached(priority: .userInitiated) {
                    try service.setTags(tags, for: urls)
                }.value
                try Task.checkCancellation()
                guard let self else { return }
                metadata = updated
                tagDraftIsDirty = false
                tagsError = nil
                finishMutation()
            } catch is CancellationError {
                self?.finishMutation()
            } catch {
                self?.tagsError = error.localizedDescription
                self?.finishMutation()
            }
        }
    }

    func applyPermissions() {
        guard canApplyPermissions else { return }
        let permissions: POSIXPermissions
        do {
            permissions = try POSIXPermissions(octalString: permissionDraft)
        } catch {
            permissionsError = error.localizedDescription
            return
        }
        beginMutation()

        let service = metadataService
        let urls = self.urls
        mutationTask = Task { @MainActor [weak self] in
            do {
                let updated = try await Task.detached(priority: .userInitiated) {
                    try service.setPOSIXPermissions(permissions, for: urls)
                }.value
                try Task.checkCancellation()
                guard let self else { return }
                metadata = updated
                permissionDraft = permissions.octalString
                permissionDraftIsDirty = false
                permissionsError = nil
                finishMutation()
            } catch is CancellationError {
                self?.finishMutation()
            } catch {
                self?.permissionsError = error.localizedDescription
                self?.finishMutation()
            }
        }
    }

    private func prepareDrafts() {
        guard let first = metadata.first else { return }
        nameDraft = metadata.count == 1 ? first.name : ""
        tagDraft = commonTags.joined(separator: ", ")
        permissionDraft = permissionsAreMixed ? "" : first.permissions.octalString
        tagDraftIsDirty = false
        permissionDraftIsDirty = false
        tagsError = nil
        permissionsError = nil
        renameWasSubmitted = false
    }

    private var commonTags: [String] {
        guard let first = metadata.first?.tags else { return [] }
        return first.filter { tag in
            metadata.dropFirst().allSatisfy { $0.tags.contains(tag) }
        }
    }

    private func parsedTags() throws -> [String] {
        let components = tagDraft.split(separator: ",", omittingEmptySubsequences: false)
            .map(String.init)
        return try FileMetadataService.sanitizedTags(components)
    }

    private func beginMutation() {
        mutationTask?.cancel()
        isApplyingChanges = true
        tagsError = nil
        permissionsError = nil
    }

    private func finishMutation() {
        isApplyingChanges = false
        mutationTask = nil
    }

    private func startSizeCalculation() {
        guard !urls.isEmpty else { return }
        sizeTask?.cancel()
        isCalculatingSize = true
        sizeResult = nil
        sizeProgress = nil
        sizeError = nil

        let (stream, continuation) = AsyncStream<DirectorySizeProgress>.makeStream()
        let calculator = directorySizeCalculator
        let urls = self.urls
        let worker = Task<DirectorySizeResult, Error> {
            defer { continuation.finish() }
            return try await calculator.calculate(urls: urls) { progress in
                continuation.yield(progress)
            }
        }

        sizeTask = Task { @MainActor [weak self] in
            do {
                let result = try await withTaskCancellationHandler {
                    for await progress in stream {
                        try Task.checkCancellation()
                        self?.sizeProgress = progress
                    }
                    return try await worker.value
                } onCancel: {
                    worker.cancel()
                }
                guard let self else { return }
                sizeResult = result
                isCalculatingSize = false
                sizeTask = nil
            } catch is CancellationError {
                self?.isCalculatingSize = false
                self?.sizeTask = nil
            } catch {
                self?.sizeError = error.localizedDescription
                self?.isCalculatingSize = false
                self?.sizeTask = nil
            }
        }
    }

    private func cancelTasks() {
        metadataTask?.cancel()
        sizeTask?.cancel()
        mutationTask?.cancel()
        metadataTask = nil
        sizeTask = nil
        mutationTask = nil
        isCalculatingSize = false
        isApplyingChanges = false
    }

    private static func byteCountText(_ byteCount: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.includesCount = true
        formatter.includesUnit = true
        return formatter.string(fromByteCount: byteCount)
    }

    private func dateText(_ date: Date?) -> String {
        guard let date else { return String(localized: "Unknown") }
        return date.formatted(date: .abbreviated, time: .shortened)
    }

    private static func isValidFileName(_ name: String) -> Bool {
        guard !name.isEmpty, name != ".", name != ".." else { return false }
        return name.unicodeScalars.allSatisfy { scalar in
            scalar.value != 0 && scalar.value != 47
        }
    }

    private static func flags(for item: FileMetadata) -> [String] {
        var flags: [String] = []
        if item.isSymbolicLink { flags.append(String(localized: "Symbolic Link")) }
        if item.isPackage { flags.append(String(localized: "Package")) }
        if item.isDirectory { flags.append(String(localized: "Directory")) }
        return flags
    }
}
