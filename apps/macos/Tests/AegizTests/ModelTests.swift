import AppKit
import CryptoKit
import Foundation
import Testing
@testable import Aegiz

@MainActor
private enum GhosttySmokeLifetime {
    // libghostty's embedded runtime is process-scoped. Retaining the smoke
    // surface matches production lifetime and avoids tearing its renderer
    // down while Swift Testing is still draining executor callbacks.
    static var surface: EmbeddedGhosttyNSView?
    static var window: NSWindow?
}

@Test
func tunnelRouteExplainsItsDirection() {
    let tunnel = TunnelModel(
        id: "1",
        hostID: "2",
        label: "Postgres",
        kind: .local,
        bindAddress: "127.0.0.1",
        localPort: 5433,
        remoteHost: "db.internal",
        remotePort: 5432,
        status: .stopped,
        lastError: ""
    )
    #expect(tunnel.route == "127.0.0.1:5433 → db.internal:5432")
    #expect(
        tunnel.route(via: "homeserver")
            == "Mac 127.0.0.1:5433 → SSH homeserver → remote db.internal:5432"
    )
}

@Test
func adaptiveSheetPoliciesKeepUsableOrderedBounds() {
    #expect(!AegizSheetSizingPolicy.all.isEmpty)
    for size in AegizSheetSizingPolicy.all {
        #expect(size.hasOrderedBounds)
        #expect(size.minWidth >= 420)
        #expect(size.minHeight >= 320)
    }
}

@Test
func commandTokenizerPreservesQuotedArgumentsWithoutRunningAShell() throws {
    let arguments = try CommandLineTokenizer.parse(
        #"get pods --selector "app=api worker" --context 'company prod'"#
    )
    #expect(
        arguments
            == ["get", "pods", "--selector", "app=api worker", "--context", "company prod"]
    )
}

@Test
func commandTokenizerRejectsUnfinishedInput() {
    #expect(throws: CommandLineTokenizerError.self) {
        try CommandLineTokenizer.parse(#"get pods "unfinished"#)
    }
}

@Test
func commandRiskRequiresReviewForMutationsAndUnknownCommands() {
    #expect(
        ToolCommandRisk.requiresConfirmation(
            adapterID: "kubectl",
            arguments: ["delete", "pod", "api"]
        )
    )
    #expect(
        !ToolCommandRisk.requiresConfirmation(
            adapterID: "aws",
            arguments: ["sts", "get-caller-identity"]
        )
    )
}

@Test
func operationOutputIsBounded() {
    var operation = ToolOperationModel(adapterID: "kubectl", title: "kubectl")
    operation.consume(
        OperationEventModel(
            operationID: "1",
            phase: "running",
            message: String(repeating: "x", count: 1_100_000),
            stream: "stdout",
            sequence: 1,
            progress: 50,
            terminal: false,
            success: false,
            exitCode: 0
        )
    )
    #expect(operation.output.utf8.count <= 750_000)
}

@Test
func embeddedTerminalRejectsCommandInjectionThroughHostAlias() {
    #expect(EmbeddedGhosttyNSView.isSafeHostAlias("prod-api-01"))
    #expect(EmbeddedGhosttyNSView.isSafeHostAlias("bastion.internal"))
    #expect(!EmbeddedGhosttyNSView.isSafeHostAlias("-oProxyCommand=bad"))
    #expect(!EmbeddedGhosttyNSView.isSafeHostAlias("prod; touch /tmp/bad"))
    #expect(!EmbeddedGhosttyNSView.isSafeHostAlias("prod\nother"))
}

@Test
func embeddedTerminalVisibilityNeverRendersDetachedOrHiddenSurfaces() {
    #expect(
        EmbeddedGhosttyNSView.presentationVisibility(
            windowAttached: true,
            windowVisible: true,
            windowMiniaturized: false,
            hidden: false
        )
    )
    #expect(
        !EmbeddedGhosttyNSView.presentationVisibility(
            windowAttached: false,
            windowVisible: true,
            windowMiniaturized: false,
            hidden: false
        )
    )
    #expect(
        !EmbeddedGhosttyNSView.presentationVisibility(
            windowAttached: true,
            windowVisible: false,
            windowMiniaturized: false,
            hidden: false
        )
    )
    #expect(
        !EmbeddedGhosttyNSView.presentationVisibility(
            windowAttached: true,
            windowVisible: true,
            windowMiniaturized: true,
            hidden: false
        )
    )
    #expect(
        !EmbeddedGhosttyNSView.presentationVisibility(
            windowAttached: true,
            windowVisible: true,
            windowMiniaturized: false,
            hidden: true
        )
    )
}

