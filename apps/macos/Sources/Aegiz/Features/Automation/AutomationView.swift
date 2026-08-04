import AppKit
import Foundation
import SwiftUI

private enum AutomationTool: String, CaseIterable, Identifiable {
    case terraform = "Terraform"
    case ansible = "Ansible"

    var id: String { rawValue }
}

private struct PendingAutomationAction {
    let title: String
    let adapterID: String
    let arguments: [String]
    let target: String
}

struct AutomationView: View {
    @Bindable var model: AppModel

    @State private var tool = AutomationTool.terraform
    @State private var projectDirectory = ""
    @State private var discoveredFiles: [String] = []
    @State private var reviewedPlanPath = ""
    @State private var planSummary = ""
    @State private var inventoryPath = ""
    @State private var playbookPath = ""
    @State private var hostLimit = ""
    @State private var output = ""
    @State private var pendingAction: PendingAutomationAction?
    @State private var showingConfirmation = false

    private var capability: ToolCapabilityModel? {
        switch tool {
        case .terraform: model.capability("terraform")
        case .ansible: model.capability("ansible-playbook")
        }
    }
    private var operation: ToolOperationModel? {
        guard ["terraform", "ansible", "ansible-playbook", "ansible-inventory"]
            .contains(model.toolOperation?.adapterID ?? "")
        else {
            return nil
        }
        return model.toolOperation
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            projectBar
            Divider()
            if capability?.available == true {
                VSplitView {
                    HSplitView {
                        actions
                            .frame(minWidth: 380, idealWidth: 480)
                        projectInspector
                            .frame(minWidth: 280, idealWidth: 350)
                    }
                    .frame(minHeight: 340)
                    outputConsole
                        .frame(minHeight: 170, idealHeight: 240)
                }
            } else {
                AegizCapabilityUnavailableView(
                    tool: tool.rawValue,
                    diagnostic: capability?.diagnostic ?? "No trusted executable was detected.",
                    installHint: "Install \(tool.rawValue) in a trusted system location, then check again.",
                    symbol: "hammer"
                ) {
                    Task { await model.refresh() }
                }
            }
        }
        .background(AegizTheme.raised)
        .navigationTitle("Automation")
        .confirmationDialog(
            pendingAction?.title ?? "Run automation mutation?",
            isPresented: $showingConfirmation,
            titleVisibility: .visible
        ) {
            Button("Run on \(pendingAction?.target ?? "project")", role: .destructive) {
                guard let pendingAction else { return }
                Task {
                    await run(
                        adapterID: pendingAction.adapterID,
                        arguments: pendingAction.arguments,
                        confirmedMutation: true
                    )
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                "Project: \(projectDirectory.isEmpty ? "not selected" : projectDirectory). Aegiz runs the executable directly and records a redacted audit summary."
            )
        }
    }

