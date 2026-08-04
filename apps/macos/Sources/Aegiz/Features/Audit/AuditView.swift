import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct AuditView: View {
    @Bindable var model: AppModel
    @State private var searchText = ""
    @State private var selectedEventID: Int64?
    @State private var outcomeFilter = "all"
    @State private var actionFilter = "all"
    @State private var timeFilter = AuditTimeFilter.all
    @State private var backupRequest: BackupSheetRequest?

    private var filteredEvents: [AuditEventModel] {
        return model.auditEvents.filter { event in
            let searchMatch = searchText.isEmpty
                || event.action.localizedCaseInsensitiveContains(searchText)
                || event.outcome.localizedCaseInsensitiveContains(searchText)
                || event.resourceID.localizedCaseInsensitiveContains(searchText)
                || event.detail.localizedCaseInsensitiveContains(searchText)
            let outcomeMatch = outcomeFilter == "all" || event.outcome == outcomeFilter
            let actionMatch = actionFilter == "all" || event.action == actionFilter
            let timeMatch = timeFilter.cutoff.map { $0 <= event.occurredAt } ?? true
            return searchMatch && outcomeMatch && actionMatch && timeMatch
        }
    }

    private var outcomes: [String] {
        Array(Set(model.auditEvents.map(\.outcome))).sorted()
    }

    private var actions: [String] {
        Array(Set(model.auditEvents.map(\.action))).sorted()
    }

    private var selectedEvent: AuditEventModel? {
        model.auditEvents.first { $0.id == selectedEventID }
    }

    var body: some View {
        VStack(spacing: 0) {
            AegizPageHeader(
                "Local Audit",
                subtitle: "Redacted operation summaries stored only on this Mac",
                symbol: "list.bullet.clipboard"
            ) {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) {
                        TextField("Filter events", text: $searchText)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 200)
                        exportMenu
                        backupMenu
                        refreshButton
                    }
                    HStack(spacing: 8) {
                        TextField("Filter", text: $searchText)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 130)
                        Menu {
                            Button("Export JSON…") { exportAudit(.json) }
                            Button("Export CSV…") { exportAudit(.csv) }
                            Divider()
                            Button("Create Encrypted Backup…") { chooseBackupDestination() }
                            Button("Restore Encrypted Backup…") { chooseBackupSource() }
                        } label: {
                            Label("Actions", systemImage: "ellipsis.circle")
                        }
                        refreshButton.labelStyle(.iconOnly)
                    }
                }
            }
            Divider()
            filters
            Divider()
            if filteredEvents.isEmpty {
                AegizWorkspaceStateView(
                    "No matching audit events",
                    message: "Host imports, tunnel changes, and adapter operations appear here.",
                    symbol: "checkmark.shield"
                )
            } else {
                HSplitView {
                    List(filteredEvents, selection: $selectedEventID) { event in
                        AuditRow(event: event)
                            .tag(event.id)
                            .aegizInteractiveRow(isSelected: selectedEventID == event.id)
                    }
                    .listStyle(.inset)
                    .scrollContentBackground(.hidden)
                    .frame(minWidth: 390)
                    auditDetail
                        .frame(minWidth: 240, idealWidth: 290)
                }
            }
        }
        .background(AegizTheme.raised)
        .navigationTitle("Audit")
        .sheet(item: $backupRequest) { request in
            BackupPassphraseView(model: model, request: request)
        }
    }

    private var exportMenu: some View {
        Menu {
            Button("Export JSON…") { exportAudit(.json) }
            Button("Export CSV…") { exportAudit(.csv) }
        } label: {
            Label("Export", systemImage: "square.and.arrow.up")
        }
    }

    private var backupMenu: some View {
        Menu {
            Button("Create Encrypted Backup…") { chooseBackupDestination() }
            Button("Restore Encrypted Backup…") { chooseBackupSource() }
        } label: {
            Label("Backup", systemImage: "externaldrive.badge.timemachine")
        }
    }

    private var refreshButton: some View {
        Button {
            Task { await model.refresh() }
        } label: {
            Label("Refresh", systemImage: "arrow.clockwise")
        }
    }

    private var filters: some View {
        HStack(spacing: 8) {
            Picker("Outcome", selection: $outcomeFilter) {
                Text("Any outcome").tag("all")
                ForEach(outcomes, id: \.self) { Text($0.capitalized).tag($0) }
            }
            .frame(maxWidth: 150)
            Picker("Action", selection: $actionFilter) {
                Text("Any action").tag("all")
                ForEach(actions, id: \.self) { Text($0).tag($0) }
            }
            .frame(maxWidth: 230)
            Picker("Time", selection: $timeFilter) {
                ForEach(AuditTimeFilter.allCases) { Text($0.rawValue).tag($0) }
            }
            .frame(maxWidth: 130)
            Spacer()
            Text("\(filteredEvents.count) of \(model.auditEvents.count)")
                .font(.system(size: 10).monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
        .frame(height: 38)
        .background(AegizTheme.canvas.opacity(0.5))
    }

    @ViewBuilder
    private var auditDetail: some View {
        if let event = selectedEvent {
            VStack(alignment: .leading, spacing: 16) {
                Label(event.action, systemImage: outcomeSymbol(event.outcome))
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(outcomeColor(event.outcome))
                LabeledContent("Outcome", value: event.outcome.capitalized)
                LabeledContent("Time") {
                    Text(event.occurredAt.formatted(date: .abbreviated, time: .standard))
                }
                if !event.resourceID.isEmpty {
                    LabeledContent("Resource") {
                        Text(event.resourceID)
                            .font(.system(size: 10).monospaced())
                            .textSelection(.enabled)
                    }
                }
                Divider()
                Text("Summary")
                    .font(.system(size: 11, weight: .semibold))
                Text(event.detail.isEmpty ? "No additional detail was recorded." : event.detail)
                    .font(.system(size: 11).monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                Spacer()
            }
            .padding(16)
        } else {
            ContentUnavailableView {
                Label("Select an event", systemImage: "sidebar.right")
            } description: {
                Text("Its redacted local summary will appear here.")
            }
        }
    }

    private func exportAudit(_ format: AuditExportFormat) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = format == .json ? [.json] : [.commaSeparatedText]
        panel.nameFieldStringValue = "aegiz-audit-\(Int(Date().timeIntervalSince1970)).\(format.rawValue)"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        _ = model.exportAudit(to: url, format: format)
    }

    private func chooseBackupDestination() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.data]
        panel.nameFieldStringValue =
            "aegiz-\(Int(Date().timeIntervalSince1970)).\(AegizBackupManager.fileExtension)"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        backupRequest = BackupSheetRequest(mode: .create, url: url)
    }

    private func chooseBackupSource() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        backupRequest = BackupSheetRequest(mode: .restore, url: url)
    }
}

