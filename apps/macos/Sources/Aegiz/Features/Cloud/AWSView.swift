import AppKit
import Foundation
import SwiftUI

enum AWSResourceKind: String, CaseIterable, Identifiable {
    case ec2 = "EC2"
    case ecs = "ECS"
    case eks = "EKS"
    case rds = "RDS"
    case cloudWatch = "CloudWatch"

    var id: String { rawValue }
}

struct AWSIdentity {
    var account = ""
    var arn = ""
    var userID = ""
}

struct AWSResourceItem: Identifiable, Hashable {
    let id: String
    let name: String
    let state: String
    let detail: String
    let secondary: String
}

private struct PendingAWSAction {
    let title: String
    let target: String
    let arguments: [String]
    var openTerminal = false
}

struct AWSView: View {
    @Bindable var model: AppModel

    @State private var profiles: [String] = []
    @State private var selectedProfile = ""
    @State private var region = ""
    @State private var identity = AWSIdentity()
    @State private var identityDiagnostic = ""
    @State private var resourceKind = AWSResourceKind.ec2
    @State private var resources: [AWSResourceItem] = []
    @State private var selectedResourceID: String?
    @State private var output = ""
    @State private var isRefreshing = false
    @State private var pendingAction: PendingAWSAction?
    @State private var showingConfirmation = false

    private var capability: ToolCapabilityModel? { model.capability("aws") }
    private var resource: AWSResourceItem? {
        resources.first { $0.id == selectedResourceID }
    }
    private var operation: ToolOperationModel? {
        guard model.toolOperation?.adapterID == "aws" else { return nil }
        return model.toolOperation
    }

    var body: some View {
        VStack(spacing: 0) {
            AegizPageHeader(
                "AWS",
                subtitle: "Account-aware cloud workflows are being rebuilt",
                symbol: "cloud.fill"
            )
            Divider()
            AegizWorkspaceStateView(
                "AWS is under maintenance",
                message: "Profiles, SSO identity, region scoping, resources, and mutations are temporarily disabled while the module is rebuilt.",
                detail: "No AWS CLI command will run from this screen.",
                symbol: "wrench.and.screwdriver.fill",
                tint: AegizTheme.warning
            )
        }
        .background(AegizTheme.raised)
        .navigationTitle("AWS")
    }

    private var header: some View {
        AegizPageHeader(
            "AWS",
            subtitle: "Profiles, SSO sessions, account-aware resources, CloudWatch, and SSM",
            symbol: "cloud.fill"
        ) {
            HStack(spacing: 8) {
                if isRefreshing {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel("Refreshing AWS resources")
                }
                Button {
                    Task { await loadProfiles() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .disabled(isRefreshing || operation?.isRunning == true)
            }
        }
    }

    private var identityBanner: some View {
        VStack(spacing: 7) {
            HStack(spacing: 8) {
                Image(systemName: identity.account.isEmpty ? "exclamationmark.shield.fill" : "checkmark.shield.fill")
                    .foregroundStyle(identity.account.isEmpty ? .orange : .green)
                Picker("Profile", selection: $selectedProfile) {
                    ForEach(profiles, id: \.self) { profile in
                        Text(profile).tag(profile)
                    }
                }
                .labelsHidden()
                .frame(width: 190)
                TextField("Region", text: $region)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 10).monospaced())
                    .frame(width: 145)
                Text(identity.account.isEmpty ? "Account unknown" : "Account \(identity.account)")
                    .font(.system(size: 10, weight: .semibold).monospaced())
                Spacer()
                Text(identity.arn)
                    .font(.system(size: 9).monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            if !identityDiagnostic.isEmpty {
                Label(identityDiagnostic, systemImage: "person.crop.circle.badge.exclamationmark")
                    .font(.system(size: 9))
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Text("Credentials stay with AWS CLI's configured provider/SSO cache; Aegiz does not copy them.")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(
            (identity.account.isEmpty ? Color.orange : Color.green).opacity(0.055)
        )
    }

    private var resourceWorkspace: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("Service", selection: $resourceKind) {
                    ForEach(AWSResourceKind.allCases) { kind in
                        Text(kind.rawValue).tag(kind)
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 520)
                Spacer()
                Text("\(resources.count) resources")
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .padding(10)
            Divider()
            HSplitView {
                List(resources, selection: $selectedResourceID) { item in
                    HStack(spacing: 9) {
                        Circle()
                            .fill(stateColor(item.state))
                            .frame(width: 7, height: 7)
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Text(item.name)
                                    .font(.system(size: 11, weight: .semibold))
                                Spacer()
                                Text(item.state.uppercased())
                                    .font(.system(size: 8, weight: .bold).monospaced())
                                    .foregroundStyle(.secondary)
                            }
                            Text("\(item.id) · \(item.detail)")
                                .font(.system(size: 9).monospaced())
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    .padding(.vertical, 3)
                    .tag(item.id)
                    .aegizInteractiveRow(isSelected: selectedResourceID == item.id)
                }
                .scrollContentBackground(.hidden)
                .frame(minWidth: 420, idealWidth: 590)
                resourceInspector
                    .frame(minWidth: 300, idealWidth: 360)
            }
        }
    }

    private var resourceInspector: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if let resource {
                    Label(resource.name, systemImage: serviceSymbol)
                        .font(.system(size: 14, weight: .semibold))
                    LabeledContent("ID", value: resource.id)
                    LabeledContent("State", value: resource.state)
                    LabeledContent("Detail", value: resource.detail)
                    if !resource.secondary.isEmpty {
                        LabeledContent("Endpoint", value: resource.secondary)
                    }
                    Divider()
                    serviceActions(resource)
                } else {
                    ContentUnavailableView("Select a resource", systemImage: "cursorarrow.click")
                }
            }
            .padding(14)
        }
    }

