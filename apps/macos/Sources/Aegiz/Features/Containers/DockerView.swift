import Foundation
import SwiftUI

enum DockerResourceKind: String, CaseIterable, Identifiable {
    case containers = "Containers"
    case images = "Images"
    case compose = "Compose"

    var id: String { rawValue }
}

struct DockerContextItem: Identifiable, Hashable {
    var id: String { name }
    let name: String
    let endpoint: String
    let description: String
    let current: Bool
}

struct DockerContainerItem: Identifiable, Hashable {
    var id: String { containerID }
    let containerID: String
    let name: String
    let image: String
    let state: String
    let status: String
    let ports: String
}

struct DockerImageItem: Identifiable, Hashable {
    var id: String { imageID }
    let imageID: String
    let repository: String
    let tag: String
    let size: String
    let created: String
}

struct DockerComposeItem: Identifiable, Hashable {
    var id: String { name }
    let name: String
    let status: String
    let configFiles: String

    var inferredWorkingDirectory: String {
        guard let first = configFiles.split(separator: ",").first else { return "" }
        let path = String(first).trimmingCharacters(in: .whitespacesAndNewlines)
        return path.hasPrefix("/") ? (path as NSString).deletingLastPathComponent : ""
    }
}

private struct PendingDockerAction {
    let title: String
    let target: String
    let arguments: [String]
    let workingDirectory: String
    var openTerminal = false
}

struct DockerView: View {
    @Bindable var model: AppModel

    @State private var contexts: [DockerContextItem] = []
    @State private var selectedContext = ""
    @State private var resourceKind = DockerResourceKind.containers
    @State private var containers: [DockerContainerItem] = []
    @State private var images: [DockerImageItem] = []
    @State private var composeProjects: [DockerComposeItem] = []
    @State private var selectedContainerID: String?
    @State private var selectedImageID: String?
    @State private var selectedComposeID: String?
    @State private var composeWorkingDirectory = ""
    @State private var detailOutput = ""
    @State private var isRefreshing = false
    @State private var pendingAction: PendingDockerAction?
    @State private var showingConfirmation = false

    private var capability: ToolCapabilityModel? { model.capability("docker") }
    private var isPodmanBackend: Bool {
        guard let path = capability?.executablePath, !path.isEmpty else { return false }
        return URL(filePath: path).lastPathComponent == "podman"
    }
    private var backendName: String { isPodmanBackend ? "Podman" : "Docker" }
    private var context: DockerContextItem? {
        contexts.first { $0.name == selectedContext }
    }
    private var container: DockerContainerItem? {
        containers.first { $0.id == selectedContainerID }
    }
    private var image: DockerImageItem? {
        images.first { $0.id == selectedImageID }
    }
    private var compose: DockerComposeItem? {
        composeProjects.first { $0.id == selectedComposeID }
    }
    private var operation: ToolOperationModel? {
        guard model.toolOperation?.adapterID == "docker" else { return nil }
        return model.toolOperation
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if capability?.available == true {
                contextBanner
                Divider()
                VSplitView {
                    resourceWorkspace
                        .frame(minHeight: 360)
                    operationConsole
                        .frame(minHeight: 150, idealHeight: 220)
                }
            } else {
                AegizCapabilityUnavailableView(
                    tool: "Container CLI",
                    diagnostic: capability?.diagnostic ?? "No trusted Docker or Podman executable was detected.",
                    installHint: "Install Docker Desktop or Podman, start its engine or machine, then check again.",
                    symbol: "shippingbox"
                ) {
                    Task { await model.refresh() }
                }
            }
        }
        .background(AegizTheme.raised)
        .navigationTitle("Containers")
        .task(id: capability?.executablePath) {
            guard capability?.available == true else { return }
            await refreshAll()
        }
        .onChange(of: selectedContext) {
            if !isRefreshing {
                Task { await refreshResources() }
            }
        }
        .onChange(of: selectedComposeID) {
            if composeWorkingDirectory.isEmpty, let inferred = compose?.inferredWorkingDirectory {
                composeWorkingDirectory = inferred
            }
        }
        .confirmationDialog(
            pendingAction?.title ?? "Run container mutation?",
            isPresented: $showingConfirmation,
            titleVisibility: .visible
        ) {
            Button("Run on \(pendingAction?.target ?? "resource")", role: .destructive) {
                guard let pendingAction else { return }
                if pendingAction.openTerminal, let executable = capability?.executablePath {
                    model.openLocalTerminal(
                        title: "\(backendName.lowercased()) · \(pendingAction.target)",
                        endpoint: "\(backendName) connection \(selectedContext)",
                        executable: executable,
                        arguments: pendingAction.arguments
                    )
                    return
                }
                Task {
                    await run(
                        pendingAction.arguments,
                        workingDirectory: pendingAction.workingDirectory,
                        confirmedMutation: true,
                        exposeOutput: true
                    )
                    await refreshResources()
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                "\(backendName) connection: \(selectedContext.isEmpty ? "default" : selectedContext). Review the exact resource identity before continuing."
            )
        }
    }