private enum AuditTimeFilter: String, CaseIterable, Identifiable {
    case all = "Any time"
    case day = "Last 24 hours"
    case week = "Last 7 days"
    case month = "Last 30 days"

    var id: String { rawValue }

    var cutoff: Date? {
        let seconds: TimeInterval? = switch self {
        case .all: nil
        case .day: 86_400
        case .week: 7 * 86_400
        case .month: 30 * 86_400
        }
        return seconds.map { Date().addingTimeInterval(-$0) }
    }
}

private enum BackupSheetMode: Equatable {
    case create
    case restore
}

private struct BackupSheetRequest: Identifiable {
    let id = UUID()
    let mode: BackupSheetMode
    let url: URL
}

private struct BackupPassphraseView: View {
    @Environment(\.dismiss) private var dismiss
    let model: AppModel
    let request: BackupSheetRequest
    @State private var passphrase = ""
    @State private var confirmation = ""
    @State private var restorePhrase = ""
    @State private var isRunning = false

    private var canSubmit: Bool {
        passphrase.count >= 12
            && (request.mode == .restore
                ? restorePhrase == "RESTORE"
                : confirmation == passphrase)
            && !isRunning
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Label(
                        request.mode == .create
                            ? "Encrypted Local Backup" : "Restore Local Backup",
                        systemImage: request.mode == .create
                            ? "lock.doc.fill" : "externaldrive.badge.timemachine"
                    )
                    .font(.title3.weight(.semibold))
                    .accessibilityHeading(.h1)
                    Text(request.url.lastPathComponent)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .help(request.url.path)
                    Text(
                        request.mode == .create
                            ? "Inventory, tunnels, database profile metadata, organization data, and redacted audit history are encrypted with AES-256-GCM. Keychain secrets and SSH private keys are never exported."
                            : "Restore atomically replaces local inventory metadata. Running tunnels are stopped and restored as off. Keychain secrets are not contained in the backup."
                    )
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    SecureField("Passphrase (at least 12 characters)", text: $passphrase)
                        .textFieldStyle(.roundedBorder)
                    if request.mode == .create {
                        SecureField("Confirm passphrase", text: $confirmation)
                            .textFieldStyle(.roundedBorder)
                    } else {
                        TextField("Type RESTORE to replace local metadata", text: $restorePhrase)
                            .textFieldStyle(.roundedBorder)
                    }
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Divider()
            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button(request.mode == .create ? "Create Backup" : "Restore Backup") {
                    isRunning = true
                    Task {
                        let success: Bool
                        if request.mode == .create {
                            success = await model.exportEncryptedBackup(
                                to: request.url,
                                passphrase: passphrase
                            )
                        } else {
                            success = await model.restoreEncryptedBackup(
                                from: request.url,
                                passphrase: passphrase
                            )
                        }
                        passphrase = ""
                        confirmation = ""
                        isRunning = false
                        if success { dismiss() }
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(request.mode == .restore ? .red : AegizTheme.accent)
                .disabled(!canSubmit)
                .keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
        .aegizAdaptiveSheet(AegizSheetSizingPolicy.backup)
        .interactiveDismissDisabled(isRunning)
    }
}

private struct AuditRow: View {
    let event: AuditEventModel

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: outcomeSymbol(event.outcome))
                .foregroundStyle(outcomeColor(event.outcome))
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(event.action)
                        .font(.system(size: 12, weight: .medium))
                    Spacer()
                    Text(event.occurredAt, style: .relative)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                Text(event.detail.isEmpty ? event.outcome.capitalized : event.detail)
                    .font(.system(size: 10).monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 3)
    }
}

private func outcomeSymbol(_ outcome: String) -> String {
    switch outcome {
    case "success", "running", "stopped": "checkmark.circle.fill"
    case "failed": "xmark.octagon.fill"
    case "cancelled": "stop.circle.fill"
    default: "clock.fill"
    }
}

private func outcomeColor(_ outcome: String) -> Color {
    switch outcome {
    case "success", "running", "stopped": .green
    case "failed": .red
    case "cancelled": .orange
    default: .secondary
    }
}
