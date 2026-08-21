import AppKit
import QuickLookUI
import SwiftUI

private enum FileTransferStatus: String, Sendable {
    case queued = "Queued"
    case running = "Running"
    case completed = "Completed"
    case failed = "Failed"
    case cancelled = "Cancelled"
}

private struct SFTPTransferSpec: Sendable {
    let local: String
    let remote: String
}

private struct SFTPBatchOperation: Sendable {
    let operation: String
    let fields: [String]
}

private struct FileTransferRecord: Identifiable, Sendable {
    let id = UUID()
    let title: String
    let route: String
    let host: HostModel
    let operation: String
    let fields: [String]
    var status = FileTransferStatus.queued
    var progress: UInt32 = 0
    var attempts = 0
    var success: Bool?
}

private enum PendingSFTPMutation {
    case uploads([SFTPTransferSpec])
    case delete(remote: String, directory: Bool)
    case batch(title: String, operations: [SFTPBatchOperation])
    case rename(from: String, to: String)
    case mkdir(remote: String)
    case chmod(mode: String, remote: String)
}

private enum SFTPConflictPolicy: String, CaseIterable, Identifiable {
    case ask = "Ask"
    case replace = "Replace"
    case rename = "Keep both"
    case skip = "Skip"

    var id: String { rawValue }
}

private enum FilePreviewState {
    case idle
    case loading(name: String)
    case text(name: String, document: FileTextPreviewDocument)
    case empty(name: String)
    case unavailable(name: String, message: String)

    var name: String {
        switch self {
        case .idle: "Preview"
        case .loading(let name), .text(let name, _), .empty(let name), .unavailable(let name, _):
            name
        }
    }
}

struct FilesView: View {
    @Bindable var model: AppModel
    @State private var remotePath = "."
    @State private var entries: [SFTPEntryModel] = []
    @State private var selectedEntryID: String?
    @State private var selectedEntryIDs = Set<String>()
    @State private var selectionAnchorID: String?
    @State private var newFolderName = ""
    @State private var renameValue = ""
    @State private var chmodValue = "644"
    @State private var transfers: [FileTransferRecord] = []
    @State private var previewState = FilePreviewState.idle
    @State private var showingPreview = false
    @State private var previewTask: Task<Void, Never>?
    @State private var previewRequestID: UUID?
    @State private var pendingMutation: PendingSFTPMutation?
    @State private var showingMutationConfirmation = false
    @State private var pendingConflictCount = 0
    @State private var conflictPolicy = SFTPConflictPolicy.ask
    @State private var transferWorker: Task<Void, Never>?
    @State private var isDropTargeted = false
    @State private var compactInspectorExpanded = false
    @State private var isListing = false
    @State private var hasLoadedListing = false
    @State private var listingRequestID: UUID?
    @State private var remoteClipboard: [SFTPEntryModel] = []
    @State private var clipboardIsCut = false
    @State private var showingConnectionSettings = false
    @State private var showingNewFolder = false
    @State private var showingMove = false
    @State private var moveDestination = ""