    private var header: some View {
        AegizPageHeader(
            "Containers",
            subtitle: "\(backendName) connections, containers, images, Compose, logs, and guarded actions",
            symbol: "shippingbox.fill"
        ) {
            HStack(spacing: 8) {
                if isRefreshing {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel("Refreshing \(backendName) resources")
                }
                Button {
                    Task { await refreshAll() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .disabled(isRefreshing || operation?.isRunning == true)
            }
        }
    }

    private var contextBanner: some View {
        HStack(spacing: 9) {
            Label("\(backendName) connection", systemImage: "scope")
                .font(.system(size: 10, weight: .semibold))
            Picker("Context", selection: $selectedContext) {
                Text("CLI default").tag("")
                if !contexts.isEmpty {
                    Divider()
                }
                ForEach(contexts) { context in
                    Text(context.name).tag(context.name)
                }
            }
            .labelsHidden()
            .frame(width: 190)
            if let context {
                Text(context.endpoint)
                    .font(.system(size: 9).monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if context.current {
                    Text(isPodmanBackend ? "DEFAULT" : "CLI CURRENT")
                        .font(.system(size: 8, weight: .bold).monospaced())
                        .foregroundStyle(.green)
                }
            }
            Spacer()
            Text(
                isPodmanBackend
                    ? "Every command is explicitly scoped with --connection"
                    : "Every command is explicitly scoped with --context"
            )
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
        .frame(height: 40)
        .background(AegizTheme.canvas.opacity(0.55))
    }

    private var resourceWorkspace: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("Resource", selection: $resourceKind) {
                    ForEach(DockerResourceKind.allCases) { kind in
                        Text(kind.rawValue).tag(kind)
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 360)
                Spacer()
                Text(resourceCount, format: .number)
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .padding(10)
            Divider()
            HSplitView {
                resourceList
                    .frame(minWidth: 390, idealWidth: 560)
                resourceInspector
                    .frame(minWidth: 280, idealWidth: 350)
            }
        }
    }

    private var resourceCount: Int {
        switch resourceKind {
        case .containers: containers.count
        case .images: images.count
        case .compose: composeProjects.count
        }
    }

    @ViewBuilder
    private var resourceList: some View {
        switch resourceKind {
        case .containers:
            List(containers, selection: $selectedContainerID) { item in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Circle()
                            .fill(item.state.lowercased() == "running" ? .green : .secondary)
                            .frame(width: 7, height: 7)
                        Text(item.name)
                            .font(.system(size: 11, weight: .semibold))
                        Spacer()
                        Text(item.state.uppercased())
                            .font(.system(size: 8, weight: .bold).monospaced())
                            .foregroundStyle(.secondary)
                    }
                    Text("\(item.image) · \(item.status)")
                        .font(.system(size: 9).monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .padding(.vertical, 3)
                .tag(item.id)
                .aegizInteractiveRow(isSelected: selectedContainerID == item.id)
            }
        case .images:
            List(images, selection: $selectedImageID) { item in
                HStack {
                    Image(systemName: "shippingbox")
                        .foregroundStyle(AegizTheme.accent)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("\(item.repository):\(item.tag)")
                            .font(.system(size: 11, weight: .semibold))
                        Text("\(item.imageID) · \(item.size) · \(item.created)")
                            .font(.system(size: 9).monospaced())
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 3)
                .tag(item.id)
                .aegizInteractiveRow(isSelected: selectedImageID == item.id)
            }
        case .compose:
            List(composeProjects, selection: $selectedComposeID) { item in
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.name)
                        .font(.system(size: 11, weight: .semibold))
                    Text("\(item.status) · \(item.configFiles)")
                        .font(.system(size: 9).monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .padding(.vertical, 3)
                .tag(item.id)
                .aegizInteractiveRow(isSelected: selectedComposeID == item.id)
            }
        }
    }

    @ViewBuilder
    private var resourceInspector: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                switch resourceKind {
                case .containers:
                    containerInspector
                case .images:
                    imageInspector
                case .compose:
                    composeInspector
                }
            }
            .padding(14)
        }
    }

