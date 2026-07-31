import AppKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor
struct SettingsView: View {
    @ObservedObject var settings: AppSettings

    init(settings: AppSettings? = nil) {
        self.settings = settings ?? .shared
    }

    var body: some View {
        Form {
            Section("General") {
                Toggle("Show Hidden Files in New Windows", isOn: $settings.showHiddenFilesByDefault)
            }

            Section("External Applications") {
                Picker("Text Editor", selection: $settings.preferredEditorApplication) {
                    ForEach(PreferredEditorApplication.allCases) { application in
                        Text(application.displayName).tag(application)
                    }
                }

                if settings.preferredEditorApplication == .custom {
                    applicationPathRow
                }

                Picker("Terminal", selection: $settings.preferredTerminalApplication) {
                    ForEach(PreferredTerminalApplication.allCases) { application in
                        Text(application.displayName).tag(application)
                    }
                }
            }

            Section("AI") {
                HStack {
                    TextField("Cursor CLI Executable Path", text: $settings.cursorCLIExecutablePath)
                        .textFieldStyle(.roundedBorder)
                    Button("Choose…", action: chooseCursorCLI)
                }
            }

            HStack {
                Spacer()
                Button("Restore Defaults", action: settings.restoreDefaults)
            }
        }
        .formStyle(.grouped)
        .frame(width: 560)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var applicationPathRow: some View {
        HStack {
            TextField("Application Path", text: $settings.customEditorApplicationPath)
                .textFieldStyle(.roundedBorder)
            Button("Choose…", action: chooseEditorApplication)
        }
    }

    private func chooseEditorApplication() {
        let panel = NSOpenPanel()
        panel.title = L10n.string("Choose Text Editor")
        panel.prompt = L10n.string("Choose")
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.applicationBundle]
        panel.directoryURL = editorApplicationDirectory

        guard panel.runModal() == .OK, let url = panel.url else { return }
        settings.customEditorApplicationPath = url.standardizedFileURL.path
    }

    private func chooseCursorCLI() {
        let panel = NSOpenPanel()
        panel.title = L10n.string("Choose Cursor CLI Executable")
        panel.prompt = L10n.string("Choose")
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.item]
        panel.directoryURL = cursorCLIDirectory

        guard panel.runModal() == .OK, let url = panel.url else { return }
        settings.cursorCLIExecutablePath = url.standardizedFileURL.path
    }

    private var editorApplicationDirectory: URL? {
        let path = settings.customEditorApplicationPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else { return URL(fileURLWithPath: "/Applications", isDirectory: true) }
        return URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
            .deletingLastPathComponent()
    }

    private var cursorCLIDirectory: URL? {
        let path = settings.cursorCLIExecutablePath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else { return FileManager.default.homeDirectoryForCurrentUser }
        return URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
            .deletingLastPathComponent()
    }
}
