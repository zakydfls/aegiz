import AppKit
import Foundation
import SwiftUI
import UniformTypeIdentifiers

enum KubernetesResourceKind: String, CaseIterable, Identifiable {
    case pods = "Pods"
    case deployments = "Deployments"
    case events = "Events"

    var id: String { rawValue }
    var cliName: String {
        switch self {
        case .pods: "pods"
        case .deployments: "deployments"
        case .events: "events"
        }
    }
}

struct KubernetesResourceItem: Identifiable, Hashable {
    let id: String
    let kind: String
    let namespace: String
    let name: String
    let status: String
    let detail: String
}

private struct PendingKubernetesAction {
    let title: String
    let target: String
    let arguments: [String]
    var openTerminal = false
}

struct KubernetesView: View {
    @Bindable var model: AppModel

    @State private var contexts: [String] = []
    @State private var selectedContext = ""
    @State private var namespaces: [String] = []
    @State private var selectedNamespace = ""
    @State private var identity = ""
    @State private var resourceKind = KubernetesResourceKind.pods
    @State private var resources: [KubernetesResourceItem] = []
    @State private var selectedResourceID: String?
    @State private var output = ""
    @State private var localPort = "8080"
    @State private var remotePort = "8080"
    @State private var replicas = "1"
    @State private var isRefreshing = false
    @State private var pendingAction: PendingKubernetesAction?
    @State private var showingConfirmation = false

    private var capability: ToolCapabilityModel? { model.capability("kubectl") }
    private var selectedResource: KubernetesResourceItem? {
        resources.first { $0.id == selectedResourceID }
    }
    private var operation: ToolOperationModel? {
        guard model.toolOperation?.adapterID == "kubectl" else { return nil }
        return model.toolOperation
    }

    var body: some View {
        VStack(spacing: 0) {
            AegizPageHeader(
                "Kubernetes",
                subtitle: "Cluster workflows are being rebuilt with stricter context safety",
                symbol: "hexagon.fill"
            )
            Divider()
            AegizWorkspaceStateView(
                "Kubernetes is under maintenance",
                message: "Context, namespace, workload, and mutation flows are temporarily disabled while their safety and UX are rebuilt.",
                detail: "No kubectl command will run from this screen.",
                symbol: "wrench.and.screwdriver.fill",
                tint: AegizTheme.warning
            )
        }
        .background(AegizTheme.raised)
        .navigationTitle("Kubernetes")
    }