@Test
func ghosttyWakeupsAreCoalescedBeforeTheyReachTheMainThread() {
    let gate = GhosttyWakeupGate()
    #expect(gate.claim())
    for _ in 0..<10_000 {
        #expect(!gate.claim())
    }
    gate.release()
    #expect(gate.claim())
}

@Test
func ghosttyFramebufferMetricsAreStableAcrossEquivalentLayouts() {
    let first = GhosttyFramebufferMetrics.make(
        bounds: NSRect(x: 0, y: 0, width: 640, height: 360),
        scale: 2
    )
    let equivalent = GhosttyFramebufferMetrics.make(
        bounds: NSRect(x: 40, y: 80, width: 640, height: 360),
        scale: 2
    )
    #expect(first == equivalent)
    #expect(first?.width == 1_280)
    #expect(first?.height == 720)
    #expect(GhosttyFramebufferMetrics.make(bounds: .zero, scale: 2) == nil)
}

@Test
@MainActor
func embeddedGhosttyCreatesAMetalBackedSurface() throws {
    let application = NSApplication.shared
    if !application.isRunning {
        application.setActivationPolicy(.accessory)
        application.finishLaunching()
    }
    let testConfig = FileManager.default.temporaryDirectory
        .appendingPathComponent("aegiz-ghostty-\(UUID().uuidString).conf")
    try Data("window-vsync = false\n".utf8).write(to: testConfig, options: .atomic)
    defer { try? FileManager.default.removeItem(at: testConfig) }

    let app = try GhosttyRuntime.shared.application(additionalConfigPath: testConfig.path)
    let view = try EmbeddedGhosttyNSView(
        app: app,
        command: "/usr/bin/printf aegiz-ghostty-smoke"
    )
    view.setFrameSize(NSSize(width: 640, height: 360))
    let container = NSView(frame: NSRect(x: 0, y: 0, width: 640, height: 360))
    let window = NSWindow(
        contentRect: container.bounds,
        styleMask: [.titled, .closable, .resizable],
        backing: .buffered,
        defer: false
    )
    window.contentView = container
    view.frame = container.bounds
    container.addSubview(view)
    window.orderFrontRegardless()
    view.viewDidMoveToWindow()
    #expect(view.isSurfaceReady)
    #expect(view.wantsLayer)
    #expect(view.layer != nil)
    #expect(window.isVisible)
    #expect(view.reportedVisible == true)

    view.removeFromSuperview()
    #expect(view.reportedVisible == false)
    container.addSubview(view)
    #expect(view.reportedVisible == true)

    GhosttySmokeLifetime.surface = view
    GhosttySmokeLifetime.window = window
}

@Test
func hostOperationRiskAndFailureClassificationAreExplicit() {
    let readArguments = [
        "-o", "BatchMode=yes",
        "-o", "ConnectTimeout=10",
        "-o", "ConnectionAttempts=1",
        "prod-api",
        HostRemoteCommandRisk.serviceListCommand,
    ]
    #expect(!ToolCommandRisk.requiresConfirmation(adapterID: "ssh-host", arguments: readArguments))

    var mutationArguments = readArguments
    mutationArguments[7] = "systemctl restart api.service"
    #expect(ToolCommandRisk.requiresConfirmation(adapterID: "ssh-host", arguments: mutationArguments))
    #expect(
        HostOperationFailureClassifier.message(for: "Permission denied (publickey)")
            == "Authentication failed. Check the selected SSH config identity, agent, or server authorization."
    )
    var injectedRead = readArguments
    injectedRead[7] = "\(HostRemoteCommandRisk.processListCommand); reboot"
    #expect(ToolCommandRisk.requiresConfirmation(adapterID: "ssh-host", arguments: injectedRead))
    var logTail = readArguments
    logTail[7] = "tail -n 200 -F -- '/var/log/api.log'"
    #expect(!ToolCommandRisk.requiresConfirmation(adapterID: "ssh-host", arguments: logTail))
}