    private var host: HostModel? { model.selectedHost }
    private var selectedEntry: SFTPEntryModel? {
        entries.first { $0.id == selectedEntryID }
    }
    private var selectedEntries: [SFTPEntryModel] {
        entries.filter { selectedEntryIDs.contains($0.id) }
    }
    private var selectedFileEntries: [SFTPEntryModel] {
        selectedEntries.filter { !$0.isDirectory }
    }
    private var capability: ToolCapabilityModel? { model.capability("sftp") }
    private var operation: ToolOperationModel? {
        guard model.toolOperation?.adapterID == "sftp" else { return nil }
        return model.toolOperation
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            routeBar
            Divider()
            if let host, capability?.available == true {
                VStack(spacing: 0) {
                    browserToolbar
                    Divider()
                    browser(host)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    Divider()
                    transferQueue
                }
            } else {
                if capability?.available == false {
                    AegizCapabilityUnavailableView(
                        tool: "OpenSSH SFTP",
                        diagnostic: capability?.diagnostic ?? "Aegiz requires /usr/bin/sftp.",
                        installHint: "Install the macOS OpenSSH client tools, then check again.",
                        symbol: "folder.badge.gearshape"
                    ) {
                        Task { await model.refresh() }
                    }
                } else {
                    AegizWorkspaceStateView(
                        "Select an SSH host",
                        message: "Choose a host above to browse its files through your existing OpenSSH route.",
                        symbol: "folder.badge.gearshape"
                    )
                }
            }
        }
        .background(AegizTheme.raised)
        .navigationTitle("Files")
        .confirmationDialog(
            mutationTitle,
            isPresented: $showingMutationConfirmation,
            titleVisibility: .visible
        ) {
            Button("Continue on \(host?.alias ?? "host")", role: .destructive) {
                executePendingMutation()
            }
            Button("Cancel", role: .cancel) {
                pendingMutation = nil
                pendingConflictCount = 0
            }
        } message: {
            Text(mutationMessage)
        }
        .sheet(isPresented: $showingPreview) {
            FilePreviewSheet(state: previewState) {
                if previewTask != nil {
                    cancelPreview()
                } else {
                    showingPreview = false
                }
            }
        }
        .sheet(isPresented: $showingConnectionSettings) {
            SFTPConnectionSheet(
                host: host,
                secrets: model.secrets,
                selectedSecretID: Binding(
                    get: { host.map { model.sftpSecretReference(for: $0.id) } ?? "" },
                    set: { value in
                        if let host { model.setSFTPSecretReference(value, for: host.id) }
                    }
                ),
                createSecret: {
                    model.beginCreatingSecret(kind: .sshPassword)
                    showingConnectionSettings = false
                }
            )
        }
        .sheet(isPresented: $showingNewFolder) {
            SFTPNewFolderSheet(name: $newFolderName) {
                guard Self.isSafeLeafName(newFolderName) else {
                    model.notice = "Enter a safe directory name without path separators."
                    return
                }
                showingNewFolder = false
                confirm(.mkdir(remote: SFTPListingParser.remotePath(remotePath, appending: newFolderName)))
            }
        }
        .sheet(isPresented: $showingMove) {
            SFTPMoveSheet(destination: $moveDestination, itemCount: selectedEntries.count) {
                moveSelected()
            }
        }
        .onChange(of: selectedEntryID) { _, _ in
            renameValue = selectedEntry?.name ?? ""
            if let permissions = selectedEntry?.permissions,
               let mode = Self.octalMode(from: permissions) {
                chmodValue = mode
            }
        }
        .task(id: listingContextID) {
            await loadInitialListing()
        }
    }

    private var header: some View {
        AegizPageHeader(
            "Files",
            subtitle: "Browse and transfer through your OpenSSH routes",
            symbol: "folder.fill"
        ) {
            Picker(
                "Host",
                selection: Binding(
                    get: { model.selectedHostID ?? "" },
                    set: {
                        model.selectedHostID = $0
                        entries = []
                        selectedEntryID = nil
                        selectedEntryIDs = []
                        selectionAnchorID = nil
                        remotePath = "."
                        newFolderName = ""
                        hasLoadedListing = false
                    }
                )
            ) {
                ForEach(model.hosts) { host in
                    Text(host.alias).tag(host.id)
                }
            }
            .frame(width: 190)
            .help("Choose the remote SSH host")
        }
    }

    private var listingContextID: String {
        "\(model.selectedHostID ?? "")-\(capability?.available == true)"
    }

    private var routeBar: some View {
        HStack(spacing: 8) {
            Image(systemName: capability?.available == true ? "checkmark.circle.fill" : "clock.fill")
                .foregroundStyle(capability?.available == true ? .green : .orange)
            Text(host?.alias ?? "No host")
                .font(.system(size: 11, weight: .semibold))
            TextField("Remote path", text: $remotePath)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 10).monospaced())
                .onSubmit { refreshListing() }
            Button {
                navigateUp()
            } label: {
                Label("Up", systemImage: "arrow.up")
            }
            .help("Open the parent directory")
            Button {
                refreshListing()
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.borderedProminent)
            .help("Refresh this remote directory")
            Button {
                showingConnectionSettings = true
            } label: {
                Label(
                    model.sftpSecretReference(for: host?.id ?? "").isEmpty ? "Authentication" : "Password saved",
                    systemImage: "key.fill"
                )
            }
            .help("Choose a Keychain SSH password or use your OpenSSH config and agent")
            if operation?.isRunning == true {
                Button("Cancel", role: .destructive) {
                    Task { await model.cancelToolOperation() }
                }
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 44)
        .background(AegizTheme.canvas.opacity(0.55))
    }

    private func browser(_ host: HostModel) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 0) {
                fileListing(host)
                    .frame(minWidth: 360, maxWidth: .infinity, maxHeight: .infinity)
                    .layoutPriority(1)
                Divider()
                inspector
                    .frame(width: 280)
                    .frame(maxHeight: .infinity)
            }
            .frame(minWidth: 641, maxWidth: .infinity, maxHeight: .infinity)

            VStack(spacing: 0) {
                fileListing(host)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                Divider()
                DisclosureGroup(isExpanded: $compactInspectorExpanded) {
                    inspector
                        .frame(maxWidth: .infinity, minHeight: 220, maxHeight: 280)
                } label: {
                    HStack(spacing: 8) {
                        Label("Details & file actions", systemImage: "info.circle")
                            .font(.system(size: 11, weight: .semibold))
                        Spacer()
                        if let selectedEntry {
                            Text(selectedEntry.name)
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(AegizTheme.canvas.opacity(0.35))
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            let files = urls.filter(\.isFileURL)
            guard !files.isEmpty else { return false }
            prepareUploads(files)
            return true
        } isTargeted: { targeted in
            isDropTargeted = targeted
        }
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: 10)
                    .stroke(AegizTheme.accent, style: StrokeStyle(lineWidth: 2, dash: [7]))
                    .background(AegizTheme.accent.opacity(0.08))
                    .overlay {
                        Label("Drop files to upload to \(remotePath)", systemImage: "arrow.up.doc.fill")
                            .font(.headline)
                            .padding(16)
                            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
                    }
                    .padding(10)
            }
        }
    }

    @ViewBuilder
    private func fileListing(_ host: HostModel) -> some View {
        if isListing && !hasLoadedListing {
            AegizWorkspaceStateView(
                "Loading \(remotePath)",
                message: "Reading the remote directory through \(host.alias).",
                symbol: "arrow.triangle.2.circlepath"
            ) {
                ProgressView()
            }
        } else if entries.isEmpty {
            ContentUnavailableView(
                hasLoadedListing ? "This directory is empty" : "No listing loaded",
                systemImage: "folder",
                description: Text(
                    hasLoadedListing
                        ? "\(remotePath) on \(host.alias) has no visible entries."
                        : "Choose Refresh to read \(remotePath) through \(host.alias)."
                )
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(spacing: 3) {
                    ForEach(entries) { entry in
                        Button {
                            select(entry)
                        } label: {
                            SFTPEntryRow(entry: entry)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .aegizInteractiveRow(isSelected: selectedEntryIDs.contains(entry.id))
                        .simultaneousGesture(TapGesture(count: 2).onEnded {
                            open(entry)
                        })
                        .contextMenu {
                            Button(entry.isDirectory ? "Open Folder" : "Preview") {
                                open(entry)
                            }
                            if !entry.isDirectory {
                                Button("Download…") {
                                    select(entry)
                                    downloadSelected()
                                }
                            }
                        }
                    }
                }
                .padding(12)
            }
            .overlay(alignment: .topTrailing) {
                if isListing {
                    ProgressView()
                        .controlSize(.small)
                        .padding(12)
                }
            }
        }
    }

    private var browserToolbar: some View {
        HStack(spacing: 8) {
            Button {
                newFolderName = ""
                showingNewFolder = true
            } label: {
                Label("New Folder", systemImage: "folder.badge.plus")
            }
            Button {
                chooseUpload()
            } label: {
                Label("Upload", systemImage: "arrow.up.doc")
            }
            Button {
                downloadSelected()
            } label: {
                Label("Download", systemImage: "arrow.down.doc")
            }
            .disabled(selectedFileEntries.isEmpty)
            Button {
                copySelected(cut: false)
            } label: {
                Label("Copy", systemImage: "doc.on.doc")
            }
            .disabled(selectedFileEntries.isEmpty)
            Button {
                copySelected(cut: true)
            } label: {
                Label("Cut", systemImage: "scissors")
            }
            .disabled(selectedEntries.isEmpty)
            Button {
                pasteClipboard()
            } label: {
                Label("Paste", systemImage: "clipboard")
            }
            .disabled(remoteClipboard.isEmpty)
            Button {
                if let entry = selectedEntry { preview(entry) }
            } label: {
                Label("Preview", systemImage: "eye")
            }
            .disabled(
                selectedEntries.count != 1
                    || selectedEntry?.isDirectory == true
                    || previewTask != nil
            )
            Menu {
                Button {
                    if let entry = selectedEntry { quickLook(entry) }
                } label: {
                    Label("Quick Look", systemImage: "eye.circle")
                }
                .disabled(
                    selectedEntries.count != 1
                        || selectedEntry?.isDirectory == true
                        || transferWorker != nil
                )
                Divider()
                Button("Move Selected…") {
                    moveDestination = remotePath
                    showingMove = true
                }
                .disabled(selectedEntries.isEmpty)
                Button("Delete Selected", role: .destructive) {
                    deleteSelected()
                }
                .disabled(selectedEntries.isEmpty)
                Divider()
                Picker("Upload conflicts", selection: $conflictPolicy) {
                    ForEach(SFTPConflictPolicy.allCases) { policy in
                        Text(policy.rawValue).tag(policy)
                    }
                }
            } label: {
                Label("More", systemImage: "ellipsis.circle")
            }
            .help("Quick Look and upload conflict settings")
            Spacer()
            Text(selectedEntries.isEmpty ? "\(entries.count) items" : "\(selectedEntries.count) selected")
                .font(.system(size: 10).monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .frame(minHeight: 42)
        .background(AegizTheme.canvas.opacity(0.40))
    }

    private var inspector: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if selectedEntries.count == 1, let entry = selectedEntry {
                    AegizInspectorSection("Selected item") {
                        Label(entry.name, systemImage: entry.isDirectory ? "folder.fill" : "doc.fill")
                            .font(.system(size: 14, weight: .semibold))
                            .lineLimit(2)
                        LabeledContent("Path") {
                            Text(entry.path)
                                .font(.system(size: 9).monospaced())
                                .textSelection(.enabled)
                                .lineLimit(3)
                        }
                        LabeledContent("Mode", value: entry.permissions)
                        LabeledContent("Owner", value: "\(entry.owner):\(entry.group)")
                        if let size = entry.size {
                            LabeledContent("Size") {
                                Text(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
                            }
                        }
                    }

                    Divider()
                    AegizInspectorSection("Actions") {
                        TextField("New name", text: $renameValue)
                            .textFieldStyle(.roundedBorder)
                        Button("Rename") {
                            guard Self.isSafeLeafName(renameValue) else {
                                model.notice = "Enter a safe file name without path separators."
                                return
                            }
                            let destination = SFTPListingParser.remotePath(
                                remotePath,
                                appending: renameValue
                            )
                            confirm(.rename(from: entry.path, to: destination))
                        }
                        HStack {
                            TextField("Mode", text: $chmodValue)
                                .textFieldStyle(.roundedBorder)
                            Button("chmod") {
                                guard Self.isOctalMode(chmodValue) else {
                                    model.notice = "Mode must be three or four octal digits."
                                    return
                                }
                                confirm(.chmod(mode: chmodValue, remote: entry.path))
                            }
                        }
                        Button("Delete", role: .destructive) {
                            confirm(.delete(remote: entry.path, directory: entry.isDirectory))
                        }
                    }
                } else if !selectedEntries.isEmpty {
                    VStack(spacing: 7) {
                        Image(systemName: "checklist")
                            .font(.system(size: 24, weight: .light))
                            .foregroundStyle(AegizTheme.accent)
                        Text("\(selectedEntries.count) items selected")
                            .font(.system(size: 13, weight: .semibold))
                        Text("Use Copy, Cut, Paste, Move, Download, or Delete Selected from the toolbar.")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 20)
                } else {
                    VStack(spacing: 7) {
                        Image(systemName: "cursorarrow.click")
                            .font(.system(size: 24, weight: .light))
                            .foregroundStyle(.tertiary)
                        Text("No item selected")
                            .font(.system(size: 13, weight: .semibold))
                        Text("Select a file for details and actions.")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 20)
                }

                Divider()
                AegizInspectorSection("New directory") {
                    TextField("Directory name", text: $newFolderName)
                        .textFieldStyle(.roundedBorder)
                    Button {
                        guard Self.isSafeLeafName(newFolderName) else {
                            model.notice = "Enter a safe directory name without path separators."
                            return
                        }
                        confirm(
                            .mkdir(
                                remote: SFTPListingParser.remotePath(
                                    remotePath,
                                    appending: newFolderName
                                )
                            )
                        )
                    } label: {
                        Label("Create Directory", systemImage: "folder.badge.plus")
                    }
                    .disabled(newFolderName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .padding(16)
        }
        .background(AegizTheme.canvas.opacity(0.35))
    }

    private var transferQueue: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Transfer queue")
                    .font(.system(size: 11, weight: .semibold))
                Spacer()
                if !transfers.isEmpty {
                    Button("Clear Finished") {
                        transfers.removeAll {
                            ![FileTransferStatus.running, .queued].contains($0.status)
                        }
                    }
                    .buttonStyle(.borderless)
                }
            }
            .padding(.horizontal, 12)
            .frame(height: 32)
            if transfers.isEmpty {
                Text("Uploads and downloads appear here with source, destination, and result.")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 10)
            } else {
                ScrollView(.horizontal) {
                    HStack(spacing: 8) {
                        ForEach(transfers) { transfer in
                            HStack(spacing: 7) {
                                if transfer.status == .running {
                                    ProgressView(
                                        value: Double(transfer.progress),
                                        total: 100
                                    )
                                    .progressViewStyle(.circular)
                                    .controlSize(.small)
                                } else if transfer.status == .queued {
                                    Image(systemName: "clock")
                                        .foregroundStyle(.secondary)
                                } else {
                                    Image(
                                        systemName: transfer.success == true
                                            ? "checkmark.circle.fill"
                                            : transfer.status == .cancelled
                                                ? "minus.circle.fill"
                                                : "xmark.circle.fill"
                                    )
                                    .foregroundStyle(
                                        transfer.success == true
                                            ? .green
                                            : transfer.status == .cancelled ? .secondary : .red
                                    )
                                }
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(transfer.title)
                                        .font(.system(size: 10, weight: .semibold))
                                    Text(transfer.route)
                                        .font(.system(size: 9).monospaced())
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                    HStack(spacing: 5) {
                                        Text(transfer.status.rawValue)
                                        if transfer.status == .running {
                                            Text("· \(transfer.progress)%")
                                        }
                                        if transfer.attempts > 1 {
                                            Text("· attempt \(transfer.attempts)")
                                        }
                                    }
                                    .font(.system(size: 8).monospacedDigit())
                                    .foregroundStyle(.secondary)
                                }
                                if transfer.status == .failed || transfer.status == .cancelled {
                                    Button {
                                        retryTransfer(transfer.id)
                                    } label: {
                                        Image(systemName: "arrow.clockwise")
                                    }
                                    .buttonStyle(.borderless)
                                    .aegizIconAction(
                                        "Retry \(transfer.title)",
                                        help: "Retry transfer"
                                    )
                                } else if transfer.status == .running || transfer.status == .queued {
                                    Button {
                                        cancelTransfer(transfer.id)
                                    } label: {
                                        Image(systemName: "xmark")
                                    }
                                    .buttonStyle(.borderless)
                                    .aegizIconAction(
                                        "Cancel \(transfer.title)",
                                        help: "Cancel transfer"
                                    )
                                }
                            }
                            .padding(8)
                            .background(AegizTheme.canvas, in: RoundedRectangle(cornerRadius: 6))
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.bottom, 10)
                }
            }
        }
        .frame(minHeight: 62, idealHeight: transfers.isEmpty ? 62 : 86)
    }

    private var mutationTitle: String {
        switch pendingMutation {
        case .uploads(let items):
            items.count == 1 ? "Upload this local file?" : "Upload \(items.count) local files?"
        case .delete: "Delete this remote item?"
        case .batch(let title, _): title
        case .rename: "Rename this remote item?"
        case .mkdir: "Create this remote directory?"
        case .chmod: "Change remote permissions?"
        case nil: "Confirm SFTP operation"
        }
    }

    private var mutationMessage: String {
        var message = "Review the exact host and path. SFTP changes cannot be undone by Aegiz."
        if pendingConflictCount > 0 {
            message += " \(pendingConflictCount) remote name conflict(s) will be replaced."
        }
        return message
    }

    private func loadInitialListing() async {
        guard let host, capability?.available == true else { return }
        remotePath = "."
        entries = []
        selectedEntryID = nil
        newFolderName = ""
        hasLoadedListing = false
        await loadListing(host: host, path: remotePath)
    }

    private func refreshListing() {
        guard let host else { return }
        let path = remotePath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty, !path.contains("\n"), !path.contains("\r") else {
            model.notice = "Enter one remote path."
            return
        }
        remotePath = path
        Task { await loadListing(host: host, path: path) }
    }

    private func loadListing(host: HostModel, path: String) async {
        let requestID = UUID()
        listingRequestID = requestID
        isListing = true
        defer {
            if listingRequestID == requestID {
                isListing = false
            }
        }

        let result = await model.runSFTPOperation(
            host: host,
            operation: "list",
            fields: [path],
            confirmedMutation: false
        )
        guard !Task.isCancelled,
              listingRequestID == requestID,
              model.selectedHostID == host.id,
              remotePath == path
        else {
            return
        }
        guard result?.success == true else {
            hasLoadedListing = false
            return
        }
        entries = SFTPListingParser.parse(result?.output ?? "", directory: path)
        selectedEntryID = nil
        selectedEntryIDs = []
        selectionAnchorID = nil
        hasLoadedListing = true
    }

    private func select(_ entry: SFTPEntryModel) {
        let modifiers = NSEvent.modifierFlags
        if modifiers.contains(.shift),
           let anchor = selectionAnchorID,
           let start = entries.firstIndex(where: { $0.id == anchor }),
           let end = entries.firstIndex(where: { $0.id == entry.id }) {
            selectedEntryIDs = Set(entries[min(start, end)...max(start, end)].map(\.id))
        } else if modifiers.contains(.command) {
            if selectedEntryIDs.contains(entry.id) {
                selectedEntryIDs.remove(entry.id)
            } else {
                selectedEntryIDs.insert(entry.id)
            }
            selectionAnchorID = entry.id
        } else {
            selectedEntryIDs = [entry.id]
            selectionAnchorID = entry.id
        }
        selectedEntryID = selectedEntryIDs.contains(entry.id)
            ? entry.id
            : selectedEntryIDs.first
        renameValue = entry.name
        if let mode = Self.octalMode(from: entry.permissions) {
            chmodValue = mode
        }
    }

    private func open(_ entry: SFTPEntryModel) {
        select(entry)
        if entry.isDirectory {
            remotePath = entry.path
            refreshListing()
        } else {
            preview(entry)
        }
    }

    private func navigateUp() {
        guard remotePath != "/", remotePath != "." else { return }
        let value = remotePath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let parent = (value as NSString).deletingLastPathComponent
        remotePath = remotePath.hasPrefix("/") ? (parent.isEmpty ? "/" : "/\(parent)") : (parent.isEmpty ? "." : parent)
        refreshListing()
    }

    private func chooseUpload() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        prepareUploads(panel.urls)
    }

    private func prepareUploads(_ urls: [URL]) {
        guard let host else { return }
        var reservedNames = Set(entries.map(\.name))
        var specs: [SFTPTransferSpec] = []
        var conflicts = 0

        for url in urls where url.isFileURL {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
                  !isDirectory.boolValue
            else {
                continue
            }
            var name = url.lastPathComponent
            let exists = reservedNames.contains(name)
            if exists {
                conflicts += 1
                switch conflictPolicy {
                case .skip:
                    continue
                case .rename:
                    name = Self.availableUploadName(name, reserved: reservedNames)
                case .ask, .replace:
                    break
                }
            }
            reservedNames.insert(name)
            specs.append(
                SFTPTransferSpec(
                    local: url.path,
                    remote: SFTPListingParser.remotePath(remotePath, appending: name)
                )
            )
        }

        guard !specs.isEmpty else {
            model.notice = conflicts > 0
                ? "All dropped files were skipped by the current conflict policy."
                : "No regular files were selected."
            return
        }
        pendingConflictCount = conflictPolicy == .rename || conflictPolicy == .skip ? 0 : conflicts
        model.notice = "Review \(specs.count) upload(s) to \(host.alias):\(remotePath)."
        confirm(.uploads(specs), preservingConflictCount: true)
    }

    private func downloadSelected() {
        guard let host, !selectedFileEntries.isEmpty else { return }
        if selectedFileEntries.count == 1, let entry = selectedFileEntries.first {
            let panel = NSSavePanel()
            panel.nameFieldStringValue = entry.name
            guard panel.runModal() == .OK, let url = panel.url else { return }
            startTransfer(
                title: "Download \(entry.name)",
                route: "\(host.alias):\(entry.path) → \(url.path)",
                operation: "download",
                fields: [entry.path, url.path]
            )
            return
        }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.prompt = "Download Here"
        guard panel.runModal() == .OK, let directory = panel.url else { return }
        for entry in selectedFileEntries {
            let destination = directory.appending(path: entry.name)
            startTransfer(
                title: "Download \(entry.name)",
                route: "\(host.alias):\(entry.path) → \(destination.path)",
                operation: "download",
                fields: [entry.path, destination.path]
            )
        }
    }

    private func copySelected(cut: Bool) {
        let files = selectedFileEntries
        guard !files.isEmpty else {
            model.notice = "Copy and cut currently support files. Open a folder, then paste into it."
            return
        }
        remoteClipboard = files
        clipboardIsCut = cut
        model.notice = "\(files.count) file(s) \(cut ? "ready to move" : "copied") from \(remotePath)."
    }

    private func pasteClipboard() {
        guard !remoteClipboard.isEmpty else { return }
        let operations = remoteClipboard.compactMap { entry -> SFTPBatchOperation? in
            let destination = SFTPListingParser.remotePath(remotePath, appending: entry.name)
            guard destination != entry.path else { return nil }
            return SFTPBatchOperation(
                operation: clipboardIsCut ? "rename" : "copy",
                fields: [entry.path, destination]
            )
        }
        guard !operations.isEmpty else {
            model.notice = "Choose another remote folder before pasting these files."
            return
        }
        confirm(.batch(title: clipboardIsCut ? "Move selected files?" : "Copy selected files?", operations: operations))
    }

    private func moveSelected() {
        let destinationDirectory = moveDestination.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !destinationDirectory.isEmpty, !destinationDirectory.contains("\n"), !destinationDirectory.contains("\r") else {
            model.notice = "Enter one remote destination directory."
            return
        }
        let operations = selectedEntries.compactMap { entry -> SFTPBatchOperation? in
            let destination = SFTPListingParser.remotePath(destinationDirectory, appending: entry.name)
            guard destination != entry.path else { return nil }
            return SFTPBatchOperation(operation: "rename", fields: [entry.path, destination])
        }
        guard !operations.isEmpty else {
            model.notice = "Choose a different destination directory."
            return
        }
        showingMove = false
        confirm(.batch(title: "Move selected items?", operations: operations))
    }

    private func deleteSelected() {
        let operations = selectedEntries.map {
            SFTPBatchOperation(operation: $0.isDirectory ? "rmdir" : "delete", fields: [$0.path])
        }
        guard !operations.isEmpty else { return }
        confirm(.batch(title: "Delete \(operations.count) selected item(s)?", operations: operations))
    }

    private func preview(_ entry: SFTPEntryModel) {
        guard let host, !entry.isDirectory else { return }
        guard previewTask == nil else {
            model.notice = "Wait for the current preview to finish or cancel it first."
            return
        }
        guard transferWorker == nil else {
            model.notice = "Wait for queued transfers to finish before previewing."
            return
        }
        if let size = entry.size, size > Int64(FileTextPreviewDecoder.maximumBytes) {
            previewState = .unavailable(
                name: entry.name,
                message: "Text preview is limited to 1 MiB. Download or use Quick Look instead."
            )
            showingPreview = true
            return
        }
        let safeName = entry.name.replacingOccurrences(of: "/", with: "_")
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "AegizPreview", directoryHint: .isDirectory)
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: directory.path
            )
        } catch {
            model.notice = error.localizedDescription
            return
        }
        let local = directory.appending(path: "\(UUID().uuidString)-\(safeName)")
        let requestID = UUID()
        previewRequestID = requestID
        previewState = .loading(name: entry.name)
        showingPreview = true
        previewTask = Task { @MainActor in
            defer {
                try? FileManager.default.removeItem(at: local)
                if previewRequestID == requestID {
                    previewTask = nil
                    previewRequestID = nil
                }
            }
            let result = await model.runSFTPOperation(
                host: host,
                operation: "download",
                fields: [entry.path, local.path],
                confirmedMutation: true
            )
            guard !Task.isCancelled, previewRequestID == requestID else { return }
            guard let result else {
                previewState = .unavailable(
                    name: entry.name,
                    message: "This preview was replaced by another operation. Try Preview again."
                )
                return
            }
            guard result.success == true else {
                previewState = .unavailable(
                    name: entry.name,
                    message: "The SFTP download did not complete. Review the Operations result and retry."
                )
                return
            }
            do {
                try FileManager.default.setAttributes(
                    [.posixPermissions: 0o600],
                    ofItemAtPath: local.path
                )
                let attributes = try FileManager.default.attributesOfItem(atPath: local.path)
                let size = attributes[.size] as? Int64 ?? 0
                guard size <= Int64(FileTextPreviewDecoder.maximumBytes) else {
                    previewState = .unavailable(
                        name: entry.name,
                        message: "Text preview is limited to 1 MiB. Download or use Quick Look instead."
                    )
                    return
                }
                if size == 0, entry.size.map({ $0 > 0 }) == true {
                    previewState = .unavailable(
                        name: entry.name,
                        message: "SFTP reported success but produced an empty local file. Refresh the directory and retry."
                    )
                    return
                }
                let data = try Data(contentsOf: local, options: .mappedIfSafe)
                let document = try FileTextPreviewDecoder.decode(data)
                if document.text.isEmpty {
                    previewState = .empty(name: entry.name)
                } else {
                    previewState = .text(name: entry.name, document: document)
                }
            } catch FileTextPreviewError.binary {
                previewState = .unavailable(
                    name: entry.name,
                    message: "This appears to be a binary file. Use Quick Look or Download instead."
                )
            } catch FileTextPreviewError.tooLarge {
                previewState = .unavailable(
                    name: entry.name,
                    message: "Text preview is limited to 1 MiB. Download or use Quick Look instead."
                )
            } catch {
                previewState = .unavailable(
                    name: entry.name,
                    message: "Aegiz could not decode this file safely. Download or use Quick Look instead."
                )
            }
        }
    }

    private func cancelPreview() {
        previewTask?.cancel()
        previewTask = nil
        previewRequestID = nil
        showingPreview = false
        Task { await model.cancelToolOperation() }
    }

    private func quickLook(_ entry: SFTPEntryModel) {
        guard let host, !entry.isDirectory else { return }
        guard transferWorker == nil else {
            model.notice = "Wait for queued transfers to finish before opening Quick Look."
            return
        }
        if let size = entry.size, size > 52_428_800 {
            model.notice = "Quick Look is limited to 50 MiB. Download this file instead."
            return
        }
        let safeName = entry.name.replacingOccurrences(of: "/", with: "_")
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "AegizQuickLook", directoryHint: .isDirectory)
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        } catch {
            model.notice = error.localizedDescription
            return
        }
        let local = directory.appending(path: "\(UUID().uuidString)-\(safeName)")
        Task {
            let result = await model.runSFTPOperation(
                host: host,
                operation: "download",
                fields: [entry.path, local.path],
                confirmedMutation: true
            )
            guard result?.success == true else {
                try? FileManager.default.removeItem(at: local)
                return
            }
            QuickLookCoordinator.shared.present(url: local)
        }
    }

    private func confirm(
        _ mutation: PendingSFTPMutation,
        preservingConflictCount: Bool = false
    ) {
        if !preservingConflictCount {
            pendingConflictCount = 0
        }
        pendingMutation = mutation
        showingMutationConfirmation = true
    }

    private func executePendingMutation() {
        guard let mutation = pendingMutation else { return }
        pendingMutation = nil
        pendingConflictCount = 0
        switch mutation {
        case .uploads(let items):
            for item in items {
                startTransfer(
                    title: "Upload \((item.local as NSString).lastPathComponent)",
                    route: "\(item.local) → \(host?.alias ?? "host"):\(item.remote)",
                    operation: "upload",
                    fields: [item.local, item.remote]
                )
            }
        case .delete(let remote, let directory):
            runMutation(operation: directory ? "rmdir" : "delete", fields: [remote])
        case .batch(_, let operations):
            runBatchMutation(operations)
        case .rename(let source, let destination):
            runMutation(operation: "rename", fields: [source, destination])
        case .mkdir(let remote):
            runMutation(operation: "mkdir", fields: [remote])
        case .chmod(let mode, let remote):
            runMutation(operation: "chmod", fields: [mode, remote])
        }
    }

    private func runMutation(operation: String, fields: [String]) {
        guard let host else { return }
        Task {
            let result = await model.runSFTPOperation(
                host: host,
                operation: operation,
                fields: fields,
                confirmedMutation: true
            )
            if result?.success == true {
                refreshListing()
            }
        }
    }

    private func runBatchMutation(_ operations: [SFTPBatchOperation]) {
        guard let host else { return }
        Task {
            var failures = 0
            for item in operations {
                let result = await model.runSFTPOperation(
                    host: host,
                    operation: item.operation,
                    fields: item.fields,
                    confirmedMutation: true
                )
                if result?.success != true { failures += 1 }
            }
            if clipboardIsCut, failures == 0 {
                remoteClipboard = []
                clipboardIsCut = false
            }
            if failures > 0 {
                model.notice = "\(failures) file operation(s) failed. Review Operations, then refresh the directory."
            }
            refreshListing()
        }
    }

    private func startTransfer(
        title: String,
        route: String,
        operation: String,
        fields: [String]
    ) {
        guard let host else { return }
        let record = FileTransferRecord(
            title: title,
            route: route,
            host: host,
            operation: operation,
            fields: fields
        )
        transfers.append(record)
        startTransferWorkerIfNeeded()
    }

    private func startTransferWorkerIfNeeded() {
        guard transferWorker == nil else { return }
        transferWorker = Task { @MainActor in
            while !Task.isCancelled,
                  let index = transfers.firstIndex(where: { $0.status == .queued }) {
                let id = transfers[index].id
                transfers[index].status = .running
                transfers[index].progress = 1
                transfers[index].attempts += 1
                let transfer = transfers[index]
                let result = await model.runSFTPOperation(
                    host: transfer.host,
                    operation: transfer.operation,
                    fields: transfer.fields,
                    confirmedMutation: true
                ) { event in
                    guard let current = transfers.firstIndex(where: { $0.id == id }),
                          transfers[current].status == .running
                    else {
                        return
                    }
                    transfers[current].progress = event.progress
                }
                guard let current = transfers.firstIndex(where: { $0.id == id }) else {
                    continue
                }
                if result?.phase == "cancelled" {
                    transfers[current].status = .cancelled
                    transfers[current].success = false
                } else if result?.success == true {
                    transfers[current].status = .completed
                    transfers[current].progress = 100
                    transfers[current].success = true
                    if transfer.operation == "upload" {
                        refreshListing()
                    }
                } else {
                    transfers[current].status = .failed
                    transfers[current].success = false
                }
            }
            transferWorker = nil
        }
    }

    private func cancelTransfer(_ id: UUID) {
        guard let index = transfers.firstIndex(where: { $0.id == id }) else {
            return
        }
        if transfers[index].status == .queued {
            transfers[index].status = .cancelled
            transfers[index].success = false
        } else if transfers[index].status == .running {
            Task { await model.cancelToolOperation() }
        }
    }

    private func retryTransfer(_ id: UUID) {
        guard let index = transfers.firstIndex(where: { $0.id == id }),
              [.failed, .cancelled].contains(transfers[index].status)
        else {
            return
        }
        transfers[index].status = .queued
        transfers[index].progress = 0
        transfers[index].success = nil
        startTransferWorkerIfNeeded()
    }

    private static func isSafeLeafName(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty
            && trimmed != "."
            && trimmed != ".."
            && trimmed.utf8.count <= 255
            && !trimmed.contains("/")
            && !trimmed.contains("\\")
            && !trimmed.contains("\n")
            && !trimmed.contains("\r")
    }

    private static func isOctalMode(_ value: String) -> Bool {
        (value.count == 3 || value.count == 4)
            && value.allSatisfy { ("0"..."7").contains(String($0)) }
    }

    private static func octalMode(from permissions: String) -> String? {
        let bits = Array(permissions.dropFirst().prefix(9))
        guard bits.count == 9 else { return nil }
        return stride(from: 0, to: 9, by: 3).map { index in
            let value = (bits[index] == "-" ? 0 : 4)
                + (bits[index + 1] == "-" ? 0 : 2)
                + (bits[index + 2] == "-" ? 0 : 1)
            return String(value)
        }.joined()
    }

    private static func availableUploadName(_ original: String, reserved: Set<String>) -> String {
        let value = original as NSString
        let stem = value.deletingPathExtension
        let pathExtension = value.pathExtension
        for suffix in 2...9_999 {
            let leaf = pathExtension.isEmpty
                ? "\(stem) (\(suffix))"
                : "\(stem) (\(suffix)).\(pathExtension)"
            if !reserved.contains(leaf) {
                return leaf
            }
        }
        return "\(UUID().uuidString)-\(original)"
    }
}