    @ViewBuilder
    private var containerInspector: some View {
        if let container {
            Label(container.name, systemImage: "shippingbox.fill")
                .font(.system(size: 14, weight: .semibold))
            LabeledContent("ID", value: container.containerID)
            LabeledContent("Image", value: container.image)
            LabeledContent("State", value: container.status)
            if !container.ports.isEmpty {
                LabeledContent("Ports", value: container.ports)
            }
            Divider()
            HStack {
                Button("Inspect") {
                    Task {
                        await run(scoped(["inspect", container.containerID]), exposeOutput: true)
                    }
                }
                Button("Logs") {
                    Task {
                        await run(
                            scoped(["logs", "--tail", "300", container.containerID]),
                            exposeOutput: true
                        )
                    }
                }
                Button("Stats") {
                    Task {
                        await run(
                            scoped(["stats", "--no-stream", container.containerID]),
                            exposeOutput: true
                        )
                    }
                }
            }
            Button("Exec /bin/sh in Terminal") {
                pendingAction = PendingDockerAction(
                    title: "Open an interactive container shell?",
                    target: container.name,
                    arguments: scoped(
                        ["exec", "-it", container.containerID, "/bin/sh"]
                    ),
                    workingDirectory: "",
                    openTerminal: true
                )
                showingConfirmation = true
            }
            HStack {
                if container.state.lowercased() == "running" {
                    mutationButton("Stop", target: container.name, arguments: scoped(["stop", container.containerID]))
                    mutationButton("Restart", target: container.name, arguments: scoped(["restart", container.containerID]))
                } else {
                    mutationButton("Start", target: container.name, arguments: scoped(["start", container.containerID]))
                }
            }
            mutationButton(
                "Remove container",
                target: container.name,
                arguments: scoped(["rm", container.containerID]),
                destructive: true
            )
        } else {
            inspectorPlaceholder("Select a container")
        }
    }

    @ViewBuilder
    private var imageInspector: some View {
        if let image {
            Label("\(image.repository):\(image.tag)", systemImage: "shippingbox")
                .font(.system(size: 14, weight: .semibold))
            LabeledContent("ID", value: image.imageID)
            LabeledContent("Size", value: image.size)
            LabeledContent("Created", value: image.created)
            Button("Inspect") {
                Task {
                    await run(scoped(["inspect", image.imageID]), exposeOutput: true)
                }
            }
            mutationButton(
                "Remove image",
                target: "\(image.repository):\(image.tag)",
                arguments: scoped(["rmi", image.imageID]),
                destructive: true
            )
        } else {
            inspectorPlaceholder("Select an image")
        }
    }