@Test
func terminalSettingsValidateEnvironmentAndEscapeRemoteDirectories() throws {
    let environment = try TerminalHostSettings.parseEnvironment(
        "LANG=en_US.UTF-8\nAEGIZ_MODE=ops\n# comment"
    )
    #expect(environment.count == 2)
    #expect(environment[1].name == "AEGIZ_MODE")
    #expect(throws: TerminalSettingsError.self) {
        try TerminalHostSettings.parseEnvironment("BAD-NAME=value")
    }

    let settings = TerminalHostSettings(
        remoteWorkingDirectory: "/srv/team's api",
        environment: environment,
        fontSize: 14,
        startupCommand: "exec ./console"
    )
    let launch = TerminalLaunchConfiguration(hostAlias: "prod-api", settings: settings)
    #expect(launch.initialInput == "cd -- '/srv/team'\"'\"'s api' && exec ./console\n")
    #expect(launch.command.contains("ConnectTimeout=10"))
    #expect(launch.command.contains("ServerAliveInterval=30"))
    let path = launch.environment.first { $0.name == "PATH" }?.value ?? ""
    #expect(path.split(separator: ":").contains("/opt/homebrew/bin"))
    #expect(path.split(separator: ":").contains("/usr/bin"))
}

@Test
func terminalRuntimePathIsAddedOnceAndExplicitOverridesArePreserved() {
    let added = AegizProcessEnvironment.addingExecutableSearchPath(to: [])
    #expect(added.filter { $0.name == "PATH" }.count == 1)

    let explicit = [TerminalEnvironmentVariable(name: "PATH", value: "/custom/bin")]
    #expect(AegizProcessEnvironment.addingExecutableSearchPath(to: explicit) == explicit)
}

@Test
func ghosttyTickThrottleBoundsBurstFrequencyWithoutAddingIdleDelay() {
    let interval = GhosttyTickThrottle.minimumInterval
    #expect(abs(GhosttyTickThrottle.delay(now: 10, lastTick: 10) - interval) < 0.000_001)
    #expect(GhosttyTickThrottle.delay(now: 10 + interval, lastTick: 10) == 0)
    #expect(GhosttyTickThrottle.delay(now: 11, lastTick: 10) == 0)
}

@Test
@MainActor
func vaultExpiryUsesCancelableMainRunLoopTimer() {
    var fireCount = 0
    let timer = AegizMainRunLoopTimer.schedule(after: 3_600) {
        fireCount += 1
    }
    #expect(timer.isValid)
    timer.fire()
    #expect(fireCount == 1)
    #expect(!timer.isValid)
}

@Test
func disposableLoginKeychainRoundTrip() async throws {
    guard ProcessInfo.processInfo.environment["AEGIZ_RUN_KEYCHAIN_FIXTURE"] == "1" else {
        return
    }
    let service = "dev.aegiz.desktop.fixture.\(UUID().uuidString.lowercased())"
    let vault = KeychainVault(fixtureService: service)
    var createdID: String?

    do {
        var draft = SecretDraft()
        draft.name = "Disposable Aegiz fixture"
        draft.kind = .apiToken
        draft.value = "first-fixture-value"
        draft.requiresUserPresence = false
        let created = try await vault.saveSecret(draft)
        createdID = created.id

        let listed = try await vault.listSecrets()
        #expect(listed.map(\.id) == [created.id])
        #expect(listed.first?.kind == .apiToken)
        #expect(listed.first?.requiresUserPresence == false)

        var revealed = try await vault.revealSecret(
            id: created.id,
            reason: "Disposable fixture",
            authenticationAlreadySatisfied: true
        )
        #expect(String(decoding: revealed, as: UTF8.self) == "first-fixture-value")
        revealed.resetBytes(in: 0..<revealed.count)

        draft.name = "Updated disposable fixture"
        draft.value = "second-fixture-value"
        let updated = try await vault.saveSecret(draft, replacingID: created.id)
        #expect(updated.id == created.id)
        #expect(updated.name == draft.name)

        var updatedValue = try await vault.revealSecret(
            id: created.id,
            reason: "Disposable fixture",
            authenticationAlreadySatisfied: true
        )
        #expect(String(decoding: updatedValue, as: UTF8.self) == "second-fixture-value")
        updatedValue.resetBytes(in: 0..<updatedValue.count)

        try await vault.deleteSecret(id: created.id)
        createdID = nil
        #expect(try await vault.listSecrets().isEmpty)
    } catch {
        if let createdID {
            try? await vault.deleteSecret(id: createdID)
        }
        throw error
    }
}