private struct FilePreviewSheet: View {
    let state: FilePreviewState
    let close: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) {
                    identity
                    Spacer(minLength: 12)
                    closeButton
                }
                VStack(alignment: .leading, spacing: 8) {
                    identity
                    closeButton.frame(maxWidth: .infinity, alignment: .trailing)
                }
            }
            .padding(14)
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 520, idealWidth: 760, minHeight: 360, idealHeight: 560)
    }

    private var identity: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(state.name)
                .font(.system(size: 15, weight: .semibold))
                .lineLimit(1)
                .accessibilityHeading(.h1)
            if let detail {
                Text(detail)
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
    }

    private var closeButton: some View {
        Button(isLoading ? "Cancel" : "Done", role: isLoading ? .cancel : nil, action: close)
            .keyboardShortcut(.cancelAction)
    }

    @ViewBuilder
    private var content: some View {
        switch state {
        case .idle:
            ContentUnavailableView("No preview", systemImage: "doc.text.magnifyingglass")
        case .loading(let name):
            VStack(spacing: 12) {
                ProgressView()
                    .controlSize(.small)
                Text("Downloading \(name) through SFTP…")
                    .font(.system(size: 12, weight: .medium))
                Text("The remote file is kept only in a private temporary directory during preview.")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(24)
        case .empty:
            ContentUnavailableView {
                Label("This file is empty", systemImage: "doc")
            } description: {
                Text("SFTP returned a zero-byte file. Nothing is hidden or waiting to render.")
            }
        case .unavailable(_, let message):
            ContentUnavailableView {
                Label("Preview unavailable", systemImage: "doc.badge.ellipsis")
            } description: {
                Text(message)
            }
        case .text(_, let document):
            VStack(spacing: 0) {
                if document.containsOnlyWhitespace {
                    Label(
                        "This file contains only whitespace characters.",
                        systemImage: "character.cursor.ibeam"
                    )
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 14)
                    .frame(maxWidth: .infinity, minHeight: 34, alignment: .leading)
                    Divider()
                }
                FilePreviewTextView(text: document.text)
            }
        }
    }

    private var isLoading: Bool {
        if case .loading = state { return true }
        return false
    }

    private var detail: String? {
        switch state {
        case .text(_, let document):
            let bytes = ByteCountFormatter.string(
                fromByteCount: Int64(document.byteCount),
                countStyle: .file
            )
            return "\(document.encoding) · \(bytes)" + (document.usedLossyDecoding ? " · replacements shown" : "")
        case .loading: return "Reading a private temporary copy"
        case .empty: return "0 bytes"
        case .unavailable: return "No ambiguous blank preview"
        case .idle: return nil
        }
    }
}

