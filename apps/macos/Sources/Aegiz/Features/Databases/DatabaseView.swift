import AppKit
import SwiftUI

struct DatabaseView: View {
    @Bindable var model: AppModel
    @State private var selectedProfileID: String?
    @State private var sql = "SELECT current_timestamp;"
    @State private var pendingSQL = ""
    @State private var showingMutationConfirmation = false
    @State private var pendingDeletion: DatabaseProfileModel?
    @State private var showingDeleteConfirmation = false
    @State private var sessionHistory: [String] = []
    @State private var rememberSessionHistory = false
    @State private var redisKey = ""
    @State private var showRawResult = false

    private var selectedProfile: DatabaseProfileModel? {
        model.databaseProfiles.first { $0.id == selectedProfileID }
            ?? model.databaseProfiles.first
    }

    private var operation: ToolOperationModel? {
        guard model.toolOperation?.adapterID == "database" else { return nil }
        return model.toolOperation
    }

    var body: some View {
        return VStack(spacing: 0) {
            header
            Divider()
            if model.databaseProfiles.isEmpty {
                AegizWorkspaceStateView(
                    "No database profiles",
                    message: "Create a local profile and reference a password from the Aegiz Keychain vault.",
                    symbol: "cylinder"
                ) {
                    Button("New Profile") { model.beginCreatingDatabaseProfile() }
                        .buttonStyle(.borderedProminent)
                }
            } else {
                HSplitView {
                    profileList
                        .frame(minWidth: 250, idealWidth: 300)
                    queryWorkspace
                        .frame(minWidth: 520, idealWidth: 760)
                }
            }
        }
        .background(AegizTheme.raised)
        .navigationTitle("Databases")
        .onAppear {
            if selectedProfileID == nil {
                selectedProfileID = model.databaseProfiles.first?.id
            }
        }
        .confirmationDialog(
            "Run a database mutation?",
            isPresented: $showingMutationConfirmation,
            titleVisibility: .visible
        ) {
            Button("Run on \(selectedProfile?.label ?? "database")", role: .destructive) {
                execute(pendingSQL, confirmedMutation: true)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                "Target: \(selectedProfile?.hostname ?? "unknown"):\(selectedProfile?.port ?? 0)/\(selectedProfile?.databaseName ?? ""). The SQL executes inside this database."
            )
        }
        .confirmationDialog(
            "Delete this database profile?",
            isPresented: $showingDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete “\(pendingDeletion?.label ?? "Profile")”", role: .destructive) {
                guard let pendingDeletion else { return }
                Task { await model.deleteDatabaseProfile(pendingDeletion) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The referenced Keychain secret is intentionally left untouched.")
        }
    }

    private var header: some View {
        AegizPageHeader(
            "Database Studio",
            subtitle: "Native PostgreSQL, MySQL, and Redis with Keychain secret references",
            symbol: "cylinder.fill"
        ) {
            Button {
                model.beginCreatingDatabaseProfile()
            } label: {
                Label("New Profile", systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
        }
    }

    private var profileList: some View {
        List(model.databaseProfiles, selection: $selectedProfileID) { profile in
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Image(systemName: "cylinder")
                        .foregroundStyle(AegizTheme.accent)
                    Text(profile.label)
                        .font(.system(size: 12, weight: .semibold))
                    Spacer()
                    if profile.readOnly {
                        Text("RO")
                            .font(.system(size: 8, weight: .bold).monospaced())
                            .foregroundStyle(.green)
                    }
                }
                Text("\(profile.username)@\(profile.hostname):\(profile.port)/\(profile.databaseName)")
                    .font(.system(size: 9).monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .padding(.vertical, 4)
            .tag(profile.id)
            .aegizInteractiveRow(isSelected: selectedProfileID == profile.id)
            .contextMenu {
                Button("Edit") { model.beginEditingDatabaseProfile(profile) }
                Button("Delete", role: .destructive) {
                    pendingDeletion = profile
                    showingDeleteConfirmation = true
                }
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
    }

    @ViewBuilder
    private var queryWorkspace: some View {
        if let profile = selectedProfile {
            VStack(spacing: 0) {
                profileBar(profile)
                Divider()
                queryEditor(profile)
                Divider()
                resultConsole
            }
        }
    }

    private func profileBar(_ profile: DatabaseProfileModel) -> some View {
        HStack(spacing: 8) {
            Label(profile.engine.rawValue, systemImage: "network")
                .font(.system(size: 10, weight: .semibold))
            Text("•")
                .foregroundStyle(.tertiary)
            Text("\(profile.hostname):\(profile.port)")
                .font(.system(size: 10).monospaced())
                .foregroundStyle(.secondary)
            if !profile.tunnelID.isEmpty {
                Label(
                    profile.autoStartTunnel ? "Ephemeral tunnel" : "Existing tunnel",
                    systemImage: "point.3.connected.trianglepath.dotted"
                )
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            } else if profile.engine == .redis {
                Label("Direct TCP", systemImage: "exclamationmark.shield")
                    .font(.system(size: 10))
                    .foregroundStyle(.orange)
            }
            Spacer()
            Label(
                profile.engine == .redis ? "Isolated command" : "Auto-commit per run",
                systemImage: "arrow.triangle.2.circlepath"
            )
            .font(.system(size: 9))
            .foregroundStyle(.secondary)
            Label(
                profile.readOnly ? "Read-only enforced" : "Mutations guarded",
                systemImage: profile.readOnly ? "lock.fill" : "exclamationmark.shield.fill"
            )
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(profile.readOnly ? .green : .orange)
            Button("Edit") { model.beginEditingDatabaseProfile(profile) }
        }
        .padding(.horizontal, 12)
        .frame(height: 36)
        .background(AegizTheme.canvas.opacity(0.55))
    }

    private func queryEditor(_ profile: DatabaseProfileModel) -> some View {
        VStack(spacing: 8) {
            TextEditor(text: $sql)
                .font(.system(size: 12).monospaced())
                .scrollContentBackground(.hidden)
                .padding(8)
                .background(AegizTheme.canvas, in: RoundedRectangle(cornerRadius: 6))
                .frame(minHeight: 100, idealHeight: 150)
            HStack(spacing: 8) {
                Button(profile.engine == .redis ? "Scan Keys" : "Tables") {
                    sql = switch profile.engine {
                    case .postgres:
                        "SELECT table_schema, table_name FROM information_schema.tables WHERE table_schema NOT IN ('pg_catalog', 'information_schema') ORDER BY 1, 2;"
                    case .mysql:
                        "SHOW TABLES;"
                    case .redis:
                        "SCAN 0 COUNT 200"
                    }
                }
                Button("Version") {
                    sql = profile.engine == .redis ? "INFO server" : "SELECT version();"
                }
                Toggle("Session-only history", isOn: $rememberSessionHistory)
                    .toggleStyle(.checkbox)
                    .font(.system(size: 10))
                Spacer()
                if operation?.isRunning == true {
                    Button("Cancel", role: .destructive) {
                        Task { await model.cancelToolOperation() }
                    }
                } else {
                    Button {
                        prepareRun(profile)
                    } label: {
                        Label("Run Query", systemImage: "play.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.return, modifiers: .command)
                }
            }
            if profile.engine == .redis {
                HStack(spacing: 8) {
                    TextField("Redis key", text: $redisKey)
                        .textFieldStyle(.roundedBorder)
                    ForEach(["GET", "TYPE", "TTL"], id: \.self) { command in
                        Button(command) {
                            guard let encoded = RedisCommandEscaping.quoted(redisKey) else {
                                model.notice = "Enter a Redis key without control characters."
                                return
                            }
                            sql = "\(command) \(encoded)"
                            prepareRun(profile)
                        }
                    }
                    Button("DEL", role: .destructive) {
                        guard let encoded = RedisCommandEscaping.quoted(redisKey) else {
                            model.notice = "Enter a Redis key without control characters."
                            return
                        }
                        sql = "DEL \(encoded)"
                        prepareRun(profile)
                    }
                }
            }
            if rememberSessionHistory, !sessionHistory.isEmpty {
                ScrollView(.horizontal) {
                    HStack {
                        ForEach(Array(sessionHistory.enumerated()), id: \.offset) { _, query in
                            Button(DatabaseQueryHistory.redactedSummary(query)) { sql = query }
                                .font(.system(size: 9).monospaced())
                        }
                    }
                }
                .scrollIndicators(.hidden)
            }
        }
        .padding(12)
    }

    private var resultConsole: some View {
        let output = operation?.output ?? ""
        let table = DatabaseTabularResult.parse(
            output,
            engine: selectedProfile?.engine ?? .postgres
        )
        return VStack(spacing: 0) {
            HStack {
                Text(table == nil ? "Query output" : "Result table")
                    .font(.system(size: 11, weight: .semibold))
                if let table {
                    Text("\(table.rows.count) rows · \(table.columns.count) columns")
                        .font(.system(size: 9).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                if let operation {
                    StatusPill(
                        label: operation.phase.capitalized,
                        success: operation.success,
                        running: operation.isRunning
                    )
                }
                Spacer()
                if table != nil {
                    Picker("Result format", selection: $showRawResult) {
                        Text("Table").tag(false)
                        Text("Raw").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 112)
                }
                Button("Export…") { exportResult() }
                    .disabled(operation?.output.isEmpty != false)
            }
            .padding(.horizontal, 12)
            .frame(height: 34)
            if let table, !showRawResult {
                DatabaseResponsiveTable(result: table)
            } else {
                ScrollView([.vertical, .horizontal]) {
                    Text(
                        output.isEmpty
                            ? "Run a query. Results are capped at 1,000 rows and are not persisted by Aegiz."
                            : output
                    )
                    .font(.system(size: 11).monospaced())
                    .foregroundStyle(output.isEmpty ? .secondary : .primary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding(12)
                }
                .background(Color(nsColor: .textBackgroundColor))
            }
        }
    }

    private func prepareRun(_ profile: DatabaseProfileModel) {
        let query = sql.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }
        let readOnly = DatabaseQueryRisk.isReadOnly(query, engine: profile.engine)
        if profile.readOnly, !readOnly {
            model.notice = "This profile enforces read-only queries."
            return
        }
        if !readOnly {
            pendingSQL = query
            showingMutationConfirmation = true
        } else {
            execute(query, confirmedMutation: false)
        }
    }

    private func execute(_ query: String, confirmedMutation: Bool) {
        guard let profile = selectedProfile else { return }
        if rememberSessionHistory {
            sessionHistory.removeAll { $0 == query }
            sessionHistory.insert(query, at: 0)
            sessionHistory = Array(sessionHistory.prefix(20))
        }
        Task {
            await model.runDatabaseQuery(
                profile: profile,
                sql: query,
                confirmedMutation: confirmedMutation
            )
        }
    }

    private func exportResult() {
        guard let output = operation?.output, !output.isEmpty else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(selectedProfile?.label ?? "query")-result.tsv"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try Data(output.utf8).write(to: url, options: .atomic)
            model.notice = "Query result exported to \(url.lastPathComponent)."
        } catch {
            model.notice = error.localizedDescription
        }
    }
}

private struct DatabaseTabularResult: Equatable {
    let columns: [String]
    let rows: [[String]]

    static func parse(
        _ output: String,
        engine: DatabaseEngineModel
    ) -> DatabaseTabularResult? {
        let lines = output
            .split(whereSeparator: \.isNewline)
            .map(String.init)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("›") }
        guard !lines.isEmpty else { return nil }
        let values = lines.map { $0.components(separatedBy: "\t") }
        if engine == .redis {
            let width = values.map(\.count).max() ?? 1
            let columns = width == 1
                ? ["Value"]
                : (0..<width).map { "Value \($0 + 1)" }
            return DatabaseTabularResult(
                columns: columns,
                rows: values.map { normalized($0, count: width) }
            )
        }
        guard values.count >= 2 else { return nil }
        let columns = values[0]
        guard !columns.isEmpty else { return nil }
        return DatabaseTabularResult(
            columns: columns,
            rows: values.dropFirst().map { normalized($0, count: columns.count) }
        )
    }

    private static func normalized(_ values: [String], count: Int) -> [String] {
        if values.count == count { return values }
        if values.count > count { return Array(values.prefix(count)) }
        return values + Array(repeating: "", count: count - values.count)
    }
}

private struct DatabaseResponsiveTable: View {
    let result: DatabaseTabularResult

    var body: some View {
        GeometryReader { geometry in
            let columnWidth = max(
                132,
                geometry.size.width / CGFloat(max(result.columns.count, 1))
            )
            ScrollView([.horizontal, .vertical]) {
                LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
                    Section {
                        ForEach(Array(result.rows.enumerated()), id: \.offset) { index, row in
                            tableRow(row, width: columnWidth, header: false)
                                .background(
                                    index.isMultiple(of: 2)
                                        ? Color.clear
                                        : AegizTheme.canvas.opacity(0.42)
                                )
                        }
                    } header: {
                        tableRow(result.columns, width: columnWidth, header: true)
                            .background(AegizTheme.raised)
                    }
                }
                .frame(
                    minWidth: max(
                        geometry.size.width,
                        columnWidth * CGFloat(result.columns.count)
                    ),
                    alignment: .topLeading
                )
            }
            .background(Color(nsColor: .textBackgroundColor))
        }
    }

    private func tableRow(
        _ values: [String],
        width: CGFloat,
        header: Bool
    ) -> some View {
        HStack(spacing: 0) {
            ForEach(Array(values.enumerated()), id: \.offset) { _, value in
                Text(value)
                    .font(
                        .system(
                            size: header ? 10 : 11,
                            weight: header ? .semibold : .regular
                        )
                        .monospaced()
                    )
                    .foregroundStyle(value == "NULL" ? .secondary : .primary)
                    .lineLimit(3)
                    .textSelection(.enabled)
                    .frame(
                        maxWidth: .infinity,
                        minHeight: header ? 30 : 32,
                        alignment: .leading
                    )
                    .padding(.horizontal, 9)
                    .frame(width: width, alignment: .leading)
                    .overlay(alignment: .trailing) {
                        Rectangle()
                            .fill(AegizTheme.subtleBorder)
                            .frame(width: 1)
                    }
            }
        }
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(AegizTheme.subtleBorder)
                .frame(height: 1)
        }
    }
}

private enum DatabaseAuthenticationMode: String, CaseIterable, Identifiable {
    case none = "No password / external auth"
    case existing = "Existing Keychain secret"
    case password = "Password"

    var id: String { rawValue }
}

struct DatabaseProfileEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var model: AppModel
    @State private var draft = DatabaseProfileDraft()
    @State private var authentication = DatabaseAuthenticationMode.none
    @State private var password = ""
    @State private var requireUserPresence = true
    @State private var saving = false

    private var eligibleSecrets: [SecretMetadataModel] {
        model.secrets.filter { [.database, .password, .generic].contains($0.kind) }
    }

    var body: some View {
        VStack(spacing: 0) {
            AegizSheetHeader(
                model.editingDatabaseProfile == nil
                    ? "New Database Profile" : "Edit Database Profile",
                subtitle: "Connection metadata goes to local SQLite; passwords stay in Keychain."
            )
            Divider()
            Form {
                TextField("Label", text: $draft.label)
                Picker("Engine", selection: $draft.engine) {
                    ForEach(DatabaseEngineModel.allCases) { engine in
                        Text(engine.rawValue).tag(engine)
                    }
                }
                .onChange(of: draft.engine) { _, engine in
                    draft.port = engine.defaultPort
                    if engine == .redis, draft.databaseName.isEmpty {
                        draft.databaseName = "0"
                    }
                }
                TextField("Hostname", text: $draft.hostname)
                TextField("Port", text: $draft.port)
                TextField(
                    draft.engine == .redis ? "Redis DB index" : "Database",
                    text: $draft.databaseName
                )
                TextField(
                    draft.engine == .redis ? "ACL username (optional)" : "Username",
                    text: $draft.username
                )
                Picker("Authentication", selection: $authentication) {
                    ForEach(DatabaseAuthenticationMode.allCases) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .onChange(of: authentication) { _, mode in
                    if mode == .none || mode == .password {
                        draft.secretReference = ""
                    }
                }
                if authentication == .existing {
                    Picker("Keychain secret", selection: $draft.secretReference) {
                        Text("Select a secret").tag("")
                        ForEach(eligibleSecrets) { secret in
                            Label(secret.name, systemImage: secret.kind.symbol).tag(secret.id)
                        }
                    }
                    if eligibleSecrets.isEmpty {
                        Text("No compatible Keychain secrets. Choose Password to save one now.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else if authentication == .password {
                    SecureField("Password", text: $password)
                        .textContentType(.password)
                    Toggle(
                        "Require \(model.vaultStatus?.authenticationLabel ?? "user presence") when connecting",
                        isOn: $requireUserPresence
                    )
                    .disabled(model.vaultStatus?.userPresenceAvailable != true)
                    Text("The password is written directly to the local macOS Keychain. SQLite stores only its reference.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Picker("Managed tunnel route", selection: $draft.tunnelID) {
                    Text("Direct").tag("")
                    ForEach(model.tunnels) { tunnel in
                        Text("\(tunnel.label) · \(model.tunnelRoute(for: tunnel))").tag(tunnel.id)
                    }
                }
                if !draft.tunnelID.isEmpty {
                    Toggle("Start and stop tunnel for each query", isOn: $draft.autoStartTunnel)
                }
                Toggle(
                    draft.engine == .redis
                        ? "Allow read-only Redis commands only"
                        : "Enforce read-only SQL",
                    isOn: $draft.readOnly
                )
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Save Profile") {
                    saving = true
                    Task {
                        var profileDraft = draft
                        if authentication == .none {
                            profileDraft.secretReference = ""
                        }
                        let inlinePassword = authentication == .password ? password : nil
                        if await model.saveDatabaseProfile(
                            profileDraft,
                            password: inlinePassword,
                            requireUserPresence: requireUserPresence
                        ) {
                            password.removeAll(keepingCapacity: false)
                            dismiss()
                        }
                        saving = false
                    }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(
                    saving
                        || draft.label.isEmpty
                        || draft.hostname.isEmpty
                        || draft.databaseName.isEmpty
                        || (draft.username.isEmpty && draft.engine != .redis)
                        || UInt16(draft.port) == nil
                        || (authentication == .existing && draft.secretReference.isEmpty)
                        || (authentication == .password && password.isEmpty)
                )
            }
            .padding(16)
        }
        .aegizAdaptiveSheet(AegizSheetSizingPolicy.databaseEditor)
        .onAppear {
            guard let profile = model.editingDatabaseProfile else { return }
            draft = DatabaseProfileDraft(
                id: profile.id,
                label: profile.label,
                engine: profile.engine,
                hostname: profile.hostname,
                port: String(profile.port),
                databaseName: profile.databaseName,
                username: profile.username,
                secretReference: profile.secretReference,
                tunnelID: profile.tunnelID,
                autoStartTunnel: profile.autoStartTunnel,
                readOnly: profile.readOnly
            )
            authentication = profile.secretReference.isEmpty ? .none : .existing
            if let secret = model.secrets.first(where: { $0.id == profile.secretReference }) {
                requireUserPresence = secret.requiresUserPresence
            }
        }
        .onDisappear { password.removeAll(keepingCapacity: false) }
    }
}