@Test
func closingATerminalSplitRemovesOnlyItsDuplicateSession() {
    let primary = TerminalSessionModel(
        localTitle: "primary",
        endpoint: "local",
        executable: "/usr/bin/aws",
        arguments: ["--version"]
    )
    let split = TerminalSessionModel(
        localTitle: "split",
        endpoint: "local",
        executable: "/usr/bin/aws",
        arguments: ["--version"]
    )
    let remaining = TerminalSessionLifecycle.removing(split.id, from: [primary, split])
    #expect(remaining.map(\.id) == [primary.id])
}

@Test
func tunnelCollisionKeysApplyOnlyToMacListeningEndpoints() {
    var tunnel = TunnelModel(
        id: "local",
        hostID: "host",
        label: "Local DB",
        kind: .local,
        bindAddress: "LOCALHOST",
        localPort: 5433,
        remoteHost: "127.0.0.1",
        remotePort: 5432,
        status: .stopped,
        lastError: ""
    )
    #expect(tunnel.localEndpointKey == "localhost:5433")
    tunnel.kind = .dynamic
    #expect(tunnel.localEndpointKey == "localhost:5433")
    tunnel.kind = .remote
    #expect(tunnel.localEndpointKey == nil)
}

@Test
func localTerminalCommandsAreFixedAndArgumentEscaped() {
    let command = TerminalLocalCommand.encoded(
        executable: "/usr/local/bin/kubectl",
        arguments: ["exec", "-it", "pod/api", "--", "/bin/sh"]
    )
    #expect(command?.contains(#"'pod/api'"#) == true)
    #expect(
        TerminalLocalCommand.encoded(
            executable: "/bin/sh",
            arguments: ["-c", "touch /tmp/bad"]
        ) == nil
    )
    #expect(
        TerminalLocalCommand.encoded(
            executable: "/usr/bin/aws",
            arguments: ["ssm", "start-session\nother"]
        ) == nil
    )
}

@Test
func sftpListingParserKeepsNamesWithSpacesAndDirectoryOrdering() {
    let listing = """
    -rw-r--r-- 1 deploy staff 128 Jul 30 12:41 app config.json
    drwxr-xr-x 2 deploy staff 4096 Jul 30 12:40 release logs
    """
    let entries = SFTPListingParser.parse(listing, directory: "/srv/app")
    #expect(entries.count == 2)
    #expect(entries[0].isDirectory)
    #expect(entries[0].path == "/srv/app/release logs")
    #expect(entries[1].name == "app config.json")
    #expect(entries[1].size == 128)
}

@Test
func sftpListingParserNormalizesServerPrefixedNamesWithoutDuplicatingTheDirectory() {
    let listing = """
    drwxr-xr-x  4 deploy staff 128 Jul 31 10:20 ./deployment/identity-service
    -rw-r--r--  1 deploy staff 512 Jul 31 10:21 ./deployment/docker-compose.yml
    drwxr-xr-x  4 deploy staff 128 Jul 31 10:20 ./deployment/.
    """

    let entries = SFTPListingParser.parse(listing, directory: "./deployment")

    #expect(entries.map(\.name) == ["identity-service", "docker-compose.yml"])
    #expect(entries.map(\.path) == [
        "./deployment/identity-service",
        "./deployment/docker-compose.yml",
    ])
}