private struct FilePreviewTextView: NSViewRepresentable {
    let text: String

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false

        let textView = NSTextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.importsGraphics = false
        textView.drawsBackground = false
        textView.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        textView.textContainerInset = NSSize(width: 14, height: 14)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(
            width: 0,
            height: CGFloat.greatestFiniteMagnitude
        )
        scrollView.documentView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView,
              textView.string != text
        else {
            return
        }
        textView.string = text
        textView.scrollToBeginningOfDocument(nil)
    }
}

private struct SFTPConnectionSheet: View {
    let host: HostModel?
    let secrets: [SecretMetadataModel]
    @Binding var selectedSecretID: String
    let createSecret: () -> Void
    @Environment(\.dismiss) private var dismiss

    private var passwordSecrets: [SecretMetadataModel] {
        secrets.filter { $0.kind == .sshPassword || $0.kind == .password }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Label("SFTP authentication", systemImage: "key.fill")
                    .font(.headline)
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            Text("\(host?.alias ?? "This host") uses your normal OpenSSH config, keys, and agent unless a Keychain password is selected below.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Form {
                Picker("Keychain SSH password", selection: $selectedSecretID) {
                    Text("Use OpenSSH config / agent").tag("")
                    ForEach(passwordSecrets) { secret in
                        Text(secret.name).tag(secret.id)
                    }
                }
                Text("Aegiz only stores the Keychain item reference. The password is supplied to OpenSSH only while this SFTP operation runs.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack {
                Button("Create Keychain Password…") { createSecret() }
                Spacer()
                if !selectedSecretID.isEmpty {
                    Label("Password ready", systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.green)
                }
            }
        }
        .padding(24)
        .frame(width: 500)
    }
}

