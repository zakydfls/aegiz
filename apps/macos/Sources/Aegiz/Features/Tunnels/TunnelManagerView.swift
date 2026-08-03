import AppKit
import SwiftUI

private enum TunnelGrouping: String, CaseIterable, Identifiable {
    case project = "Project"
    case sshHost = "SSH host"
    case status = "Status"

    var id: String { rawValue }
}

private struct TunnelGroup: Identifiable {
    let title: String
    let tunnels: [TunnelModel]

    var id: String { title }
}

struct TunnelManagerView: View {
    @Bindable var model: AppModel
    @AppStorage("tunnelGrouping") private var groupingRaw = TunnelGrouping.project.rawValue

    private var grouping: TunnelGrouping {
        TunnelGrouping(rawValue: groupingRaw) ?? .project
    }

    private var groups: [TunnelGroup] {
        let grouped = Dictionary(grouping: model.tunnels) { tunnel in
            groupTitle(for: tunnel)
        }
        return grouped.map { title, tunnels in
            TunnelGroup(
                title: title,
                tunnels: tunnels.sorted {
                    $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending
                }
            )
        }.sorted { lhs, rhs in
            if grouping == .status {
                return statusRank(lhs.title) < statusRank(rhs.title)
            }
            return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            AegizPageHeader(
                "Tunnels",
                subtitle: "OpenSSH forwards managed by Aegiz on this Mac",
                symbol: "point.3.connected.trianglepath.dotted"
            ) {
                Picker("Group", selection: $groupingRaw) {
                    ForEach(TunnelGrouping.allCases) { grouping in
                        Text(grouping.rawValue).tag(grouping.rawValue)
                    }
                }
                .pickerStyle(.menu)
                .frame(width: 112)
                .help("Group tunnels by project, SSH host, or status")
                Button {
                    model.showingNewTunnel = true
                } label: {
                    Label("New Tunnel", systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
                .help("Create a local, remote, or SOCKS tunnel")
            }
            Divider()

            if model.tunnels.isEmpty {
                AegizWorkspaceStateView(
                    "No tunnel definitions",
                    message: "Create a forward, review its exact route, then start it explicitly.",
                    symbol: "point.3.connected.trianglepath.dotted"
                ) {
                    Button("New Tunnel") { model.showingNewTunnel = true }
                        .buttonStyle(.borderedProminent)
                }
            } else {
                List(selection: $model.selectedTunnelID) {
                    ForEach(groups) { group in
                        Section {
                            ForEach(group.tunnels) { tunnel in
                                TunnelRow(
                                    tunnel: tunnel,
                                    route: model.tunnelRoute(for: tunnel),
                                    isSelected: model.selectedTunnelID == tunnel.id,
                                    isChanging: model.tunnelOperationID == tunnel.id,
                                    hasPortConflict: model.tunnelPortConflictIDs.contains(tunnel.id)
                                ) {
                                    Task { await model.toggleTunnel(tunnel) }
                                }
                                .tag(tunnel.id)
                            }
                        } header: {
                            HStack {
                                Text(group.title)
                                Spacer()
                                Text("\(group.tunnels.count)")
                                    .monospacedDigit()
                                    .foregroundStyle(.tertiary)
                            }
                        }
                    }
                }
                .listStyle(.inset)
            }
        }
        .background(AegizTheme.raised)
        .navigationTitle("Tunnels")
    }

    private func groupTitle(for tunnel: TunnelModel) -> String {
        let host = model.hosts.first { $0.id == tunnel.hostID }
        switch grouping {
        case .project:
            let metadata = model.hostOrganization(for: tunnel.hostID)
            if !metadata.company.isEmpty { return metadata.company }
            if !metadata.workspace.isEmpty { return metadata.workspace }
            if let prefix = tunnel.label.split(whereSeparator: \.isWhitespace).first {
                let value = String(prefix).trimmingCharacters(in: .punctuationCharacters)
                if !value.isEmpty, value.utf8.count <= 32 { return value }
            }
            return host?.alias ?? "Other"
        case .sshHost:
            return host?.alias ?? "Missing SSH host"
        case .status:
            return tunnel.status.rawValue
        }
    }

    private func statusRank(_ title: String) -> Int {
        ["Running", "Starting", "Failed", "Stopping", "Stopped"]
            .firstIndex(of: title) ?? Int.max
    }
}

private struct TunnelRow: View {
    let tunnel: TunnelModel
    let route: String
    let isSelected: Bool
    let isChanging: Bool
    let hasPortConflict: Bool
    let toggle: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: tunnel.status.symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(AegizTheme.statusColor(tunnel.status))
                .frame(width: 24, height: 24)
                .background(
                    AegizTheme.statusColor(tunnel.status).opacity(0.10),
                    in: RoundedRectangle(cornerRadius: 6)
                )
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 7) {
                    Text(tunnel.label)
                        .font(.system(size: 12, weight: .semibold))
                    Text(tunnel.kind.rawValue)
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                    if hasPortConflict {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 9))
                            .foregroundStyle(AegizTheme.warning)
                            .help("Another saved tunnel uses the same local endpoint. Only one can run at a time.")
                    }
                }
                Text(route)
                    .font(.system(size: 10).monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if !tunnel.lastError.isEmpty {
                    Label(tunnel.lastError, systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(AegizTheme.danger)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 8)
            AegizStatusPill(
                title: tunnel.status.rawValue,
                color: AegizTheme.statusColor(tunnel.status)
            )
            Button(action: toggle) {
                if isChanging {
                    ProgressView().controlSize(.small)
                } else {
                    Text(tunnel.status == .running ? "Stop" : "Start")
                }
            }
            .buttonStyle(.bordered)
            .frame(minWidth: 58)
            .disabled(
                isChanging || tunnel.status == .starting || tunnel.status == .stopping
            )
            .help(tunnel.status == .running ? "Stop this tunnel" : "Start this tunnel")
            .accessibilityLabel(
                tunnel.status == .running
                    ? "Stop \(tunnel.label)"
                    : "Start \(tunnel.label)"
            )
        }
        .aegizInteractiveRow(isSelected: isSelected)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            guard canStart else { return }
            toggle()
        }
        .contextMenu {
            Button(tunnel.status == .running ? "Stop Tunnel" : "Start Tunnel") {
                toggle()
            }
            .disabled(!canToggle)

            Divider()

            Button("Copy Route") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(route, forType: .string)
            }
        }
        .help(rowHelp)
        .accessibilityAction(named: "Start Tunnel") {
            guard canStart else { return }
            toggle()
        }
    }

    private var canToggle: Bool {
        !isChanging && tunnel.status != .starting && tunnel.status != .stopping
    }

    private var canStart: Bool {
        canToggle && tunnel.status != .running
    }

    private var rowHelp: String {
        if canStart {
            return "Double-click to start this tunnel"
        }
        if tunnel.status == .running {
            return "Use Stop or the context menu to stop this tunnel"
        }
        return "Tunnel operation in progress"
    }
}