@Test
func sftpListingParserDeduplicatesRepeatedOpenSSHStreamLinesByRemotePath() {
    let line = "drwxr-xr-x  4 deploy staff 128 Jul 31 10:20 ./deployment/api"
    let entries = SFTPListingParser.parse("\(line)\n\(line)\n", directory: "./deployment")

    #expect(entries.count == 1)
    #expect(entries.first?.name == "api")
    #expect(entries.first?.path == "./deployment/api")
}

@Test
func filePreviewDecoderHandlesUnicodeLegacyTextAndLongLines() throws {
    let utf8 = try FileTextPreviewDecoder.decode(Data([0xEF, 0xBB, 0xBF]) + Data("hello".utf8))
    #expect(utf8.text == "hello")
    #expect(utf8.encoding == "UTF-8")

    let utf16Text = "deployment=ready\n"
    let utf16 = try #require(utf16Text.data(using: .utf16LittleEndian))
    let utf16Preview = try FileTextPreviewDecoder.decode(Data([0xFF, 0xFE]) + utf16)
    #expect(utf16Preview.text == utf16Text)
    #expect(utf16Preview.encoding == "UTF-16 LE")

    let legacy = try FileTextPreviewDecoder.decode(Data([0x63, 0x61, 0x66, 0xE9]))
    #expect(legacy.text == "café")
    #expect(legacy.encoding == "Windows-1252")

    let longLine = String(repeating: "x", count: 300_000)
    let longPreview = try FileTextPreviewDecoder.decode(Data(longLine.utf8))
    #expect(longPreview.text.count == 300_000)
}

@Test
func filePreviewDecoderDistinguishesEmptyWhitespaceBinaryAndOversizedFiles() throws {
    let empty = try FileTextPreviewDecoder.decode(Data())
    #expect(empty.text.isEmpty)
    #expect(empty.encoding == "Empty")

    let whitespace = try FileTextPreviewDecoder.decode(Data(" \n\t".utf8))
    #expect(whitespace.containsOnlyWhitespace)

    #expect(throws: FileTextPreviewError.binary) {
        try FileTextPreviewDecoder.decode(Data([0x89, 0x50, 0x4E, 0x47, 0, 1, 2]))
    }
    #expect(throws: FileTextPreviewError.tooLarge(limit: 8)) {
        try FileTextPreviewDecoder.decode(Data(repeating: 0x61, count: 9), maximumBytes: 8)
    }
}

@Test
func filePreviewDecoderMakesUnsafeControlBytesVisible() throws {
    let preview = try FileTextPreviewDecoder.decode(Data([0x61, 0x1B, 0x62]))
    #expect(preview.text == "a\u{FFFD}b")
}

@Test
func databaseQueryRiskIsConservative() {
    #expect(DatabaseQueryRisk.isReadOnly(" SELECT current_timestamp;"))
    #expect(DatabaseQueryRisk.isReadOnly("EXPLAIN SELECT * FROM users"))
    #expect(!DatabaseQueryRisk.isReadOnly("WITH removed AS (DELETE FROM users RETURNING *) SELECT * FROM removed"))
    #expect(!DatabaseQueryRisk.isReadOnly("-- looks safe\nSELECT 1"))
    #expect(!DatabaseQueryRisk.isReadOnly("UPDATE users SET admin = true"))
    #expect(!DatabaseQueryRisk.isReadOnly("SELECT 1; DELETE FROM users"))
    #expect(DatabaseQueryRisk.isReadOnly("SCAN 0 COUNT 200", engine: .redis))
    #expect(!DatabaseQueryRisk.isReadOnly("DEL session:1", engine: .redis))
    #expect(RedisCommandEscaping.quoted(#"release "blue""#) == #""release \"blue\"""#)
    let history = DatabaseQueryHistory.redactedSummary(
        "SELECT * FROM users WHERE token='abc123'"
    )
    #expect(history.contains("[REDACTED]"))
    #expect(!history.contains("abc123"))
}