private struct SFTPNewFolderSheet: View {
    @Binding var name: String
    let create: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("New remote folder")
                .font(.headline)
            TextField("Folder name", text: $name)
                .textFieldStyle(.roundedBorder)
                .onSubmit { create() }
            HStack {
                Button("Cancel") { dismiss() }
                Spacer()
                Button("Create", action: create)
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 360)
    }
}

private struct SFTPMoveSheet: View {
    @Binding var destination: String
    let itemCount: Int
    let move: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Move \(itemCount) remote item\(itemCount == 1 ? "" : "s")")
                .font(.headline)
            Text("Destination directory")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            TextField("/srv/app/releases", text: $destination)
                .textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .monospaced))
                .onSubmit { move() }
            HStack {
                Button("Cancel") { dismiss() }
                Spacer()
                Button("Move", action: move)
                    .keyboardShortcut(.defaultAction)
                    .disabled(destination.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 440)
    }
}

private struct SFTPEntryRow: View {
    let entry: SFTPEntryModel

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: entry.isDirectory ? "folder.fill" : entry.isSymbolicLink ? "link" : "doc")
                .foregroundStyle(entry.isDirectory ? AegizTheme.accent : .secondary)
                .frame(width: 18)
            Text(entry.name)
                .font(.system(size: 11, weight: .medium))
                .lineLimit(1)
            Spacer()
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) {
                    Text(entry.permissions)
                    Text(entry.owner)
                        .frame(width: 70, alignment: .leading)
                    if let size = entry.size {
                        Text(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
                            .frame(width: 68, alignment: .trailing)
                    }
                }
                .font(.system(size: 9).monospaced())
                .foregroundStyle(.secondary)
                if let size = entry.size {
                    Text(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
                        .font(.system(size: 9).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 3)
    }
}

@MainActor
private final class QuickLookCoordinator: NSObject,
    @preconcurrency QLPreviewPanelDataSource,
    QLPreviewPanelDelegate
{
    static let shared = QuickLookCoordinator()
    private var previewURL: URL?

    func present(url: URL) {
        cleanup()
        previewURL = url
        guard let panel = QLPreviewPanel.shared() else {
            NSWorkspace.shared.open(url)
            return
        }
        panel.dataSource = self
        panel.delegate = self
        panel.reloadData()
        panel.makeKeyAndOrderFront(nil)
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        previewURL == nil ? 0 : 1
    }

    func previewPanel(
        _ panel: QLPreviewPanel!,
        previewItemAt index: Int
    ) -> (any QLPreviewItem)! {
        previewURL as NSURL?
    }

    func previewPanelWillClose(_ panel: QLPreviewPanel!) {
        cleanup()
    }

    private func cleanup() {
        if let previewURL {
            try? FileManager.default.removeItem(at: previewURL)
        }
        previewURL = nil
    }
}