struct TunnelInspector: View {
    @Bindable var model: AppModel

    private var eligibleSecrets: [SecretMetadataModel] {
        model.secrets.filter {
            [.sshPassword, .password, .generic].contains($0.kind)
        }
    }

    var body: some View {
        ScrollView {
            if let tunnel = model.selectedTunnel {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 7) {
                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(tunnel.label)
                                    .font(.system(size: 17, weight: .semibold))
                                Text(tunnel.kind.rawValue + " forward")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            AegizStatusPill(
                                title: tunnel.status.rawValue,
                                color: AegizTheme.statusColor(tunnel.status)
                            )
                        }
                    }

                    AegizInspectorSection("Route") {
                        Text(model.tunnelRoute(for: tunnel))
                            .font(.system(size: 10).monospaced())
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                        if let host = model.hosts.first(where: { $0.id == tunnel.hostID }) {
                            LabeledContent("SSH host", value: host.alias)
                                .font(.system(size: 11))
                        }
                        if model.tunnelPortConflictIDs.contains(tunnel.id) {
                            Label(
                                "Another saved tunnel uses this local endpoint. Start only one of them at a time.",
                                systemImage: "exclamationmark.triangle.fill"
                            )
                            .font(.system(size: 10))
                            .foregroundStyle(AegizTheme.warning)
                            .fixedSize(horizontal: false, vertical: true)
                        }
                    }

                    Divider()

                    AegizInspectorSection("SSH authentication") {
                        Picker(
                            "Credential",
                            selection: Binding(
                                get: { model.tunnelSecretReference(for: tunnel.id) },
                                set: { model.setTunnelSecretReference($0, for: tunnel.id) }
                            )
                        ) {
                            Text("SSH config / key / agent").tag("")
                            let reference = model.tunnelSecretReference(for: tunnel.id)
                            if !reference.isEmpty,
                               !eligibleSecrets.contains(where: { $0.id == reference }) {
                                Label("Missing Keychain credential", systemImage: "exclamationmark.triangle")
                                    .tag(reference)
                            }
                            if !eligibleSecrets.isEmpty {
                                Divider()
                                ForEach(eligibleSecrets) { secret in
                                    Label(secret.name, systemImage: secret.kind.symbol)
                                        .tag(secret.id)
                                }
                            }
                        }
                        .labelsHidden()
                        .frame(maxWidth: .infinity)

                        let reference = model.tunnelSecretReference(for: tunnel.id)
                        if !reference.isEmpty,
                           !eligibleSecrets.contains(where: { $0.id == reference }) {
                            Label("This Keychain item no longer exists.", systemImage: "exclamationmark.triangle.fill")
                                .font(.system(size: 10))
                                .foregroundStyle(AegizTheme.danger)
                            Button("Use SSH config instead") {
                                model.setTunnelSecretReference("", for: tunnel.id)
                            }
                            .buttonStyle(.link)
                        }

                        Text(
                            model.tunnelSecretReference(for: tunnel.id).isEmpty
                                ? "Uses your normal OpenSSH config. Interactive prompts are disabled."
                                : "The password stays in macOS Keychain and is delivered once to OpenSSH when Start is pressed."
                        )
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                        Button {
                            model.beginCreatingSecret(kind: .sshPassword)
                        } label: {
                            Label("New SSH Password", systemImage: "plus")
                        }
                        .buttonStyle(.link)
                    }

                    if !tunnel.lastError.isEmpty {
                        Divider()
                        AegizInspectorSection("Last error") {
                            Label(tunnel.lastError, systemImage: "exclamationmark.triangle.fill")
                                .font(.system(size: 10))
                                .foregroundStyle(AegizTheme.danger)
                                .textSelection(.enabled)
                        }
                    }

                    Divider()

                    Button {
                        Task { await model.toggleTunnel(tunnel) }
                    } label: {
                        HStack {
                            if model.tunnelOperationID == tunnel.id {
                                ProgressView().controlSize(.small)
                            }
                            Text(tunnel.status == .running ? "Stop Tunnel" : "Start Tunnel")
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(tunnel.status == .running ? AegizTheme.danger : AegizTheme.accent)
                    .disabled(
                        model.tunnelOperationID != nil
                            || tunnel.status == .starting
                            || tunnel.status == .stopping
                    )
                }
                .padding(16)
            } else {
                ContentUnavailableView(
                    "Select a tunnel",
                    systemImage: "point.3.connected.trianglepath.dotted",
                    description: Text("Its route, authentication, and controls appear here.")
                )
                .padding(24)
            }
        }
        .background(AegizTheme.raised)
    }
}