    private var header: some View {
        AegizPageHeader(
            "Automation",
            subtitle: "Reviewed Terraform plans and guarded Ansible execution",
            symbol: "hammer.fill"
        ) {
            Picker("Tool", selection: $tool) {
                ForEach(AutomationTool.allCases) { tool in
                    Text(tool.rawValue).tag(tool)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 230)
        }
    }

    private var projectBar: some View {
        HStack(spacing: 8) {
            Label("Project", systemImage: "folder")
                .font(.system(size: 10, weight: .semibold))
            TextField("Choose an absolute project directory", text: $projectDirectory)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 10).monospaced())
                .onSubmit { discoverProject() }
            Button("Choose…") { chooseProject() }
            Button("Discover") { discoverProject() }
                .disabled(projectDirectory.isEmpty)
            Spacer()
            if let capability {
                Text(capability.version)
                    .font(.system(size: 9).monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 42)
        .background(AegizTheme.canvas.opacity(0.55))
    }

    @ViewBuilder
    private var actions: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if tool == .terraform {
                    terraformActions
                } else {
                    ansibleActions
                }
            }
            .padding(14)
        }
    }

    private var terraformActions: some View {
        VStack(alignment: .leading, spacing: 12) {
            actionSection("Checks", symbol: "checkmark.shield") {
                actionButton("Format check + diff", symbol: "text.alignleft") {
                    Task {
                        await run(
                            adapterID: "terraform",
                            arguments: ["fmt", "-check", "-diff"]
                        )
                    }
                }
                actionButton("Validate", symbol: "checkmark.circle") {
                    Task {
                        await run(
                            adapterID: "terraform",
                            arguments: ["validate", "-no-color"]
                        )
                    }
                }
                Button("Initialize providers…") {
                    confirm(
                        title: "Initialize this Terraform project?",
                        adapterID: "terraform",
                        arguments: ["init", "-input=false", "-no-color"],
                        target: projectDirectory
                    )
                }
            }

            actionSection("Reviewed plan", symbol: "doc.text.magnifyingglass") {
                Button("Create and Review Saved Plan…") {
                    createPlan()
                }
                .buttonStyle(.borderedProminent)
                if !planSummary.isEmpty {
                    Label(planSummary, systemImage: "list.number")
                        .font(.system(size: 10, weight: .semibold).monospaced())
                        .foregroundStyle(.orange)
                }
                if !reviewedPlanPath.isEmpty {
                    Text(reviewedPlanPath)
                        .font(.system(size: 9).monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                    Button("Apply Reviewed Plan", role: .destructive) {
                        guard FileManager.default.fileExists(atPath: reviewedPlanPath) else {
                            model.notice = "The reviewed plan file no longer exists."
                            reviewedPlanPath = ""
                            return
                        }
                        confirm(
                            title: "Apply this exact reviewed plan?",
                            adapterID: "terraform",
                            arguments: ["apply", "-input=false", "-no-color", reviewedPlanPath],
                            target: (reviewedPlanPath as NSString).lastPathComponent
                        )
                    }
                }
                Text("Aegiz never offers `terraform apply` without a plan file created and reviewed in this session.")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var ansibleActions: some View {
        VStack(alignment: .leading, spacing: 12) {
            actionSection("Inputs", symbol: "doc.on.doc") {
                HStack {
                    TextField("Inventory file", text: $inventoryPath)
                        .textFieldStyle(.roundedBorder)
                    Button("Choose…") {
                        chooseFile(binding: $inventoryPath)
                    }
                }
                HStack {
                    TextField("Playbook file", text: $playbookPath)
                        .textFieldStyle(.roundedBorder)
                    Button("Choose…") {
                        chooseFile(binding: $playbookPath)
                    }
                }
                TextField("Host limit (optional)", text: $hostLimit)
                    .textFieldStyle(.roundedBorder)
            }
            actionSection("Inventory & dry run", symbol: "network") {
                actionButton("Inventory graph", symbol: "point.3.connected.trianglepath.dotted") {
                    guard validateAnsibleInputs(requirePlaybook: false) else { return }
                    Task {
                        await run(
                            adapterID: "ansible-inventory",
                            arguments: ["-i", inventoryPath, "--graph"]
                        )
                    }
                }
                actionButton("Check mode + diff", symbol: "doc.text.magnifyingglass") {
                    guard validateAnsibleInputs(requirePlaybook: true) else { return }
                    Task {
                        await run(
                            adapterID: "ansible-playbook",
                            arguments: ansiblePlaybookArguments(checkMode: true)
                        )
                    }
                }
            }
            actionSection("Guarded execution", symbol: "play.fill") {
                Button("Run Playbook…") {
                    guard validateAnsibleInputs(requirePlaybook: true) else { return }
                    confirm(
                        title: "Run this Ansible playbook?",
                        adapterID: "ansible-playbook",
                        arguments: ansiblePlaybookArguments(checkMode: false),
                        target: (playbookPath as NSString).lastPathComponent
                    )
                }
                .buttonStyle(.borderedProminent)
                Text("No raw extra-vars field is provided. Secrets must stay in your existing Ansible Vault or credential provider; streamed output is redacted.")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var projectInspector: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Discovered files")
                .font(.system(size: 11, weight: .semibold))
            if discoveredFiles.isEmpty {
                ContentUnavailableView(
                    "No project scanned",
                    systemImage: "folder.badge.questionmark",
                    description: Text("Choose a directory to find Terraform and Ansible files.")
                )
            } else {
                List(discoveredFiles, id: \.self) { file in
                    Label(file, systemImage: file.hasSuffix(".tf") ? "doc.text" : "doc")
                        .font(.system(size: 10).monospaced())
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
            }
        }
        .padding(12)
    }

    private var outputConsole: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Automation output")
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
                Text(output.isEmpty ? "Choose a check, plan, graph, or run action." : output)
                    .font(.system(size: 10).monospaced())
                    .foregroundStyle(output.isEmpty ? .secondary : .primary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding(12)
            }
            .background(Color(nsColor: .textBackgroundColor))
        }
    }

    private func actionSection<Content: View>(
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

    private func chooseProject() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        projectDirectory = url.path
        discoverProject()
    }

    private func discoverProject() {
        let url = URL(filePath: projectDirectory)
        var isDirectory: ObjCBool = false
        guard url.path.hasPrefix("/"),
              FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              isDirectory.boolValue
        else {
            model.notice = "Choose an existing absolute project directory."
            return
        }
        let files = (try? FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        discoveredFiles = files
            .filter { ["tf", "tfvars", "yml", "yaml", "json"].contains($0.pathExtension.lowercased()) }
            .map(\.lastPathComponent)
            .sorted()
        reviewedPlanPath = ""
        planSummary = ""
        if inventoryPath.isEmpty,
           let inventory = files.first(where: {
               $0.lastPathComponent.localizedCaseInsensitiveContains("inventor")
           }) {
            inventoryPath = inventory.path
        }
        if playbookPath.isEmpty,
           let playbook = files.first(where: {
               ["yml", "yaml"].contains($0.pathExtension.lowercased())
           }) {
            playbookPath = playbook.path
        }
    }

    private func createPlan() {
        guard !projectDirectory.isEmpty else {
            model.notice = "Choose a Terraform project directory first."
            return
        }
        let panel = NSSavePanel()
        panel.directoryURL = URL(filePath: projectDirectory)
        panel.nameFieldStringValue = "aegiz-\(Int(Date().timeIntervalSince1970)).tfplan"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        reviewedPlanPath = ""
        planSummary = ""
        Task {
            await run(
                adapterID: "terraform",
                arguments: [
                    "plan", "-input=false", "-no-color", "-out=\(url.path)",
                ]
            )
            guard operation?.success == true,
                  FileManager.default.fileExists(atPath: url.path)
            else {
                return
            }
            await run(
                adapterID: "terraform",
                arguments: ["show", "-no-color", url.path]
            )
            guard operation?.success == true else { return }
            reviewedPlanPath = url.path
            planSummary = TerraformPlanSummary.extract(output)
        }
    }

    private func chooseFile(binding: Binding<String>) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        if !projectDirectory.isEmpty {
            panel.directoryURL = URL(filePath: projectDirectory)
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        binding.wrappedValue = url.path
    }

    private func validateAnsibleInputs(requirePlaybook: Bool) -> Bool {
        guard inventoryPath.hasPrefix("/"),
              FileManager.default.fileExists(atPath: inventoryPath)
        else {
            model.notice = "Choose an existing absolute inventory file."
            return false
        }
        if requirePlaybook,
           (!playbookPath.hasPrefix("/") || !FileManager.default.fileExists(atPath: playbookPath)) {
            model.notice = "Choose an existing absolute playbook file."
            return false
        }
        guard !hostLimit.contains("\n"), !hostLimit.contains("\0") else {
            model.notice = "The host limit contains unsupported control characters."
            return false
        }
        return true
    }

    private func ansiblePlaybookArguments(checkMode: Bool) -> [String] {
        var arguments = ["-i", inventoryPath]
        if checkMode {
            arguments += ["--check", "--diff"]
        }
        if !hostLimit.trimmingCharacters(in: .whitespaces).isEmpty {
            arguments += ["--limit", hostLimit.trimmingCharacters(in: .whitespaces)]
        }
        arguments.append(playbookPath)
        return arguments
    }

    private func confirm(
        title: String,
        adapterID: String,
        arguments: [String],
        target: String
    ) {
        pendingAction = PendingAutomationAction(
            title: title,
            adapterID: adapterID,
            arguments: arguments,
            target: target
        )
        showingConfirmation = true
    }

    private func run(
        adapterID: String,
        arguments: [String],
        confirmedMutation: Bool = false
    ) async {
        guard !projectDirectory.isEmpty else {
            model.notice = "Choose a project directory first."
            return
        }
        await model.runTool(
            adapterID: adapterID,
            arguments: arguments,
            workingDirectory: projectDirectory,
            confirmedMutation: confirmedMutation
        )
        output = model.toolOperation?.output ?? ""
    }
}

enum TerraformPlanSummary {
    static func extract(_ output: String) -> String {
        for line in output.split(whereSeparator: \.isNewline).reversed() {
            let value = line.trimmingCharacters(in: .whitespaces)
            if value.contains("No changes.") {
                return "No changes"
            }
            if value.hasPrefix("Plan:") {
                let numbers = value
                    .split(whereSeparator: { !$0.isNumber })
                    .compactMap { Int($0) }
                if numbers.count >= 3 {
                    return "+\(numbers[0]) ~\(numbers[1]) -\(numbers[2])"
                }
                return String(value.prefix(180))
            }
        }
        return "Plan reviewed · inspect the full output below"
    }
}