    private var header: some View {
        AegizPageHeader(
            "Kubernetes",
            subtitle: "Contexts, namespaces, workloads, events, logs, YAML, and guarded changes",
            symbol: "hexagon.fill"
        ) {
            HStack(spacing: 8) {
                if isRefreshing {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel("Refreshing Kubernetes resources")
                }
                Button {
                    Task { await loadContexts() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .disabled(isRefreshing || operation?.isRunning == true)
            }
        }
    }

    private var safetyBanner: some View {
        VStack(spacing: 7) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.shield.fill")
                    .foregroundStyle(.orange)
                Text("Explicit cluster scope")
                    .font(.system(size: 10, weight: .semibold))
                Picker("Context", selection: $selectedContext) {
                    ForEach(contexts, id: \.self) { context in
                        Text(context).tag(context)
                    }
                }
                .labelsHidden()
                .frame(width: 220)
                Picker("Namespace", selection: $selectedNamespace) {
                    Text("All namespaces").tag("")
                    ForEach(namespaces, id: \.self) { namespace in
                        Text(namespace).tag(namespace)
                    }
                }
                .labelsHidden()
                .frame(width: 180)
                Spacer()
                Text(identity.isEmpty ? "Identity unavailable" : identity)
                    .font(.system(size: 9).monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Text("Aegiz passes --context and --namespace/--all-namespaces on every resource command; it never silently switches your kubectl default.")
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Color.orange.opacity(0.06))
    }

    private var resourceWorkspace: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("Resource", selection: $resourceKind) {
                    ForEach(KubernetesResourceKind.allCases) { kind in
                        Text(kind.rawValue).tag(kind)
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 390)
                Spacer()
                Button("Apply file…") {
                    chooseApplyFile()
                }
                Text("\(resources.count) resources")
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .padding(10)
            Divider()
            HSplitView {
                List(resources, selection: $selectedResourceID) { resource in
                    HStack(spacing: 9) {
                        Circle()
                            .fill(statusColor(resource.status))
                            .frame(width: 7, height: 7)
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Text(resource.name)
                                    .font(.system(size: 11, weight: .semibold))
                                Spacer()
                                Text(resource.status)
                                    .font(.system(size: 8, weight: .bold).monospaced())
                                    .foregroundStyle(.secondary)
                            }
                            Text("\(resource.namespace) · \(resource.detail)")
                                .font(.system(size: 9).monospaced())
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    .padding(.vertical, 3)
                    .tag(resource.id)
                    .aegizInteractiveRow(isSelected: selectedResourceID == resource.id)
                }
                .frame(minWidth: 420, idealWidth: 590)
                resourceInspector
                    .frame(minWidth: 300, idealWidth: 360)
            }
        }
    }

    private var resourceInspector: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if let resource = selectedResource {
                    Label(resource.name, systemImage: resource.kind == "Pod" ? "cube" : "square.3.layers.3d")
                        .font(.system(size: 14, weight: .semibold))
                    LabeledContent("Kind", value: resource.kind)
                    LabeledContent("Namespace", value: resource.namespace)
                    LabeledContent("Status", value: resource.status)
                    Divider()
                    HStack {
                        Button("YAML") {
                            Task {
                                await run(
                                    scoped(
                                        ["get", resource.kind.lowercased(), resource.name, "-o", "yaml"],
                                        namespace: resource.namespace
                                    ),
                                    exposeOutput: true
                                )
                            }
                        }
                        Button("Describe") {
                            Task {
                                await run(
                                    scoped(
                                        ["describe", resource.kind.lowercased(), resource.name],
                                        namespace: resource.namespace
                                    ),
                                    exposeOutput: true
                                )
                            }
                        }
                        if resource.kind == "Pod" {
                            Button("Logs") {
                                Task {
                                    await run(
                                        scoped(
                                            ["logs", "--tail", "300", resource.name, "--all-containers"],
                                            namespace: resource.namespace
                                        ),
                                        exposeOutput: true
                                    )
                                }
                            }
                            Button("Exec") {
                                pendingAction = PendingKubernetesAction(
                                    title: "Open an interactive pod shell?",
                                    target: "\(resource.namespace)/\(resource.name)",
                                    arguments: scoped(
                                        [
                                            "exec", "-it", resource.name,
                                            "--", "/bin/sh",
                                        ],
                                        namespace: resource.namespace
                                    ),
                                    openTerminal: true
                                )
                                showingConfirmation = true
                            }
                        }
                    }
                    if resource.kind == "Pod" {
                        HStack {
                            TextField("Local", text: $localPort)
                                .textFieldStyle(.roundedBorder)
                            Text(":")
                            TextField("Remote", text: $remotePort)
                                .textFieldStyle(.roundedBorder)
                            Button("Port Forward") {
                                guard let local = UInt16(localPort), let remote = UInt16(remotePort),
                                      local > 0, remote > 0
                                else {
                                    model.notice = "Enter valid local and remote ports."
                                    return
                                }
                                confirm(
                                    title: "Start a kubectl port-forward?",
                                    target: "\(resource.namespace)/\(resource.name)",
                                    arguments: scoped(
                                        [
                                            "port-forward", "pod/\(resource.name)",
                                            "\(local):\(remote)",
                                            "--address", "127.0.0.1",
                                        ],
                                        namespace: resource.namespace
                                    )
                                )
                            }
                        }
                    }
                    if resource.kind == "Deployment" {
                        HStack {
                            TextField("Replicas", text: $replicas)
                                .textFieldStyle(.roundedBorder)
                            Button("Scale") {
                                guard let count = UInt32(replicas), count <= 10_000 else {
                                    model.notice = "Enter a replica count from 0 to 10000."
                                    return
                                }
                                confirm(
                                    title: "Scale this deployment?",
                                    target: "\(resource.namespace)/\(resource.name) → \(count)",
                                    arguments: scoped(
                                        [
                                            "scale", "deployment/\(resource.name)",
                                            "--replicas", String(count),
                                        ],
                                        namespace: resource.namespace
                                    )
                                )
                            }
                        }
                        Button("Rollout Restart") {
                            confirm(
                                title: "Restart this deployment?",
                                target: "\(resource.namespace)/\(resource.name)",
                                arguments: scoped(
                                    ["rollout", "restart", "deployment/\(resource.name)"],
                                    namespace: resource.namespace
                                )
                            )
                        }
                    }
                    Button("Delete \(resource.kind)", role: .destructive) {
                        confirm(
                            title: "Delete this \(resource.kind.lowercased())?",
                            target: "\(resource.namespace)/\(resource.name)",
                            arguments: scoped(
                                ["delete", resource.kind.lowercased(), resource.name],
                                namespace: resource.namespace
                            )
                        )
                    }
                } else {
                    ContentUnavailableView("Select a resource", systemImage: "cursorarrow.click")
                }
            }
            .padding(14)
        }
    }

    private var outputConsole: some View {
        VStack(spacing: 0) {
            HStack {
                Text("kubectl output")
                    .font(.system(size: 11, weight: .semibold))
                if let operation {
                    StatusPill(
                        label: operation.phase.capitalized,
                        success: operation.success,
                        running: operation.isRunning
                    )
                }
                Spacer()
                if operation?.isRunning == true {
                    Button("Stop / Cancel", role: .destructive) {
                        Task { await model.cancelToolOperation() }
                    }
                }
            }
            .padding(.horizontal, 12)
            .frame(height: 34)
            ScrollView([.vertical, .horizontal]) {
                Text(output.isEmpty ? "Select a resource action to view output." : output)
                    .font(.system(size: 10).monospaced())
                    .foregroundStyle(output.isEmpty ? .secondary : .primary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding(12)
            }
            .background(Color(nsColor: .textBackgroundColor))
        }
    }

    private func loadContexts() async {
        isRefreshing = true
        let names = await run(["config", "get-contexts", "-o", "name"], exposeOutput: false)
            .split(whereSeparator: \.isNewline)
            .map(String.init)
            .filter { !$0.hasPrefix("›") && !$0.isEmpty }
        let current = await run(["config", "current-context"], exposeOutput: false)
            .split(whereSeparator: \.isNewline)
            .map(String.init)
            .first { !$0.hasPrefix("›") } ?? ""
        contexts = Array(Set(names)).sorted()
        if contexts.contains(current) {
            selectedContext = current
        } else if !contexts.contains(selectedContext) {
            selectedContext = contexts.first ?? ""
        }
        await loadContextData()
        isRefreshing = false
    }

    private func loadContextData() async {
        guard !selectedContext.isEmpty else { return }
        isRefreshing = true
        let namespaceOutput = await run(
            scoped(["get", "namespaces", "-o", "json"], includeNamespace: false),
            exposeOutput: false
        )
        namespaces = KubernetesOutputParser.namespaces(namespaceOutput)
        if !selectedNamespace.isEmpty, !namespaces.contains(selectedNamespace) {
            selectedNamespace = ""
        }
        let identityOutput = await run(
            scoped(["auth", "whoami", "-o", "json"], includeNamespace: false),
            exposeOutput: false
        )
        identity = KubernetesOutputParser.identity(identityOutput)
        await loadResources()
        isRefreshing = false
    }

    private func loadResources() async {
        guard !selectedContext.isEmpty else { return }
        let arguments = scoped(
            ["get", resourceKind.cliName, "-o", "json"],
            namespace: selectedNamespace
        )
        let resourceOutput = await run(arguments, exposeOutput: false)
        resources = KubernetesOutputParser.resources(resourceOutput, kind: resourceKind)
        if !resources.contains(where: { $0.id == selectedResourceID }) {
            selectedResourceID = resources.first?.id
        }
        output = "Loaded \(resources.count) \(resourceKind.rawValue.lowercased()) from \(selectedContext)."
    }

    private func chooseApplyFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.yaml, .json]
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            let arguments = scoped(
                ["diff", "-f", url.path],
                includeNamespace: false
            )
            let diff = await run(arguments, exposeOutput: true)
            if operation?.success == true || operation?.exitCode == 1 {
                output = diff
                confirm(
                    title: "Apply the reviewed manifest?",
                    target: url.lastPathComponent,
                    arguments: scoped(
                        ["apply", "-f", url.path],
                        includeNamespace: false
                    )
                )
            } else {
                model.notice = "kubectl diff failed; apply was not offered."
            }
        }
    }

    private func scoped(
        _ arguments: [String],
        namespace: String? = nil,
        includeNamespace: Bool = true
    ) -> [String] {
        var result = ["--context", selectedContext]
        if includeNamespace {
            let value = namespace ?? selectedNamespace
            if value.isEmpty {
                result.append("--all-namespaces")
            } else {
                result += ["--namespace", value]
            }
        }
        result += arguments
        return result
    }

    private func confirm(title: String, target: String, arguments: [String]) {
        pendingAction = PendingKubernetesAction(
            title: title,
            target: target,
            arguments: arguments
        )
        showingConfirmation = true
    }

    @discardableResult
    private func run(
        _ arguments: [String],
        confirmedMutation: Bool = false,
        exposeOutput: Bool
    ) async -> String {
        await model.runTool(
            adapterID: "kubectl",
            arguments: arguments,
            workingDirectory: "",
            confirmedMutation: confirmedMutation
        )
        let value = model.toolOperation?.output ?? ""
        if exposeOutput {
            output = value
        }
        return value
    }

    private func statusColor(_ status: String) -> Color {
        let value = status.lowercased()
        if ["running", "available", "normal"].contains(value) { return .green }
        if ["pending", "warning", "progressing"].contains(value) { return .orange }
        if ["failed", "error", "crashloopbackoff"].contains(value) { return .red }
        return .secondary
    }
}