    @ViewBuilder
    private var composeInspector: some View {
        if let compose {
            Label(compose.name, systemImage: "square.3.layers.3d")
                .font(.system(size: 14, weight: .semibold))
            LabeledContent("Status", value: compose.status)
            TextField("Absolute project directory", text: $composeWorkingDirectory)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 10).monospaced())
            Button("Services") {
                Task {
                    await run(
                        scoped(["compose", "ps"]),
                        workingDirectory: composeWorkingDirectory,
                        exposeOutput: true
                    )
                }
            }
            Button("Logs") {
                Task {
                    await run(
                        scoped(["compose", "logs", "--tail", "300"]),
                        workingDirectory: composeWorkingDirectory,
                        exposeOutput: true
                    )
                }
            }
            mutationButton(
                "Compose up",
                target: compose.name,
                arguments: scoped(["compose", "up", "-d"]),
                workingDirectory: composeWorkingDirectory
            )
            mutationButton(
                "Compose down",
                target: compose.name,
                arguments: scoped(["compose", "down"]),
                workingDirectory: composeWorkingDirectory,
                destructive: true
            )
        } else {
            inspectorPlaceholder("Select a Compose project")
        }
    }

    private var operationConsole: some View {
        VStack(spacing: 0) {
            HStack {
                Text("\(backendName) output")
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
                    Button("Cancel", role: .destructive) {
                        Task { await model.cancelToolOperation() }
                    }
                }
            }
            .padding(.horizontal, 12)
            .frame(height: 34)
            ScrollView([.vertical, .horizontal]) {
                Text(detailOutput.isEmpty ? "Select a resource action to inspect its output." : detailOutput)
                    .font(.system(size: 10).monospaced())
                    .foregroundStyle(detailOutput.isEmpty ? .secondary : .primary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding(12)
            }
            .background(Color(nsColor: .textBackgroundColor))
        }
    }

    private func mutationButton(
        _ title: String,
        target: String,
        arguments: [String],
        workingDirectory: String = "",
        destructive: Bool = false
    ) -> some View {
        Button(title, role: destructive ? .destructive : nil) {
            pendingAction = PendingDockerAction(
                title: "\(title)?",
                target: target,
                arguments: arguments,
                workingDirectory: workingDirectory
            )
            showingConfirmation = true
        }
    }

    private func inspectorPlaceholder(_ title: String) -> some View {
        ContentUnavailableView(title, systemImage: "cursorarrow.click")
    }

    private func scoped(_ arguments: [String]) -> [String] {
        guard !selectedContext.isEmpty else { return arguments }
        return isPodmanBackend
            ? ["--connection", selectedContext] + arguments
            : ["--context", selectedContext] + arguments
    }

    private func refreshAll() async {
        isRefreshing = true
        defer { isRefreshing = false }
        let contextArguments = isPodmanBackend
            ? ["system", "connection", "list", "--format", "json"]
            : ["context", "ls", "--format", "{{json .}}"]
        let output = await run(contextArguments, exposeOutput: false)
        contexts = DockerOutputParser.contexts(output)
        if !contexts.contains(where: { $0.name == selectedContext }) {
            selectedContext = contexts.first(where: \.current)?.name ?? contexts.first?.name ?? ""
        }
        await refreshResources()
    }

    private func refreshResources() async {
        guard capability?.available == true else { return }
        let structuredFormat = isPodmanBackend ? "json" : "{{json .}}"
        let containerOutput = await run(
            scoped(["ps", "--all", "--format", structuredFormat]),
            exposeOutput: false
        )
        containers = DockerOutputParser.containers(containerOutput)
        if !containers.contains(where: { $0.id == selectedContainerID }) {
            selectedContainerID = containers.first?.id
        }

        let imageOutput = await run(
            scoped(["images", "--format", structuredFormat]),
            exposeOutput: false
        )
        images = DockerOutputParser.images(imageOutput)
        if !images.contains(where: { $0.id == selectedImageID }) {
            selectedImageID = images.first?.id
        }

        let composeOutput = await run(
            scoped(["compose", "ls", "--format", "json"]),
            exposeOutput: false
        )
        composeProjects = DockerOutputParser.compose(composeOutput)
        if !composeProjects.contains(where: { $0.id == selectedComposeID }) {
            selectedComposeID = composeProjects.first?.id
        }
        detailOutput =
            "Loaded \(containers.count) containers, \(images.count) images, and \(composeProjects.count) Compose projects."
    }

    @discardableResult
    private func run(
        _ arguments: [String],
        workingDirectory: String = "",
        confirmedMutation: Bool = false,
        exposeOutput: Bool
    ) async -> String {
        let result = await model.runTool(
            adapterID: "docker",
            arguments: arguments,
            workingDirectory: workingDirectory,
            confirmedMutation: confirmedMutation
        )
        let output = result?.output ?? ""
        if exposeOutput {
            detailOutput = output
        }
        return output
    }
}

enum DockerOutputParser {
    static func contexts(_ output: String) -> [DockerContextItem] {
        dictionaries(output).compactMap { value in
            guard let name = string(value["Name"]), !name.isEmpty else { return nil }
            return DockerContextItem(
                name: name,
                endpoint: string(value["DockerEndpoint"])
                    ?? string(value["Endpoint"])
                    ?? string(value["URI"])
                    ?? "",
                description: string(value["Description"])
                    ?? (bool(value["IsMachine"]) ? "Podman machine" : ""),
                current: bool(value["Current"]) || bool(value["Default"])
            )
        }
    }

