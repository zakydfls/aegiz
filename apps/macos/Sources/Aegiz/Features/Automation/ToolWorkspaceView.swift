import SwiftUI

struct ToolWorkspaceView: View {
    @Bindable var model: AppModel
    let title: String
    let symbol: String
    let adapterIDs: [String]
    let summary: String
    let presets: [String: [ToolPreset]]

    @State private var selectedAdapterID: String
    @State private var commandText = ""
    @State private var workingDirectory = ""
    @State private var pendingArguments: [String] = []
    @State private var showingMutationConfirmation = false

    init(
        model: AppModel,
        title: String,
        symbol: String,
        adapterIDs: [String],
        summary: String,
        presets: [String: [ToolPreset]]
    ) {
        self.model = model
        self.title = title
        self.symbol = symbol
        self.adapterIDs = adapterIDs
        self.summary = summary
        self.presets = presets
        _selectedAdapterID = State(initialValue: adapterIDs.first ?? "")
    }

    private var capability: ToolCapabilityModel? {
        model.capability(selectedAdapterID)
    }

    private var operation: ToolOperationModel? {
        guard model.toolOperation?.adapterID == selectedAdapterID else { return nil }
        return model.toolOperation
    }

    var body: some View {
        VStack(spacing: 0) {
            workspaceHeader
            Divider()
            capabilityBar
            Divider()
            if capability?.available == true {
                commandWorkspace
            } else {
                missingCapability
            }
        }
        .background(AegizTheme.raised)
        .navigationTitle(title)
        .confirmationDialog(
            "Run an infrastructure-changing command?",
            isPresented: $showingMutationConfirmation,
            titleVisibility: .visible
        ) {
            Button("Run Command", role: .destructive) {
                run(arguments: pendingArguments, confirmedMutation: true)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                "Aegiz will run \(capability?.label ?? selectedAdapterID) directly, without a local shell. Review the active context, account, and arguments first."
            )
        }
    }

    private var workspaceHeader: some View {
        AegizPageHeader(title, subtitle: summary, symbol: symbol) {
            if adapterIDs.count > 1 {
                Picker("Adapter", selection: $selectedAdapterID) {
                    ForEach(adapterIDs, id: \.self) { id in
                        Text(model.capability(id)?.label ?? id).tag(id)
                    }
                }
                .labelsHidden()
                .frame(width: 180)
            }
        }
    }

    @ViewBuilder
    private var capabilityBar: some View {
        HStack(spacing: 8) {
            if let capability {
                Image(
                    systemName: capability.available
                        ? "checkmark.circle.fill"
                        : "exclamationmark.triangle.fill"
                )
                .foregroundStyle(capability.available ? .green : .orange)
                Text(capability.available ? "Available" : "Not installed")
                    .font(.system(size: 11, weight: .semibold))
                if !capability.version.isEmpty {
                    Text(capability.version)
                        .font(.system(size: 10).monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                if !capability.executablePath.isEmpty {
                    Text(capability.executablePath)
                        .font(.system(size: 10).monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .lineLimit(1)
                }
            } else {
                ProgressView()
                    .controlSize(.small)
                Text("Detecting local capability")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Spacer()
            }
        }
        .padding(.horizontal, 16)
        .frame(height: 36)
        .background(AegizTheme.canvas.opacity(0.55))
    }

    private var commandWorkspace: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Text(selectedAdapterID)
                        .font(.system(size: 12, weight: .semibold).monospaced())
                        .foregroundStyle(AegizTheme.accent)
                    TextField("arguments", text: $commandText)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12).monospaced())
                        .onSubmit { prepareRun() }
                    if operation?.isRunning == true {
                        Button("Cancel", role: .destructive) {
                            Task { await model.cancelToolOperation() }
                        }
                    } else {
                        Button("Run") {
                            prepareRun()
                        }
                        .keyboardShortcut(.return, modifiers: .command)
                        .disabled(commandText.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
                .padding(.horizontal, 10)
                .frame(height: 34)
                .background(AegizTheme.canvas, in: RoundedRectangle(cornerRadius: 6))

                HStack(spacing: 8) {
                    Text("Quick")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                    ForEach(presets[selectedAdapterID] ?? []) { preset in
                        Button(preset.title) {
                            commandText = preset.arguments
                        }
                        .buttonStyle(.borderless)
                        .font(.system(size: 10))
                    }
                    Spacer()
                    TextField("Working directory (optional absolute path)", text: $workingDirectory)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 10).monospaced())
                        .frame(maxWidth: 310)
                }
            }
            .padding(12)
            Divider()
            operationConsole
        }
    }

    private var operationConsole: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Operation output")
                    .font(.system(size: 11, weight: .semibold))
                if let operation {
                    StatusPill(
                        label: operation.phase.capitalized,
                        success: operation.success,
                        running: operation.isRunning
                    )
                }
                Spacer()
                if let exitCode = operation?.exitCode {
                    Text("exit \(exitCode)")
                        .font(.system(size: 10).monospaced())
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 12)
            .frame(height: 34)
            ScrollView([.vertical, .horizontal]) {
                Text(operation?.output.isEmpty == false ? operation?.output ?? "" : emptyConsoleText)
                    .font(.system(size: 11).monospaced())
                    .foregroundStyle(operation?.output.isEmpty == false ? .primary : .secondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding(12)
            }
            .background(Color(nsColor: .textBackgroundColor))
        }
    }

    private var emptyConsoleText: String {
        "Choose a quick command or enter arguments above. Aegiz streams stdout and stderr here and records only a redacted summary in the local audit log."
    }

    private var missingCapability: some View {
        ContentUnavailableView {
            Label("\(capability?.label ?? selectedAdapterID) is unavailable", systemImage: symbol)
        } description: {
            Text(
                capability?.diagnostic.isEmpty == false
                    ? capability?.diagnostic ?? ""
                    : "Install the CLI in /opt/homebrew/bin or /usr/local/bin, then refresh capabilities."
            )
        } actions: {
            Button("Refresh") {
                Task { await model.refresh() }
            }
        }
    }

    private func prepareRun() {
        do {
            let arguments = try CommandLineTokenizer.parse(commandText)
            guard !arguments.isEmpty else { return }
            if ToolCommandRisk.requiresConfirmation(
                adapterID: selectedAdapterID,
                arguments: arguments
            ) {
                pendingArguments = arguments
                showingMutationConfirmation = true
            } else {
                run(arguments: arguments, confirmedMutation: false)
            }
        } catch {
            model.notice = error.localizedDescription
        }
    }

    private func run(arguments: [String], confirmedMutation: Bool) {
        Task {
            await model.runTool(
                adapterID: selectedAdapterID,
                arguments: arguments,
                workingDirectory: workingDirectory,
                confirmedMutation: confirmedMutation
            )
        }
    }
}

struct StatusPill: View {
    let label: String
    let success: Bool?
    let running: Bool

    private var color: Color {
        if running { return .orange }
        return success == true ? .green : .red
    }

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: running ? "clock.fill" : success == true ? "checkmark.circle.fill" : "xmark.circle.fill")
            Text(label)
        }
        .font(.system(size: 9, weight: .semibold))
        .foregroundStyle(color)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(color.opacity(0.10), in: Capsule())
        .accessibilityElement(children: .combine)
    }
}