@Test
func organizationMetadataIsNormalizedAndBounded() throws {
    let value = try HostOrganizationMetadata(
        workspace: "  Consulting ",
        company: " Example Co ",
        environment: " production ",
        tags: ["api", " api ", "critical"],
        favorite: true
    ).validated()
    #expect(value.workspace == "Consulting")
    #expect(value.company == "Example Co")
    #expect(value.environment == "production")
    #expect(value.tags == ["api", "critical"])
    #expect(value.favorite)
    #expect(throws: HostOrganizationMetadataError.self) {
        try HostOrganizationMetadata(workspace: "bad\nvalue").validated()
    }
}

@Test
func terminalSessionMetadataDecodesOlderRecordsWithoutLocalPTYFields() throws {
    struct Legacy: Codable {
        let id: UUID
        let hostID: String
        let hostAlias: String
        let endpoint: String
        let createdAt: Date
        let generation: UUID
    }
    let legacy = Legacy(
        id: UUID(),
        hostID: "host-1",
        hostAlias: "prod-api",
        endpoint: "deploy@prod-api",
        createdAt: Date(),
        generation: UUID()
    )
    let decoded = try JSONDecoder().decode(
        TerminalSessionModel.self,
        from: JSONEncoder().encode(legacy)
    )
    #expect(decoded.localExecutable == nil)
    #expect(decoded.localArguments == nil)
}

@Test
func pbkdf2MatchesTheHMACSHA256KnownVector() throws {
    let key = try PBKDF2SHA256.derive(
        passphrase: "password",
        salt: Data("salt".utf8),
        iterations: 1
    )
    let bytes = key.withUnsafeBytes { Data($0) }
    #expect(
        bytes.map { String(format: "%02x", $0) }.joined()
            == "120fb6cffcf8b32c43e7225256c4f837a86548c92ccc35480805987cb70be17b"
    )
}

@Test
func encryptedBackupRoundTripsAndRejectsTampering() throws {
    let payload = AegizBackupPayload(
        schemaVersion: 1,
        createdAt: Date(timeIntervalSince1970: 1_700_000_000),
        coreSnapshot: Data(#"{"schema_version":1}"#.utf8),
        hostOrganization: [
            "host-1": HostOrganizationMetadata(
                workspace: "consulting",
                company: "example",
                environment: "production",
                favorite: true
            ),
        ],
        terminalSettings: [
            "host-1": TerminalHostSettings(
                remoteWorkingDirectory: "/srv/app",
                environment: [
                    TerminalEnvironmentVariable(name: "LANG", value: "en_US.UTF-8"),
                ],
                fontSize: 14
            ),
        ]
    )
    var encrypted = try AegizBackupManager.seal(
        payload,
        passphrase: "correct horse battery staple"
    )
    let restored = try AegizBackupManager.open(
        encrypted,
        passphrase: "correct horse battery staple"
    )
    #expect(restored.coreSnapshot == payload.coreSnapshot)
    #expect(restored.hostOrganization["host-1"]?.favorite == true)
    #expect(restored.terminalSettings["host-1"]?.remoteWorkingDirectory == "/srv/app")

    encrypted[encrypted.count - 3] ^= 1
    #expect(throws: AegizBackupError.self) {
        try AegizBackupManager.open(
            encrypted,
            passphrase: "correct horse battery staple"
        )
    }
}

@Test
func auditCSVPreventsSpreadsheetFormulaInjection() {
    let data = AuditExporter.csv([
        AuditEventModel(
            id: 1,
            occurredAt: Date(timeIntervalSince1970: 0),
            action: "=HYPERLINK(\"bad\")",
            resourceID: "host-1",
            outcome: "success",
            detail: "safe"
        ),
    ])
    let csv = String(decoding: data, as: UTF8.self)
    #expect(csv.contains("\"'=HYPERLINK(\"\"bad\"\")\""))
}

