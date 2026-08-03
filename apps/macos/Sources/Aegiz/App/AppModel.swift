import AppKit
import Foundation
import Observation

@MainActor
@Observable
final class AppModel {
    var selectedSection: AppSection? = .commandCenter
    var selectedHostID: String?
    var searchText = ""
    var hosts: [HostModel] = []
    var tunnels: [TunnelModel] = []
    var capabilities: [ToolCapabilityModel] = []
    var auditEvents: [AuditEventModel] = []
    var toolOperation: ToolOperationModel?
    var secrets: [SecretMetadataModel] = []
    var databaseProfiles: [DatabaseProfileModel] = []
    var vaultStatus: VaultStatusModel?
    var revealedSecretID: String?
    var revealedSecretData = Data()
    var dashboard = DashboardModel()
    var connectionState = CoreConnectionState.connecting
    var notice: String?
    var isBusy = false
    var terminalSessions: [TerminalSessionModel] = []
    var selectedTerminalSessionID: UUID?
    var splitTerminalSessionID: UUID?
    var terminalSplitAxis = TerminalSplitAxis.horizontal
    var showingNewTunnel = false
    var showingCommandPalette = false
    var showingNewSecret = false
    var showingDatabaseProfileEditor = false
    var editingDatabaseProfile: DatabaseProfileModel?
    var editingSecret: SecretMetadataModel?
    var pendingNewSecretKind = SecretKindModel.generic
    var vaultIsLocked = true
    var vaultAutoLockMinutes = UserDefaults.standard.integer(forKey: "vaultAutoLockMinutes")
    var terminalSettingsByHost: [String: TerminalHostSettings] = [:]
    var hostOrganizationByID: [String: HostOrganizationMetadata] = [:]
    var tunnelSecretReferenceByID: [String: String] = [:]
    var selectedTunnelID: String?
    var tunnelOperationID: String?
    var hostInventoryFilter = HostInventoryFilter()

    private let dependencies: AppDependencies
    var core: CoreClient { dependencies.core }
    private var vault: KeychainVault { dependencies.vault }
    @ObservationIgnored private var revealExpiryTimer: Timer?
    @ObservationIgnored private var vaultLockTimer: Timer?
    @ObservationIgnored private var terminalControllers: [UUID: TerminalSessionController] = [:]
    @ObservationIgnored private var toolOperationGeneration = UUID()

    init(dependencies: AppDependencies = .live()) {
        self.dependencies = dependencies
        if vaultAutoLockMinutes == 0 {
            vaultAutoLockMinutes = 5
        }
        restoreTerminalSettings()
        restoreTerminalSessions()
        restoreHostOrganization()
        restoreTunnelSecretReferences()
    }

    var selectedHost: HostModel? {
        hosts.first { $0.id == selectedHostID }
    }

