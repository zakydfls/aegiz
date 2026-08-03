import AppKit
import SwiftUI

struct TerminalSettingsView: View {
    @Environment(\.dismiss) private var dismiss

    let hostAlias: String
    let onSave: (TerminalHostSettings) throws -> Void

    @State private var localWorkingDirectory: String
    @State private var remoteWorkingDirectory: String
    @State private var environmentText: String
    @State private var fontSize: Double
    @State private var startupCommand: String
    @State private var errorText = ""

    init(
        hostAlias: String,
        settings: TerminalHostSettings,
        onSave: @escaping (TerminalHostSettings) throws -> Void
    ) {
        self.hostAlias = hostAlias
        self.onSave = onSave
        _localWorkingDirectory = State(initialValue: settings.localWorkingDirectory)
        _remoteWorkingDirectory = State(initialValue: settings.remoteWorkingDirectory)
        _environmentText = State(initialValue: settings.environmentText)
        _fontSize = State(initialValue: settings.fontSize)
        _startupCommand = State(initialValue: settings.startupCommand)
    }

    var body: some View {
        VStack(spacing: 0) {
            AegizSheetHeader("Terminal settings", subtitle: hostAlias) {
                HStack {
                    Button("Cancel") {
                        dismiss()
                    }
                    Button("Save & Reconnect") {
                        save()
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                }
            }

            Divider()

            Form {
                Section("Directories") {
                    LabeledContent("Local working directory") {
                        HStack {
                            TextField("Inherit current directory", text: $localWorkingDirectory)
                                .textFieldStyle(.roundedBorder)
                            Button("Choose…") {
                                chooseLocalDirectory()
                            }
                        }
                    }
                    LabeledContent("Remote working directory") {
                        TextField("For example /srv/api", text: $remoteWorkingDirectory)
                            .textFieldStyle(.roundedBorder)
                    }
                }

                Section("Appearance") {
                    LabeledContent("Font size") {
                        HStack {
                            Slider(value: $fontSize, in: 0...32, step: 1)
                                .frame(width: 180)
                            Text(fontSize == 0 ? "Inherited font" : "\(Int(fontSize)) pt")
                                .frame(width: 96, alignment: .trailing)
                                .monospacedDigit()
                        }
                    }
                    Text(
                        "Aegiz supplies the embedded terminal palette, cursor, selection, and spacing. Set 0 to inherit the font size from your Ghostty configuration."
                    )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Environment") {
                    TextEditor(text: $environmentText)
                        .font(.system(size: 11).monospaced())
                        .frame(minHeight: 92)
                        .overlay {
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(.separator.opacity(0.65))
                        }
                    Text("One NAME=value per line. Store non-secret values only; use the Vault for credentials.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Remote startup command") {
                    TextEditor(text: $startupCommand)
                        .font(.system(size: 11).monospaced())
                        .frame(minHeight: 92)
                        .overlay {
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(.separator.opacity(0.65))
                        }
                    Text(
                        "Runs after SSH connects. Aegiz sends this as terminal input; it is never executed by a local shell."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

                if !errorText.isEmpty {
                    Label(errorText, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .font(.caption)
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
        }
        .aegizAdaptiveSheet(AegizSheetSizingPolicy.terminalSettings)
        .background(AegizTheme.canvas)
    }

    private func chooseLocalDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.prompt = "Choose"
        if !localWorkingDirectory.isEmpty {
            panel.directoryURL = URL(filePath: localWorkingDirectory)
        }
        if panel.runModal() == .OK, let url = panel.url {
            localWorkingDirectory = url.path
        }
    }

    private func save() {
        do {
            let environment = try TerminalHostSettings.parseEnvironment(environmentText)
            let settings = TerminalHostSettings(
                localWorkingDirectory: localWorkingDirectory,
                remoteWorkingDirectory: remoteWorkingDirectory,
                environment: environment,
                fontSize: fontSize,
                startupCommand: startupCommand
            )
            try onSave(settings)
            dismiss()
        } catch {
            errorText = error.localizedDescription
        }
    }
}