    static func containers(_ output: String) -> [DockerContainerItem] {
        dictionaries(output).compactMap { value in
            guard let id = string(value["ID"]) ?? string(value["Id"]), !id.isEmpty else {
                return nil
            }
            return DockerContainerItem(
                containerID: id,
                name: string(value["Names"]) ?? string(value["Name"]) ?? id,
                image: string(value["Image"]) ?? "",
                state: string(value["State"]) ?? "",
                status: string(value["Status"]) ?? "",
                ports: string(value["Ports"]) ?? ""
            )
        }
    }

    static func images(_ output: String) -> [DockerImageItem] {
        dictionaries(output).compactMap { value in
            guard let id = string(value["ID"]) ?? string(value["Id"]), !id.isEmpty else {
                return nil
            }
            let parsedName = repositoryAndTag(
                repository: string(value["Repository"]),
                tag: string(value["Tag"]),
                names: string(value["Names"])
            )
            return DockerImageItem(
                imageID: id,
                repository: parsedName.repository,
                tag: parsedName.tag,
                size: string(value["Size"]) ?? "",
                created: string(value["CreatedSince"]) ?? string(value["CreatedAt"]) ?? ""
            )
        }
    }

    static func compose(_ output: String) -> [DockerComposeItem] {
        dictionaries(output).compactMap { value in
            guard let name = string(value["Name"]), !name.isEmpty else { return nil }
            return DockerComposeItem(
                name: name,
                status: string(value["Status"]) ?? "",
                configFiles: string(value["ConfigFiles"]) ?? ""
            )
        }
    }

    static func dictionaries(_ output: String) -> [[String: Any]] {
        let structuredOutput = output
            .split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
            .map(String.init)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("›") }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let data = structuredOutput.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) {
            if let value = json as? [String: Any] {
                return [value]
            }
            if let values = json as? [[String: Any]] {
                return values
            }
        }
        let candidates = output
            .split(whereSeparator: \.isNewline)
            .map { String($0).trimmingCharacters(in: .whitespaces) }
            .filter { $0.hasPrefix("{") || $0.hasPrefix("[") }
        var result: [[String: Any]] = []
        for candidate in candidates {
            guard let data = candidate.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data)
            else {
                continue
            }
            if let value = json as? [String: Any] {
                result.append(value)
            } else if let values = json as? [[String: Any]] {
                result.append(contentsOf: values)
            }
        }
        return result
    }

    private static func string(_ value: Any?) -> String? {
        switch value {
        case let value as String: value
        case let value as NSNumber: value.stringValue
        case let values as [String]: values.joined(separator: ", ")
        case let values as [[String: Any]]:
            values.compactMap { port in
                guard let container = string(port["container_port"]) else { return nil }
                let host = string(port["host_port"]) ?? ""
                let protocolName = string(port["protocol"]) ?? "tcp"
                return host.isEmpty || host == "0"
                    ? "\(container)/\(protocolName)"
                    : "\(host):\(container)/\(protocolName)"
            }
            .joined(separator: ", ")
        default: nil
        }
    }

    private static func repositoryAndTag(
        repository: String?,
        tag: String?,
        names: String?
    ) -> (repository: String, tag: String) {
        if let repository, !repository.isEmpty {
            return (repository, tag?.isEmpty == false ? tag ?? "<none>" : "<none>")
        }
        guard let firstName = names?.split(separator: ",").first.map(String.init),
              !firstName.isEmpty else {
            return ("<none>", "<none>")
        }
        let lastSlash = firstName.lastIndex(of: "/")
        if let colon = firstName.lastIndex(of: ":"),
           lastSlash == nil || colon > lastSlash! {
            return (
                String(firstName[..<colon]),
                String(firstName[firstName.index(after: colon)...])
            )
        }
        return (firstName, "latest")
    }

    private static func bool(_ value: Any?) -> Bool {
        switch value {
        case let value as Bool: value
        case let value as String: ["true", "*", "yes"].contains(value.lowercased())
        case let value as NSNumber: value.boolValue
        default: false
        }
    }
}
