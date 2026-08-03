import SwiftUI

struct HostOperationsView: View {
    private enum OutputMode: Equatable {
        case general
        case processes
        case logs
    }

    @Bindable var model: AppModel
    @State private var processID = ""
    @State private var processSearch = ""
    @State private var processSignal = "TERM"
    @State private var serviceName = ""
    @State private var logUnit = ""
    @State private var logFile = ""
    @State private var logSearch = ""
    @State private var logsPaused = false
    @State private var pausedLogOutput = ""
    @State private var customCommand = ""
    @State private var pendingCommand = ""
    @State private var pendingOutputMode = OutputMode.general
    @State private var outputMode = OutputMode.general
    @State private var showingMutationConfirmation = false

    private var host: HostModel? {
        model.selectedHost
    }

    private var capability: ToolCapabilityModel? {
        model.capability("ssh-host")
    }

    private var operation: ToolOperationModel? {
        guard model.toolOperation?.adapterID == "ssh-host" else { return nil }
        return model.toolOperation
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            capabilityBar
            Divider()
            if let host, capability?.available == true {
                HSplitView {
                    actions(host)
                        .frame(minWidth: 330, idealWidth: 420)
                    outputConsole
                        .frame(minWidth: 380, idealWidth: 560)
                }
            } else if capability?.available == false {
                AegizCapabilityUnavailableView(
                    tool: "OpenSSH",
                    diagnostic: capability?.diagnostic ?? "Aegiz requires /usr/bin/ssh.",
                    installHint: "Install the macOS OpenSSH client tools, then check again.",
                    symbol: "terminal"
                ) {
                    Task { await model.refresh() }
                }
            } else {
                AegizWorkspaceStateView(
                    "Select an SSH host",
                    message: "Import OpenSSH config and select a host to run scoped, guarded operations.",
                    symbol: "server.rack"
                )
            }
        }
        .background(AegizTheme.raised)
        .navigationTitle("Host Operations")
        .confirmationDialog(
            "Run a remote mutation?",
            isPresented: $showingMutationConfirmation,
            titleVisibility: .visible
        ) {
            Button("Run on \(host?.alias ?? "host")", role: .destructive) {
                run(
                    pendingCommand,
                    confirmedMutation: true,
                    outputMode: pendingOutputMode
                )
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                "Target: \(host?.endpoint ?? "unknown"). Aegiz invokes /usr/bin/ssh with fixed local options. The command executes on the remote host."
            )
        }
    }

    private var header: some View {
        AegizPageHeader(
            "Host Operations",
            subtitle: "Facts, processes, services, logs, and guarded remote commands",
            symbol: "waveform.path.ecg.rectangle.fill"
        ) {
            Picker(
                "Host",
                selection: Binding(
                    get: { model.selectedHostID ?? "" },
                    set: { model.selectedHostID = $0 }
                )
            ) {
                ForEach(model.hosts) { host in
                    Text(host.alias).tag(host.id)
                }
            }
            .frame(width: 210)
        }
    }

    private var capabilityBar: some View {
        HStack(spacing: 8) {
            Image(systemName: capability?.available == true ? "checkmark.circle.fill" : "clock.fill")
                .foregroundStyle(capability?.available == true ? .green : .orange)
            Text(capability?.available == true ? "OpenSSH ready" : "Detecting OpenSSH")
                .font(.system(size: 11, weight: .semibold))
            if let host {
                Text("•")
                    .foregroundStyle(.tertiary)
                Text(host.endpoint)
                    .font(.system(size: 10).monospaced())
                    .foregroundStyle(.secondary)
                if !host.proxyJump.isEmpty {
                    Label(host.proxyJump, systemImage: "arrow.triangle.branch")
                        .font(.system(size: 10).monospaced())
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if operation?.isRunning == true {
                Button("Cancel", role: .destructive) {
                    Task { await model.cancelToolOperation() }
                }
            }
        }
        .padding(.horizontal, 16)
        .frame(height: 36)
        .background(AegizTheme.canvas.opacity(0.55))
    }

    private func actions(_ host: HostModel) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                operationSection("Connection & facts", symbol: "info.circle") {
                    actionButton("Test connection", symbol: "bolt.horizontal.circle") {
                        run("true", confirmedMutation: false)
                    }
                    actionButton("Collect host facts", symbol: "list.bullet.rectangle") {
                        run(HostRemoteCommandRisk.factsCommand, confirmedMutation: false)
                    }
                }

                operationSection("Processes", symbol: "cpu") {
                    actionButton("List processes", symbol: "list.number") {
                        run(
                            HostRemoteCommandRisk.processListCommand,
                            confirmedMutation: false,
                            outputMode: .processes
                        )
                    }
                    TextField("Filter process output", text: $processSearch)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityLabel("Process search")
                    HStack {
                        TextField("PID", text: $processID)
                            .textFieldStyle(.roundedBorder)
                        Picker("Signal", selection: $processSignal) {
                            ForEach(["TERM", "HUP", "INT", "KILL"], id: \.self) {
                                Text($0).tag($0)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 82)
                        Button("Send signal", role: .destructive) {
                            guard processID.allSatisfy(\.isNumber), !processID.isEmpty else {
                                model.notice = "Enter a numeric process ID."
                                return
                            }
                            confirm(
                                "kill -\(processSignal) -- \(processID)",
                                outputMode: .processes
                            )
                        }
                    }
                    Text("TERM is the safe default. KILL cannot be handled by the process.")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                }

                operationSection("systemd services", symbol: "gearshape.2") {
                    actionButton("List running services", symbol: "list.bullet") {
                        run(
                            HostRemoteCommandRisk.serviceListCommand,
                            confirmedMutation: false
                        )
                    }
                    TextField("Unit, e.g. nginx.service", text: $serviceName)
                        .textFieldStyle(.roundedBorder)
                    HStack {
                        ForEach(["start", "stop", "restart"], id: \.self) { verb in
                            Button(verb.capitalized, role: verb == "stop" ? .destructive : nil) {
                                guard HostRemoteCommandRisk.isSafeUnit(serviceName) else {
                                    model.notice = "Use a valid systemd unit name."
                                    return
                                }
                                confirm(
                                    "systemctl \(verb) -- \(serviceName)",
                                    outputMode: .general
                                )
                            }
                        }
                    }
                }

                operationSection("Logs", symbol: "doc.text.magnifyingglass") {
                    HStack {
                        TextField("Optional systemd unit", text: $logUnit)
                            .textFieldStyle(.roundedBorder)
                        Button("Snapshot") {
                            if logUnit.isEmpty {
                                run(
                                    "journalctl --no-pager -n 300",
                                    confirmedMutation: false,
                                    outputMode: .logs
                                )
                            } else if HostRemoteCommandRisk.isSafeUnit(logUnit) {
                                run(
                                    "journalctl --no-pager -n 300 -u \(logUnit)",
                                    confirmedMutation: false,
                                    outputMode: .logs
                                )
                            } else {
                                model.notice = "Use a valid systemd unit name."
                            }
                        }
                        Button("Follow") {
                            if logUnit.isEmpty {
                                run(
                                    "journalctl --no-pager -f -n 200",
                                    confirmedMutation: false,
                                    outputMode: .logs
                                )
                            } else if HostRemoteCommandRisk.isSafeUnit(logUnit) {
                                run(
                                    "journalctl --no-pager -f -n 200 -u \(logUnit)",
                                    confirmedMutation: false,
                                    outputMode: .logs
                                )
                            } else {
                                model.notice = "Use a valid systemd unit name."
                            }
                        }
                    }
                    HStack {
                        TextField("Absolute remote log file", text: $logFile)
                            .textFieldStyle(.roundedBorder)
                        Button("Follow file") {
                            guard Self.isSafeRemotePath(logFile) else {
                                model.notice = "Enter an absolute remote file path without control characters."
                                return
                            }
                            run(
                                "tail -n 200 -F -- \(RemoteShellEscaping.singleQuoted(logFile))",
                                confirmedMutation: false,
                                outputMode: .logs
                            )
                        }
                    }
                }

                operationSection("Explicit remote command", symbol: "terminal") {
                    TextEditor(text: $customCommand)
                        .font(.system(size: 11).monospaced())
                        .frame(minHeight: 70)
                        .padding(6)
                        .background(AegizTheme.canvas, in: RoundedRectangle(cornerRadius: 6))
                    Text("Every explicit command requires target confirmation.")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                    Button("Review and Run") {
                        let command = customCommand.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !command.isEmpty, !command.contains("\n"), !command.contains("\r") else {
                            model.notice = "Use one remote command line."
                            return
                        }
                        confirm(command, outputMode: .general)
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .padding(14)
        }
    }

    private var outputConsole: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Remote output")
                    .font(.system(size: 11, weight: .semibold))
                if let operation {
                    StatusPill(
                        label: operation.phase.capitalized,
                        success: operation.success,
                        running: operation.isRunning
                    )
                }
                Spacer()
                if outputMode == .logs, operation != nil {
                    TextField("Search logs", text: $logSearch)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 180)
                    Button(logsPaused ? "Resume" : "Pause") {
                        toggleLogPause()
                    }
                    .disabled(operation?.output.isEmpty != false)
                }
                if let exitCode = operation?.exitCode {
                    Text("exit \(exitCode)")
                        .font(.system(size: 10).monospaced())
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 12)
            .frame(height: 34)
            if let diagnostic = operation.flatMap({
                $0.success == false ? HostOperationFailureClassifier.message(for: $0.output) : nil
            }) {
                Label(diagnostic, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(.orange)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.orange.opacity(0.08))
            }
            ScrollView([.vertical, .horizontal]) {
                Text(
                    !displayedOutput.isEmpty
                        ? displayedOutput
                        : "Choose a safe operation. Output is bounded, redacted in flight, and never written to the audit database."
                )
                .font(.system(size: 11).monospaced())
                .foregroundStyle(!displayedOutput.isEmpty ? .primary : .secondary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .padding(12)
            }
            .background(Color(nsColor: .textBackgroundColor))
        }
    }

    private func operationSection<Content: View>(
        _ title: String,
        symbol: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Label(title, systemImage: symbol)
                .font(.system(size: 11, weight: .semibold))
            content()
        }
        .padding(12)
        .background(AegizTheme.canvas.opacity(0.65), in: RoundedRectangle(cornerRadius: 8))
    }

    private func actionButton(
        _ title: String,
        symbol: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var displayedOutput: String {
        guard let operation else { return "" }
        let raw = outputMode == .logs && logsPaused ? pausedLogOutput : operation.output
        let query = switch outputMode {
        case .processes: processSearch
        case .logs: logSearch
        case .general: ""
        }
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return raw }
        return raw
            .split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
            .filter { $0.localizedCaseInsensitiveContains(needle) }
            .joined(separator: "\n")
    }

    private func toggleLogPause() {
        if logsPaused {
            logsPaused = false
            pausedLogOutput = ""
        } else {
            pausedLogOutput = operation?.output ?? ""
            logsPaused = true
        }
    }

    private func confirm(_ command: String, outputMode: OutputMode) {
        pendingCommand = command
        pendingOutputMode = outputMode
        showingMutationConfirmation = true
    }

    private func run(
        _ command: String,
        confirmedMutation: Bool,
        outputMode: OutputMode = .general
    ) {
        guard let host else { return }
        self.outputMode = outputMode
        logsPaused = false
        pausedLogOutput = ""
        Task {
            await model.runHostCommand(
                host: host,
                remoteCommand: command,
                confirmedMutation: confirmedMutation
            )
        }
    }

    private static func isSafeRemotePath(_ value: String) -> Bool {
        value.hasPrefix("/")
            && value.utf8.count <= 4_096
            && !value.contains("\n")
            && !value.contains("\r")
            && !value.contains("\0")
            && !value.contains("'")
    }
}