    var visibleHosts: [HostModel] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return hosts.filter { host in
            let metadata = hostOrganization(for: host.id)
            let environment = metadata.environment.lowercased()
            let smartMatch = switch hostInventoryFilter.smart {
            case .all: true
            case .favorites: metadata.favorite
            case .production: ["prod", "production"].contains(environment)
            case .staging: ["stage", "staging", "uat"].contains(environment)
            case .development: ["dev", "development", "local"].contains(environment)
            }
            let scopedMatch =
                (hostInventoryFilter.workspace.isEmpty
                    || metadata.workspace == hostInventoryFilter.workspace)
                && (hostInventoryFilter.company.isEmpty
                    || metadata.company == hostInventoryFilter.company)
                && (hostInventoryFilter.environment.isEmpty
                    || metadata.environment == hostInventoryFilter.environment)
                && (hostInventoryFilter.tag.isEmpty
                    || (host.tags + metadata.tags).contains(hostInventoryFilter.tag))
            let searchable = [
                host.alias,
                host.hostname,
                host.user,
                host.proxyJump,
                host.source,
                metadata.workspace,
                metadata.company,
                metadata.environment,
                (host.tags + metadata.tags).joined(separator: " "),
            ].joined(separator: " ")
            return smartMatch
                && scopedMatch
                && (query.isEmpty || searchable.localizedCaseInsensitiveContains(query))
        }
    }

    var workspaceNames: [String] {
        organizedValues(\.workspace)
    }

    var companyNames: [String] {
        organizedValues(\.company)
    }

    var environmentNames: [String] {
        organizedValues(\.environment)
    }

    var organizationTags: [String] {
        Array(
            Set(
                hosts.flatMap(\.tags)
                    + hostOrganizationByID.values.flatMap(\.tags)
            )
        ).sorted {
            $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
        }
    }

    var selectedTerminalSession: TerminalSessionModel? {
        terminalSessions.first { $0.id == selectedTerminalSessionID }
    }

    var splitTerminalSession: TerminalSessionModel? {
        terminalSessions.first { $0.id == splitTerminalSessionID }
    }

    var sessionHost: HostModel? {
        guard let session = selectedTerminalSession else { return nil }
        return hosts.first { $0.id == session.hostID }
    }

    var selectedTunnel: TunnelModel? {
        tunnels.first { $0.id == selectedTunnelID }
    }

    var tunnelPortConflictIDs: Set<String> {
        let grouped = Dictionary(grouping: tunnels.compactMap { tunnel in
            tunnel.localEndpointKey.map { ($0, tunnel) }
        }, by: \.0)
        return Set(
            grouped.values.filter { $0.count > 1 }.flatMap { values in
                values.map { $0.1.id }
            }
        )
    }

    func tunnelRoute(for tunnel: TunnelModel) -> String {
        let sshHostAlias = hosts.first { $0.id == tunnel.hostID }?.alias ?? "unknown host"
        return tunnel.route(via: sshHostAlias)
    }

    func tunnelSecretReference(for tunnelID: String) -> String {
        tunnelSecretReferenceByID[tunnelID] ?? ""
    }

    func setTunnelSecretReference(_ reference: String, for tunnelID: String) {
        if reference.isEmpty {
            tunnelSecretReferenceByID[tunnelID] = nil
        } else {
            tunnelSecretReferenceByID[tunnelID] = reference
        }
        persistTunnelSecretReferences()
        notice = reference.isEmpty
            ? "Tunnel will use your OpenSSH config, keys, and agent."
            : "SSH password reference saved locally; its value remains in macOS Keychain."
    }

    func openSession(_ host: HostModel) {
        let session = TerminalSessionModel(host: host)
        terminalSessions.append(session)
        selectedTerminalSessionID = session.id
        selectedSection = .sessions
        persistTerminalSessions()
    }

    func openLocalTerminal(
        title: String,
        endpoint: String,
        executable: String,
        arguments: [String]
    ) {
        guard TerminalLocalCommand.encoded(
            executable: executable,
            arguments: arguments
        ) != nil else {
            notice = "The local terminal command is outside Aegiz's fixed executable boundary."
            return
        }
        let session = TerminalSessionModel(
            localTitle: title,
            endpoint: endpoint,
            executable: executable,
            arguments: arguments
        )
        terminalSessions.append(session)
        selectedTerminalSessionID = session.id
        selectedSection = .sessions
        persistTerminalSessions()
    }

    func selectTerminalSession(_ session: TerminalSessionModel) {
        selectedTerminalSessionID = session.id
        persistTerminalSessions()
    }

    func duplicateTerminalSession(_ session: TerminalSessionModel) {
        var duplicate = session
        duplicate.id = UUID()
        duplicate.createdAt = Date()
        duplicate.generation = UUID()
        terminalSessions.append(duplicate)
        selectedTerminalSessionID = duplicate.id
        persistTerminalSessions()
    }

    func reconnectTerminalSession(_ session: TerminalSessionModel) {
        guard let index = terminalSessions.firstIndex(where: { $0.id == session.id }) else {
            return
        }
        terminalControllers[session.id] = nil
        terminalSessions[index].generation = UUID()
        persistTerminalSessions()
    }

    func createTerminalSplit(_ session: TerminalSessionModel, axis: TerminalSplitAxis) {
        if splitTerminalSessionID != nil {
            closeTerminalSplit()
        }
        var duplicate = session
        duplicate.id = UUID()
        duplicate.createdAt = Date()
        duplicate.generation = UUID()
        terminalSessions.append(duplicate)
        splitTerminalSessionID = duplicate.id
        terminalSplitAxis = axis
        persistTerminalSessions()
    }

    func closeTerminalSplit() {
        guard let splitID = splitTerminalSessionID else { return }
        terminalControllers[splitID] = nil
        terminalSessions = TerminalSessionLifecycle.removing(splitID, from: terminalSessions)
        splitTerminalSessionID = nil
        persistTerminalSessions()
    }

    func closeTerminalSession(_ session: TerminalSessionModel) {
        terminalControllers[session.id] = nil
        terminalSessions.removeAll { $0.id == session.id }
        if splitTerminalSessionID == session.id {
            splitTerminalSessionID = nil
        }
        if selectedTerminalSessionID == session.id {
            selectedTerminalSessionID = terminalSessions.last?.id
        }
        persistTerminalSessions()
    }

    func terminalController(for session: TerminalSessionModel) -> TerminalSessionController {
        let configuration: TerminalLaunchConfiguration
        if let executable = session.localExecutable {
            configuration = TerminalLaunchConfiguration(
                title: session.hostAlias,
                executable: executable,
                arguments: session.localArguments ?? []
            )
        } else {
            configuration = TerminalLaunchConfiguration(
                hostAlias: session.hostAlias,
                settings: terminalSettings(for: session.hostID)
            )
        }
        if let controller = terminalControllers[session.id],
           controller.configuration == configuration {
            return controller
        }
        let controller = TerminalSessionController(configuration: configuration)
        terminalControllers[session.id] = controller
        return controller
    }

    func terminalSettings(for hostID: String) -> TerminalHostSettings {
        terminalSettingsByHost[hostID] ?? TerminalHostSettings()
    }

    func saveTerminalSettings(
        _ settings: TerminalHostSettings,
        forHostID hostID: String
    ) throws {
        let validated = try settings.validated()
        if validated == TerminalHostSettings() {
            terminalSettingsByHost[hostID] = nil
        } else {
            terminalSettingsByHost[hostID] = validated
        }
        for index in terminalSessions.indices where terminalSessions[index].hostID == hostID {
            terminalControllers[terminalSessions[index].id] = nil
            terminalSessions[index].generation = UUID()
        }
        persistTerminalSettings()
        persistTerminalSessions()
        notice = "Terminal settings saved. Matching sessions were reconnected."
    }

    func hostOrganization(for hostID: String) -> HostOrganizationMetadata {
        hostOrganizationByID[hostID] ?? HostOrganizationMetadata()
    }

    func saveHostOrganization(
        _ metadata: HostOrganizationMetadata,
        for hostID: String
    ) throws {
        let validated = try metadata.validated()
        if validated == HostOrganizationMetadata() {
            hostOrganizationByID[hostID] = nil
        } else {
            hostOrganizationByID[hostID] = validated
        }
        persistHostOrganization()
        notice = "Host organization metadata saved locally."
    }

    func clearInventoryScope() {
        hostInventoryFilter = HostInventoryFilter()
    }

    func saveTunnel(_ draft: TunnelDraft) async -> Bool {
        do {
            let saved = try await core.saveTunnel(draft)
            setTunnelSecretReference(draft.secretReference, for: saved.id)
            selectedTunnelID = saved.id
            showingNewTunnel = false
            notice = "Tunnel definition saved locally."
            await refresh()
            return true
        } catch {
            notice = error.localizedDescription
            return false
        }
    }

    func toggleTunnel(_ tunnel: TunnelModel) async {
        guard tunnelOperationID == nil else { return }
        tunnelOperationID = tunnel.id
        defer { tunnelOperationID = nil }
        let shouldRun = tunnel.status != .running
        var authenticationSecret = Data()
        defer {
            authenticationSecret.resetBytes(in: 0..<authenticationSecret.count)
            authenticationSecret.removeAll(keepingCapacity: false)
        }
        do {
            if shouldRun,
               tunnel.kind != .remote,
               let conflict = tunnels.first(where: {
                   $0.id != tunnel.id
                       && $0.kind != .remote
                       && $0.status == .running
                       && $0.bindAddress.caseInsensitiveCompare(tunnel.bindAddress) == .orderedSame
                       && $0.localPort == tunnel.localPort
               }) {
                notice = "Stop \(conflict.label) first. It already uses \(tunnel.bindAddress):\(tunnel.localPort)."
                return
            }
            if shouldRun, let reference = tunnelSecretReferenceByID[tunnel.id] {
                guard secrets.contains(where: { $0.id == reference }) else {
                    notice = "The SSH password reference for \(tunnel.label) no longer exists. Choose another Keychain secret."
                    return
                }
                let authenticatedNow = vaultIsLocked
                guard await unlockVaultIfNeeded(
                    reason: "Use the SSH password for \(tunnel.label)"
                ) else {
                    return
                }
                authenticationSecret = try await vault.revealSecret(
                    id: reference,
                    reason: "Start the SSH tunnel “\(tunnel.label)”",
                    authenticationAlreadySatisfied: authenticatedNow
                )
                registerVaultActivity()
            }
            notice = try await core.setTunnel(
                id: tunnel.id,
                running: shouldRun,
                authenticationSecret: authenticationSecret
            )
        } catch {
            notice = error.localizedDescription
        }
        await refresh()
    }

    func capability(_ id: String) -> ToolCapabilityModel? {
        capabilities.first { $0.id == id }
    }

    @discardableResult
    func runTool(
        adapterID: String,
        arguments: [String],
        workingDirectory: String,
        confirmedMutation: Bool,
        onEvent: (@MainActor @Sendable (OperationEventModel) -> Void)? = nil
    ) async -> ToolOperationModel? {
        guard !arguments.isEmpty else {
            notice = "Enter at least one command argument."
            return nil
        }
        let generation = UUID()
        toolOperationGeneration = generation
        let title = capability(adapterID)?.label ?? adapterID
        toolOperation = ToolOperationModel(adapterID: adapterID, title: title)
        do {
            try await core.runTool(
                adapterID: adapterID,
                arguments: arguments,
                workingDirectory: workingDirectory,
                confirmedMutation: confirmedMutation
            ) { [weak self] event in
                await MainActor.run {
                    guard let self,
                          self.toolOperationGeneration == generation,
                          var operation = self.toolOperation
                    else {
                        return
                    }
                    operation.consume(event)
                    self.toolOperation = operation
                    onEvent?(event)
                }
            }
        } catch {
            if toolOperationGeneration == generation, var operation = toolOperation {
                operation.phase = "failed"
                operation.isRunning = false
                operation.success = false
                if !operation.output.isEmpty, !operation.output.hasSuffix("\n") {
                    operation.output.append("\n")
                }
                operation.output.append("› \(error.localizedDescription)\n")
                toolOperation = operation
            }
            notice = error.localizedDescription
        }
        do {
            auditEvents = try await core.auditEvents()
        } catch {
            notice = error.localizedDescription
        }
        guard toolOperationGeneration == generation else { return nil }
        return toolOperation
    }

    func runHostCommand(
        host: HostModel,
        remoteCommand: String,
        confirmedMutation: Bool
    ) async {
        let arguments = hostCommandArguments(host: host, remoteCommand: remoteCommand)
        await runTool(
            adapterID: "ssh-host",
            arguments: arguments,
            workingDirectory: "",
            confirmedMutation: confirmedMutation
        )
    }

    func hostCommandArguments(host: HostModel, remoteCommand: String) -> [String] {
        [
            "-o", "BatchMode=yes",
            "-o", "ConnectTimeout=10",
            "-o", "ConnectionAttempts=1",
            host.alias,
            remoteCommand,
        ]
    }

    @discardableResult
    func runSFTPOperation(
        host: HostModel,
        operation: String,
        fields: [String],
        confirmedMutation: Bool,
        onEvent: (@MainActor @Sendable (OperationEventModel) -> Void)? = nil
    ) async -> ToolOperationModel? {
        return await runTool(
            adapterID: "sftp",
            arguments: [host.alias, operation] + fields,
            workingDirectory: "",
            confirmedMutation: confirmedMutation,
            onEvent: onEvent
        )
    }

    func beginCreatingDatabaseProfile() {
        editingDatabaseProfile = nil
        showingDatabaseProfileEditor = true
    }

    func beginEditingDatabaseProfile(_ profile: DatabaseProfileModel) {
        editingDatabaseProfile = profile
        showingDatabaseProfileEditor = true
    }

    func saveDatabaseProfile(
        _ draft: DatabaseProfileDraft,
        password: String? = nil,
        requireUserPresence: Bool = true
    ) async -> Bool {
        var createdSecretID: String?
        var passwordValue = password ?? ""
        defer { passwordValue.removeAll(keepingCapacity: false) }
        do {
            var profileDraft = draft
            if !passwordValue.isEmpty {
                guard await unlockVaultIfNeeded(reason: "Save a database password") else {
                    return false
                }
                let metadata = try await vault.saveSecret(
                    SecretDraft(
                        name: "\(draft.label) database password",
                        kind: .database,
                        value: passwordValue,
                        requiresUserPresence: requireUserPresence
                    )
                )
                createdSecretID = metadata.id
                profileDraft.secretReference = metadata.id
                secrets = try await vault.listSecrets()
                registerVaultActivity()
            }
            _ = try await core.saveDatabaseProfile(profileDraft)
            databaseProfiles = try await core.databaseProfiles()
            editingDatabaseProfile = nil
            showingDatabaseProfileEditor = false
            notice = "Database profile saved. Secret values remain in Keychain."
            return true
        } catch {
            if let createdSecretID {
                try? await vault.deleteSecret(id: createdSecretID)
                secrets = (try? await vault.listSecrets()) ?? secrets
            }
            notice = error.localizedDescription
            return false
        }
    }

    func deleteDatabaseProfile(_ profile: DatabaseProfileModel) async {
        do {
            try await core.deleteDatabaseProfile(id: profile.id)
            databaseProfiles = try await core.databaseProfiles()
            notice = "Database profile deleted. Its Keychain secret was not deleted."
        } catch {
            notice = error.localizedDescription
        }
    }

    func runDatabaseQuery(
        profile: DatabaseProfileModel,
        sql: String,
        confirmedMutation: Bool
    ) async {
        var secret = Data()
        var tunnelSSHAuthenticationSecret = Data()
        var authenticationSatisfiedThisOperation = false
        do {
            if !profile.secretReference.isEmpty {
                let unlockedNow = vaultIsLocked
                guard await unlockVaultIfNeeded(reason: "Use a Keychain secret for \(profile.label)") else {
                    return
                }
                secret = try await vault.revealSecret(
                    id: profile.secretReference,
                    reason: "Connect to \(profile.label)",
                    authenticationAlreadySatisfied: unlockedNow
                )
                authenticationSatisfiedThisOperation = unlockedNow
                    || secrets.first(where: { $0.id == profile.secretReference })?
                        .requiresUserPresence == true
                registerVaultActivity()
            }
            if profile.autoStartTunnel,
               let tunnel = tunnels.first(where: { $0.id == profile.tunnelID }),
               tunnel.status != .running,
               let reference = tunnelSecretReferenceByID[tunnel.id] {
                guard secrets.contains(where: { $0.id == reference }) else {
                    notice = "The SSH password reference for \(tunnel.label) no longer exists. Choose another Keychain secret in Tunnels."
                    return
                }
                let authenticatedNow = vaultIsLocked
                guard await unlockVaultIfNeeded(
                    reason: "Use the SSH password for \(tunnel.label)"
                ) else {
                    return
                }
                tunnelSSHAuthenticationSecret = try await vault.revealSecret(
                    id: reference,
                    reason: "Start the SSH tunnel “\(tunnel.label)” for \(profile.label)",
                    authenticationAlreadySatisfied: authenticatedNow
                        || authenticationSatisfiedThisOperation
                )
                registerVaultActivity()
            }
            defer {
                secret.resetBytes(in: 0..<secret.count)
                secret.removeAll(keepingCapacity: false)
                tunnelSSHAuthenticationSecret.resetBytes(
                    in: 0..<tunnelSSHAuthenticationSecret.count
                )
                tunnelSSHAuthenticationSecret.removeAll(keepingCapacity: false)
            }
            toolOperation = ToolOperationModel(adapterID: "database", title: profile.label)
            try await core.runDatabaseQuery(
                profileID: profile.id,
                secret: secret,
                tunnelSSHAuthenticationSecret: tunnelSSHAuthenticationSecret,
                sql: sql,
                confirmedMutation: confirmedMutation
            ) { [weak self] event in
                await MainActor.run {
                    guard let self, var operation = self.toolOperation else { return }
                    operation.consume(event)
                    self.toolOperation = operation
                }
            }
            auditEvents = try await core.auditEvents()
        } catch {
            if var operation = toolOperation {
                operation.phase = "failed"
                operation.isRunning = false
                operation.success = false
                operation.output.append("› \(error.localizedDescription)\n")
                toolOperation = operation
            }
            notice = error.localizedDescription
        }
    }

    func cancelToolOperation() async {
        guard let operation = toolOperation, !operation.id.isEmpty, operation.isRunning else {
            return
        }
        do {
            let accepted = try await core.cancelOperation(id: operation.id)
            if !accepted {
                notice = "The operation already finished before cancellation."
            }
        } catch {
            notice = error.localizedDescription
        }
    }

    func exportEncryptedBackup(to url: URL, passphrase: String) async -> Bool {
        isBusy = true
        defer { isBusy = false }
        do {
            let coreSnapshot = try await core.exportBackup()
            let payload = AegizBackupPayload(
                schemaVersion: 1,
                createdAt: Date(),
                coreSnapshot: coreSnapshot,
                hostOrganization: hostOrganizationByID,
                terminalSettings: terminalSettingsByHost
            )
            let encrypted = try await Task.detached {
                try AegizBackupManager.seal(payload, passphrase: passphrase)
            }.value
            try encrypted.write(to: url, options: [.atomic, .completeFileProtection])
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: url.path
            )
            notice = "Encrypted backup saved. Keychain secret values were intentionally excluded."
            auditEvents = try await core.auditEvents()
            return true
        } catch {
            notice = error.localizedDescription
            return false
        }
    }

    func restoreEncryptedBackup(from url: URL, passphrase: String) async -> Bool {
        isBusy = true
        defer { isBusy = false }
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            let size = (attributes[.size] as? NSNumber)?.intValue ?? 0
            guard size > 0, size <= AegizBackupManager.maximumFileSize else {
                throw AegizBackupError.oversized
            }
            let encrypted = try Data(contentsOf: url, options: [.mappedIfSafe])
            let payload = try await Task.detached {
                try AegizBackupManager.open(encrypted, passphrase: passphrase)
            }.value
            let report = try await core.restoreBackup(
                payload.coreSnapshot,
                confirmedReplace: true
            )
            hostOrganizationByID = payload.hostOrganization
            terminalSettingsByHost = payload.terminalSettings
            persistHostOrganization()
            persistTerminalSettings()
            terminalControllers.removeAll()
            await refresh()
            notice = "Restore complete: \(report.hosts) hosts, \(report.tunnels) tunnels, and \(report.databaseProfiles) database profiles. All tunnels were restored stopped."
            return true
        } catch {
            notice = error.localizedDescription
            return false
        }
    }

    func exportAudit(to url: URL, format: AuditExportFormat) -> Bool {
        do {
            let data = switch format {
            case .json: try AuditExporter.json(auditEvents)
            case .csv: AuditExporter.csv(auditEvents)
            }
            try data.write(to: url, options: [.atomic, .completeFileProtection])
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: url.path
            )
            notice = "Redacted audit events exported as \(format.rawValue.uppercased())."
            return true
        } catch {
            notice = error.localizedDescription
            return false
        }
    }

    func refreshVault() async {
        do {
            vaultStatus = try await vault.prepare()
            secrets = try await vault.listSecrets()
        } catch {
            notice = error.localizedDescription
        }
    }

    func beginCreatingSecret(kind: SecretKindModel = .generic) {
        editingSecret = nil
        pendingNewSecretKind = kind
        showingNewSecret = true
    }

    func beginEditingSecret(_ secret: SecretMetadataModel) {
        editingSecret = secret
        pendingNewSecretKind = secret.kind
        showingNewSecret = true
    }

    func saveSecret(_ draft: SecretDraft) async -> Bool {
        do {
            guard await unlockVaultIfNeeded(reason: "Change an Aegiz Keychain secret") else {
                return false
            }
            _ = try await vault.saveSecret(draft, replacingID: editingSecret?.id)
            secrets = try await vault.listSecrets()
            showingNewSecret = false
            editingSecret = nil
            pendingNewSecretKind = .generic
            registerVaultActivity()
            notice = "Secret saved in the local macOS Keychain."
            return true
        } catch {
            notice = error.localizedDescription
            return false
        }
    }

    func revealSecret(_ secret: SecretMetadataModel) async {
        do {
            let unlockedNow = vaultIsLocked
            guard await unlockVaultIfNeeded(reason: "Unlock the Aegiz local vault") else {
                return
            }
            let data = try await vault.revealSecret(
                id: secret.id,
                reason: "Reveal “\(secret.name)” in Aegiz",
                authenticationAlreadySatisfied: unlockedNow
            )
            hideRevealedSecret()
            revealedSecretID = secret.id
            revealedSecretData = data
            revealExpiryTimer = AegizMainRunLoopTimer.schedule(after: 30) { [weak self] in
                self?.hideRevealedSecret()
            }
            registerVaultActivity()
        } catch {
            notice = error.localizedDescription
        }
    }

    func hideRevealedSecret() {
        revealExpiryTimer?.invalidate()
        revealExpiryTimer = nil
        revealedSecretData.resetBytes(in: 0..<revealedSecretData.count)
        revealedSecretData.removeAll(keepingCapacity: false)
        revealedSecretID = nil
    }

    func deleteSecret(_ secret: SecretMetadataModel) async {
        do {
            guard await unlockVaultIfNeeded(reason: "Delete an Aegiz Keychain secret") else {
                return
            }
            if revealedSecretID == secret.id {
                hideRevealedSecret()
            }
            try await vault.deleteSecret(id: secret.id)
            tunnelSecretReferenceByID = tunnelSecretReferenceByID.filter {
                $0.value != secret.id
            }
            persistTunnelSecretReferences()
            secrets = try await vault.listSecrets()
            notice = "Secret deleted from the local Keychain."
            registerVaultActivity()
        } catch {
            notice = error.localizedDescription
        }
    }

    func unlockVault() async {
        _ = await unlockVaultIfNeeded(reason: "Unlock the Aegiz local vault")
    }

    func lockVault() {
        vaultLockTimer?.invalidate()
        vaultLockTimer = nil
        hideRevealedSecret()
        vaultIsLocked = true
    }

    func setVaultAutoLock(minutes: Int) {
        vaultAutoLockMinutes = minutes
        UserDefaults.standard.set(minutes, forKey: "vaultAutoLockMinutes")
        if !vaultIsLocked {
            registerVaultActivity()
        }
    }

    private func unlockVaultIfNeeded(reason: String) async -> Bool {
        if !vaultIsLocked {
            return true
        }
        do {
            try await vault.authenticate(reason: reason)
            vaultIsLocked = false
            registerVaultActivity()
            return true
        } catch {
            notice = error.localizedDescription
            return false
        }
    }

    private func registerVaultActivity() {
        vaultLockTimer?.invalidate()
        vaultLockTimer = AegizMainRunLoopTimer.schedule(
            after: TimeInterval(vaultAutoLockMinutes * 60)
        ) { [weak self] in
            self?.lockVault()
        }
    }

    private func restoreTerminalSessions() {
        guard let data = UserDefaults.standard.data(forKey: "terminalSessionMetadata"),
              let restored = try? JSONDecoder().decode([TerminalSessionModel].self, from: data)
        else {
            return
        }
        terminalSessions = Array(restored.prefix(20))
        if let selectedID = UserDefaults.standard.string(forKey: "selectedTerminalSessionID")
            .flatMap(UUID.init(uuidString:)),
           terminalSessions.contains(where: { $0.id == selectedID }) {
            selectedTerminalSessionID = selectedID
        } else {
            selectedTerminalSessionID = terminalSessions.last?.id
        }
    }

    private func restoreTerminalSettings() {
        guard let data = UserDefaults.standard.data(forKey: "terminalHostSettings"),
              let restored = try? JSONDecoder().decode(
                [String: TerminalHostSettings].self,
                from: data
              )
        else {
            return
        }
        terminalSettingsByHost = restored
    }

    private func restoreHostOrganization() {
        guard let data = UserDefaults.standard.data(forKey: "hostOrganizationMetadata"),
              let restored = try? JSONDecoder().decode(
                  [String: HostOrganizationMetadata].self,
                  from: data
              )
        else {
            return
        }
        hostOrganizationByID = restored
    }

    private func restoreTunnelSecretReferences() {
        guard let data = UserDefaults.standard.data(forKey: "tunnelSecretReferences"),
              let restored = try? JSONDecoder().decode([String: String].self, from: data)
        else {
            return
        }
        tunnelSecretReferenceByID = restored
    }

    private func persistTerminalSettings() {
        guard let data = try? JSONEncoder().encode(terminalSettingsByHost) else {
            return
        }
        UserDefaults.standard.set(data, forKey: "terminalHostSettings")
    }

    private func persistHostOrganization() {
        guard let data = try? JSONEncoder().encode(hostOrganizationByID) else {
            return
        }
        UserDefaults.standard.set(data, forKey: "hostOrganizationMetadata")
    }

    private func persistTunnelSecretReferences() {
        guard let data = try? JSONEncoder().encode(tunnelSecretReferenceByID) else {
            return
        }
        UserDefaults.standard.set(data, forKey: "tunnelSecretReferences")
    }

    private func organizedValues(
        _ keyPath: KeyPath<HostOrganizationMetadata, String>
    ) -> [String] {
        Array(
            Set(
                hostOrganizationByID.values
                    .map { $0[keyPath: keyPath] }
                    .filter { !$0.isEmpty }
            )
        ).sorted {
            $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
        }
    }

    private func persistTerminalSessions() {
        if let data = try? JSONEncoder().encode(terminalSessions) {
            UserDefaults.standard.set(data, forKey: "terminalSessionMetadata")
        }
        UserDefaults.standard.set(
            selectedTerminalSessionID?.uuidString,
            forKey: "selectedTerminalSessionID"
        )
    }
}