@Test
func everyStructuredAdapterDefaultsMutationsToConfirmation() {
    let mutations: [(String, [String])] = [
        ("docker", ["--context", "prod", "container", "rm", "api"]),
        ("kubectl", ["--context", "prod", "-n", "payments", "delete", "pod", "api"]),
        ("aws", ["--profile", "prod", "ec2", "stop-instances", "--instance-ids", "i-123"]),
        ("terraform", ["apply", "reviewed.tfplan"]),
        ("ansible-playbook", ["-i", "inventory", "site.yml"]),
        ("sftp", ["prod-api", "delete", "/tmp/file"]),
    ]
    for (adapter, arguments) in mutations {
        #expect(
            ToolCommandRisk.requiresConfirmation(
                adapterID: adapter,
                arguments: arguments
            ),
            "Expected confirmation for \(adapter)"
        )
    }
}

@Test
func dockerStructuredOutputParsersHandleJSONLinesAndArrays() {
    let contexts = DockerOutputParser.contexts(
        """
        › docker context ls
        {"Name":"default","DockerEndpoint":"unix:///var/run/docker.sock","Current":"true"}
        """
    )
    #expect(contexts.count == 1)
    #expect(contexts[0].current)
    let containers = DockerOutputParser.containers(
        """
        [{"ID":"abc123","Names":"api","Image":"example/api:1","State":"running","Status":"Up","Ports":"8080/tcp"}]
        """
    )
    #expect(containers.first?.name == "api")
    #expect(containers.first?.state == "running")
    let projects = DockerOutputParser.compose(
        """
        [{"Name":"payments","Status":"running(2)","ConfigFiles":"/srv/payments/compose.yml"}]
        """
    )
    #expect(projects.first?.inferredWorkingDirectory == "/srv/payments")
}

@Test
func kubernetesStructuredOutputParserKeepsContextualIdentityAndReadiness() {
    let identity = KubernetesOutputParser.identity(
        #"{"status":{"userInfo":{"username":"ops@example.com"}}}"#
    )
    #expect(identity == "ops@example.com")
    let pods = KubernetesOutputParser.resources(
        """
        {"items":[{"metadata":{"uid":"pod-1","namespace":"payments","name":"api"},"status":{"phase":"Running","containerStatuses":[{"ready":true},{"ready":false}]}}]}
        """,
        kind: .pods
    )
    #expect(pods.first?.namespace == "payments")
    #expect(pods.first?.status == "Running")
    #expect(pods.first?.detail == "1/2 containers ready")
}

@Test
func awsStructuredOutputParserKeepsAccountAndResourceIdentity() {
    let identity = AWSOutputParser.identity(
        #"{"UserId":"AIDATEST","Account":"123456789012","Arn":"arn:aws:iam::123456789012:role/ops"}"#
    )
    #expect(identity.account == "123456789012")
    let instances = AWSOutputParser.resources(
        """
        {"Reservations":[{"Instances":[{"InstanceId":"i-123","InstanceType":"t4g.small","State":{"Name":"running"},"Placement":{"AvailabilityZone":"ap-southeast-1a"},"PrivateIpAddress":"10.0.0.8","Tags":[{"Key":"Name","Value":"api"}]}]}]}
        """,
        kind: .ec2
    )
    #expect(instances.first?.id == "i-123")
    #expect(instances.first?.name == "api")
    #expect(instances.first?.secondary == "10.0.0.8")
}

@Test
func terraformPlanSummaryIsReviewable() {
    #expect(
        TerraformPlanSummary.extract(
            "Plan: 2 to add, 1 to change, 3 to destroy."
        ) == "+2 ~1 -3"
    )
    #expect(
        TerraformPlanSummary.extract(
            "No changes. Your infrastructure matches the configuration."
        ) == "No changes"
    )
}

@Test
func interactionPolicyRespectsMotionAndContrastPreferences() {
    #expect(AegizInteractionPolicy.minimumPointerTarget == 28)
    #expect(AegizInteractionPolicy.transitionDuration(reduceMotion: true) == 0)
    #expect(AegizInteractionPolicy.transitionDuration(reduceMotion: false) == 0.12)
    #expect(
        AegizInteractionPolicy.hoverOpacity(increasedContrast: true)
            > AegizInteractionPolicy.hoverOpacity(increasedContrast: false)
    )
    #expect(
        AegizInteractionPolicy.selectedOpacity(increasedContrast: true)
            > AegizInteractionPolicy.selectedOpacity(increasedContrast: false)
    )
}