    @ViewBuilder
    private func serviceActions(_ resource: AWSResourceItem) -> some View {
        switch resourceKind {
        case .ec2:
            Button("Describe") {
                Task {
                    await run(
                        awsArguments(
                            ["ec2", "describe-instances", "--instance-ids", resource.id]
                        ),
                        exposeOutput: true
                    )
                }
            }
            if resource.state == "running" {
                actionButton(
                    "Stop instance",
                    target: resource.id,
                    arguments: awsArguments(
                        ["ec2", "stop-instances", "--instance-ids", resource.id]
                    ),
                    destructive: true
                )
                actionButton(
                    "Reboot instance",
                    target: resource.id,
                    arguments: awsArguments(
                        ["ec2", "reboot-instances", "--instance-ids", resource.id]
                    )
                )
                Button("Start SSM terminal") {
                    pendingAction = PendingAWSAction(
                        title: "Start an interactive SSM session?",
                        target: resource.id,
                        arguments: awsArguments(
                            ["ssm", "start-session", "--target", resource.id],
                            includeOutput: false
                        ),
                        openTerminal: true
                    )
                    showingConfirmation = true
                }
            } else if resource.state == "stopped" {
                actionButton(
                    "Start instance",
                    target: resource.id,
                    arguments: awsArguments(
                        ["ec2", "start-instances", "--instance-ids", resource.id]
                    )
                )
            }
        case .rds:
            if resource.state == "available" {
                actionButton(
                    "Stop DB instance",
                    target: resource.id,
                    arguments: awsArguments(
                        ["rds", "stop-db-instance", "--db-instance-identifier", resource.id]
                    ),
                    destructive: true
                )
                actionButton(
                    "Reboot DB instance",
                    target: resource.id,
                    arguments: awsArguments(
                        ["rds", "reboot-db-instance", "--db-instance-identifier", resource.id]
                    )
                )
            } else if resource.state == "stopped" {
                actionButton(
                    "Start DB instance",
                    target: resource.id,
                    arguments: awsArguments(
                        ["rds", "start-db-instance", "--db-instance-identifier", resource.id]
                    )
                )
            }
        case .cloudWatch:
            Button("Tail last hour") {
                Task {
                    await run(
                        awsArguments(
                            [
                                "logs", "tail", resource.id,
                                "--since", "1h", "--format", "short",
                            ],
                            includeOutput: false
                        ),
                        exposeOutput: true
                    )
                }
            }
        case .ecs, .eks:
            Button("Copy ARN / name") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(resource.id, forType: .string)
            }
        }
    }

    private func actionButton(
        _ title: String,
        target: String,
        arguments: [String],
        destructive: Bool = false
    ) -> some View {
        Button(title, role: destructive ? .destructive : nil) {
            pendingAction = PendingAWSAction(
                title: "\(title)?",
                target: target,
                arguments: arguments
            )
            showingConfirmation = true
        }
    }

    private var outputConsole: some View {
        VStack(spacing: 0) {
            HStack {
                Text("AWS CLI output")
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

    private var serviceSymbol: String {
        switch resourceKind {
        case .ec2: "server.rack"
        case .ecs: "shippingbox"
        case .eks: "hexagon"
        case .rds: "cylinder"
        case .cloudWatch: "doc.text.magnifyingglass"
        }
    }

    private func loadProfiles() async {
        isRefreshing = true
        let profileOutput = await run(
            ["configure", "list-profiles"],
            exposeOutput: false
        )
        profiles = profileOutput
            .split(whereSeparator: \.isNewline)
            .map(String.init)
            .filter { !$0.hasPrefix("›") && !$0.isEmpty }
        if !profiles.contains(selectedProfile) {
            selectedProfile = profiles.first ?? ""
        }
        await loadIdentityAndResources()
        isRefreshing = false
    }

    private func loadIdentityAndResources() async {
        guard !selectedProfile.isEmpty else { return }
        isRefreshing = true
        let configuredRegion = await run(
            ["configure", "get", "region", "--profile", selectedProfile],
            exposeOutput: false
        )
        .split(whereSeparator: \.isNewline)
        .map(String.init)
        .first { !$0.hasPrefix("›") } ?? ""
        if region.isEmpty {
            region = configuredRegion
        }
        let identityOutput = await run(
            awsArguments(["sts", "get-caller-identity"]),
            exposeOutput: false
        )
        if operation?.success == true {
            identity = AWSOutputParser.identity(identityOutput)
            identityDiagnostic = ""
        } else {
            identity = AWSIdentity()
            identityDiagnostic = "The profile session is unavailable or expired. Run `aws sso login --profile \(selectedProfile)` outside Aegiz, then refresh."
        }
        await loadResources()
        isRefreshing = false
    }

    private func loadResources() async {
        guard !selectedProfile.isEmpty, !region.isEmpty else { return }
        let arguments: [String] = switch resourceKind {
        case .ec2:
            ["ec2", "describe-instances"]
        case .ecs:
            ["ecs", "list-clusters"]
        case .eks:
            ["eks", "list-clusters"]
        case .rds:
            ["rds", "describe-db-instances", "--max-records", "100"]
        case .cloudWatch:
            ["logs", "describe-log-groups", "--limit", "100"]
        }
        let resourceOutput = await run(
            awsArguments(arguments),
            exposeOutput: false
        )
        resources = AWSOutputParser.resources(resourceOutput, kind: resourceKind)
        if !resources.contains(where: { $0.id == selectedResourceID }) {
            selectedResourceID = resources.first?.id
        }
        output = "Loaded \(resources.count) \(resourceKind.rawValue) resources in \(region)."
    }

    private func awsArguments(
        _ arguments: [String],
        includeOutput: Bool = true
    ) -> [String] {
        var result = arguments
        result += ["--profile", selectedProfile]
        if !region.isEmpty {
            result += ["--region", region]
        }
        if includeOutput {
            result += ["--output", "json"]
        }
        result.append("--no-cli-pager")
        return result
    }

    @discardableResult
    private func run(
        _ arguments: [String],
        confirmedMutation: Bool = false,
        exposeOutput: Bool
    ) async -> String {
        await model.runTool(
            adapterID: "aws",
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

    private func stateColor(_ state: String) -> Color {
        let value = state.lowercased()
        if ["running", "available", "active"].contains(value) { return .green }
        if value.contains("pending") || value.contains("starting") || value.contains("stopping") {
            return .orange
        }
        if ["failed", "terminated", "deleting"].contains(value) { return .red }
        return .secondary
    }
}

enum AWSOutputParser {
    static func identity(_ output: String) -> AWSIdentity {
        guard let value = object(output) else { return AWSIdentity() }
        return AWSIdentity(
            account: value["Account"] as? String ?? "",
            arn: value["Arn"] as? String ?? "",
            userID: value["UserId"] as? String ?? ""
        )
    }

    static func resources(
        _ output: String,
        kind: AWSResourceKind
    ) -> [AWSResourceItem] {
        guard let root = object(output) else { return [] }
        switch kind {
        case .ec2:
            let reservations = root["Reservations"] as? [[String: Any]] ?? []
            return reservations
                .flatMap { $0["Instances"] as? [[String: Any]] ?? [] }
                .compactMap { instance in
                    guard let id = instance["InstanceId"] as? String else { return nil }
                    let tags = instance["Tags"] as? [[String: Any]] ?? []
                    let name = tags.first { $0["Key"] as? String == "Name" }?["Value"] as? String
                    let state = (instance["State"] as? [String: Any])?["Name"] as? String ?? ""
                    let placement = instance["Placement"] as? [String: Any]
                    return AWSResourceItem(
                        id: id,
                        name: name ?? id,
                        state: state,
                        detail: "\(instance["InstanceType"] as? String ?? "") · \(placement?["AvailabilityZone"] as? String ?? "")",
                        secondary: instance["PublicIpAddress"] as? String
                            ?? instance["PrivateIpAddress"] as? String
                            ?? ""
                    )
                }
        case .ecs:
            return (root["clusterArns"] as? [String] ?? []).map {
                AWSResourceItem(
                    id: $0,
                    name: $0.split(separator: "/").last.map(String.init) ?? $0,
                    state: "active",
                    detail: "ECS cluster",
                    secondary: ""
                )
            }
        case .eks:
            return (root["clusters"] as? [String] ?? []).map {
                AWSResourceItem(
                    id: $0,
                    name: $0,
                    state: "active",
                    detail: "EKS cluster",
                    secondary: ""
                )
            }
        case .rds:
            return (root["DBInstances"] as? [[String: Any]] ?? []).compactMap { database in
                guard let id = database["DBInstanceIdentifier"] as? String else { return nil }
                let endpoint = database["Endpoint"] as? [String: Any]
                return AWSResourceItem(
                    id: id,
                    name: id,
                    state: database["DBInstanceStatus"] as? String ?? "",
                    detail: "\(database["Engine"] as? String ?? "") · \(database["DBInstanceClass"] as? String ?? "")",
                    secondary: endpoint?["Address"] as? String ?? ""
                )
            }
        case .cloudWatch:
            return (root["logGroups"] as? [[String: Any]] ?? []).compactMap { group in
                guard let name = group["logGroupName"] as? String else { return nil }
                let bytes = (group["storedBytes"] as? NSNumber)?.int64Value ?? 0
                return AWSResourceItem(
                    id: name,
                    name: name,
                    state: "active",
                    detail: ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file),
                    secondary: group["arn"] as? String ?? ""
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