struct NewTunnelView: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var model: AppModel
    @State private var draft = TunnelDraft()
    @State private var validationMessage: String?
    @State private var saving = false

    private var eligibleSecrets: [SecretMetadataModel] {
        model.secrets.filter {
            [.sshPassword, .password, .generic].contains($0.kind)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            AegizSheetHeader(
                "New SSH Tunnel",
                subtitle: "Define and verify the complete forwarding route before starting it."
            ) {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            Divider()

            Form {
                Section("Route") {
                    Picker("SSH host", selection: $draft.hostID) {
                        Text("Select a host").tag("")
                        ForEach(model.hosts) { host in
                            Text(host.alias).tag(host.id)
                        }
                    }
                    TextField("Name", text: $draft.label, prompt: Text("Production database"))
                    Picker("Kind", selection: $draft.kind) {
                        ForEach(TunnelKindModel.allCases) { kind in
                            Text(kind.rawValue).tag(kind)
                        }
                    }
                    TextField("Bind address", text: $draft.bindAddress)
                        .font(.system(.body, design: .monospaced))
                    TextField("Local port", text: $draft.localPort)
                        .font(.system(.body, design: .monospaced))
                    if draft.kind != .dynamic {
                        TextField("Remote host", text: $draft.remoteHost)
                            .font(.system(.body, design: .monospaced))
                        TextField("Remote port", text: $draft.remotePort)
                            .font(.system(.body, design: .monospaced))
                    }
                }

                Section("SSH authentication") {
                    Picker("Credential", selection: $draft.secretReference) {
                        Text("SSH config / key / agent").tag("")
                        ForEach(eligibleSecrets) { secret in
                            Label(secret.name, systemImage: secret.kind.symbol).tag(secret.id)
                        }
                    }
                    Text("Passwords are referenced by ID only; values remain in macOS Keychain.")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }

                if let validationMessage {
                    Label(validationMessage, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(AegizTheme.danger)
                }
            }
            .formStyle(.grouped)

            Divider()
            HStack {
                Label("Saved locally and stopped by default", systemImage: "lock.shield")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Save Tunnel") {
                    guard validate() else { return }
                    saving = true
                    Task {
                        _ = await model.saveTunnel(draft)
                        saving = false
                    }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(saving)
            }
            .padding(16)
        }
        .aegizAdaptiveSheet(AegizSheetSizingPolicy.tunnelEditor)
        .onAppear {
            draft.hostID = model.selectedHostID ?? model.hosts.first?.id ?? ""
        }
    }

    private func validate() -> Bool {
        if draft.hostID.isEmpty {
            validationMessage = "Select the SSH host that owns this route."
        } else if draft.label.trimmingCharacters(in: .whitespaces).isEmpty {
            validationMessage = "Add a short name for this tunnel."
        } else if UInt16(draft.localPort) == nil {
            validationMessage = "Local port must be between 1 and 65535."
        } else if draft.kind != .dynamic
                    && (draft.remoteHost.isEmpty || UInt16(draft.remotePort) == nil) {
            validationMessage = "Add a valid remote destination and port."
        } else {
            validationMessage = nil
        }
        return validationMessage == nil
    }
}