enum KubernetesOutputParser {
    static func namespaces(_ output: String) -> [String] {
        guard let root = object(output),
              let items = root["items"] as? [[String: Any]]
        else {
            return []
        }
        return items.compactMap {
            ($0["metadata"] as? [String: Any])?["name"] as? String
        }
        .sorted()
    }

    static func identity(_ output: String) -> String {
        guard let root = object(output) else { return "" }
        if let status = root["status"] as? [String: Any],
           let userInfo = status["userInfo"] as? [String: Any],
           let username = userInfo["username"] as? String {
            return username
        }
        return (root["username"] as? String) ?? ""
    }

    static func resources(
        _ output: String,
        kind: KubernetesResourceKind
    ) -> [KubernetesResourceItem] {
        guard let root = object(output),
              let items = root["items"] as? [[String: Any]]
        else {
            return []
        }
        return items.compactMap { item in
            guard let metadata = item["metadata"] as? [String: Any],
                  let name = metadata["name"] as? String
            else {
                return nil
            }
            let namespace = metadata["namespace"] as? String ?? "cluster"
            let uid = metadata["uid"] as? String ?? "\(namespace)/\(name)"
            let status = item["status"] as? [String: Any] ?? [:]
            switch kind {
            case .pods:
                let phase = status["phase"] as? String ?? "Unknown"
                let containerStatuses = status["containerStatuses"] as? [[String: Any]] ?? []
                let ready = containerStatuses.filter { ($0["ready"] as? Bool) == true }.count
                return KubernetesResourceItem(
                    id: uid,
                    kind: "Pod",
                    namespace: namespace,
                    name: name,
                    status: phase,
                    detail: "\(ready)/\(containerStatuses.count) containers ready"
                )
            case .deployments:
                let desired = (item["spec"] as? [String: Any])?["replicas"] as? NSNumber
                let available = status["availableReplicas"] as? NSNumber
                return KubernetesResourceItem(
                    id: uid,
                    kind: "Deployment",
                    namespace: namespace,
                    name: name,
                    status: available?.intValue == desired?.intValue ? "Available" : "Progressing",
                    detail: "\(available?.intValue ?? 0)/\(desired?.intValue ?? 0) replicas available"
                )
            case .events:
                let type = item["type"] as? String ?? "Normal"
                let reason = item["reason"] as? String ?? ""
                let message = item["message"] as? String ?? ""
                return KubernetesResourceItem(
                    id: uid,
                    kind: "Event",
                    namespace: namespace,
                    name: reason.isEmpty ? name : reason,
                    status: type,
                    detail: message
                )
            }
        }
    }

    private static func object(_ output: String) -> [String: Any]? {
        guard let start = output.firstIndex(of: "{"),
              let end = output.lastIndex(of: "}")
        else {
            return nil
        }
        let json = String(output[start...end])
        guard let data = json.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }
}
