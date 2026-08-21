import AppKit
import SwiftUI

struct VaultView: View {
    @Bindable var model: AppModel
    @State private var selectedSecretID: String?
    @State private var pendingDeletion: SecretMetadataModel?
    @State private var showingDeleteConfirmation = false

    private var selectedSecret: SecretMetadataModel? {
        model.secrets.first { $0.id == selectedSecretID }
    }

    var body: some View {
        VStack(spacing: 0) {
            vaultHeader
            Divider()
            securityBar
            Divider()
            if model.secrets.isEmpty {
                emptyState
            } else {
                HSplitView {
                    List(model.secrets, selection: $selectedSecretID) { secret in
                        SecretRow(secret: secret)
                            .tag(secret.id)
                            .aegizInteractiveRow(isSelected: selectedSecretID == secret.id)
                            .contextMenu {
                                Button("Reveal") {
                                    Task { await model.revealSecret(secret) }
                                }
                                Divider()
                                Button("Delete", role: .destructive) {
                                    requestDeletion(secret)
                                }
                            }
                    }
                    .listStyle(.inset)
                    .scrollContentBackground(.hidden)
                    .frame(minWidth: 300, idealWidth: 370)
                    secretDetail
                        .frame(minWidth: 300, idealWidth: 390)
                }
            }
        }
        .background(AegizTheme.raised)
        .navigationTitle("Vault")
        .onAppear {
            if selectedSecretID == nil {
                selectedSecretID = model.secrets.first?.id
            }
        }
        .onChange(of: model.secrets) { _, secrets in
            if !secrets.contains(where: { $0.id == selectedSecretID }) {
                selectedSecretID = secrets.first?.id
            }
        }
        .confirmationDialog(
            "Delete this Keychain secret?",
            isPresented: $showingDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete “\(pendingDeletion?.name ?? "Secret")”", role: .destructive) {
                guard let pendingDeletion else { return }
                Task { await model.deleteSecret(pendingDeletion) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes the value from the local Keychain. Aegiz cannot recover it.")
        }
    }

    private var vaultHeader: some View {
        AegizPageHeader(
            "Local Vault",
            subtitle: "Secret values stay in macOS Keychain and never sync through Aegiz",
            symbol: "key.horizontal.fill"
        ) {
            Button {
                model.beginCreatingSecret()
            } label: {
                Label("New Secret", systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
        }
    }

    private var securityBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.shield.fill")
                .foregroundStyle(.green)
            Text(model.vaultStatus?.masterKeyReady == true ? "Master key ready" : "Preparing vault")
                .font(.system(size: 11, weight: .semibold))
            Text("•")
                .foregroundStyle(.tertiary)
            Text("This Mac only")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Text("•")
                .foregroundStyle(.tertiary)
            Text(
                model.vaultStatus?.userPresenceAvailable == true
                    ? "\(model.vaultStatus?.authenticationLabel ?? "Authentication") available"
                    : "Password authentication available"
            )
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            Spacer()
            Picker(
                "Auto-lock",
                selection: Binding(
                    get: { model.vaultAutoLockMinutes },
                    set: { model.setVaultAutoLock(minutes: $0) }
                )
            ) {
                Text("1 min").tag(1)
                Text("5 min").tag(5)
                Text("15 min").tag(15)
                Text("30 min").tag(30)
            }
            .labelsHidden()
            .frame(width: 82)
            .help("Lock after inactivity")
            Button {
                if model.vaultIsLocked {
                    Task { await model.unlockVault() }
                } else {
                    model.lockVault()
                }
            } label: {
                Label(
                    model.vaultIsLocked ? "Unlock" : "Lock",
                    systemImage: model.vaultIsLocked ? "lock.fill" : "lock.open.fill"
                )
            }
            .buttonStyle(.borderless)
            Button {
                if let guide = Bundle.main.url(
                    forResource: "RECOVERY",
                    withExtension: "md"
                ) {
                    NSWorkspace.shared.open(guide)
                } else {
                    model.notice = "This preview build does not include the private recovery guide."
                }
            } label: {
                Image(systemName: "lifepreserver")
            }
            .buttonStyle(.borderless)
            .aegizIconAction(
                "Open recovery guide",
                help: "Open migration and recovery guide"
            )
            Text("\(model.secrets.count) references")
                .font(.system(size: 10).monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .frame(height: 36)
        .background(AegizTheme.canvas.opacity(0.55))
    }

    private var emptyState: some View {
        AegizWorkspaceStateView(
            "No local secrets",
            message: "Store database passwords or API tokens in your local login Keychain. Aegiz metadata and logs never contain their values.",
            symbol: "key.horizontal"
        ) {
            Button("Create Secret") {
                model.beginCreatingSecret()
            }
            .buttonStyle(.borderedProminent)
        }
    }

    @ViewBuilder
    private var secretDetail: some View {
        if let secret = selectedSecret {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 10) {
                    Image(systemName: secret.kind.symbol)
                        .foregroundStyle(AegizTheme.accent)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(secret.name)
                            .font(.system(size: 17, weight: .semibold))
                        Text(secret.kind.rawValue)
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Edit") {
                        model.beginEditingSecret(secret)
                    }
                }

                LabeledContent("Protection") {
                    Label(
                        secret.requiresUserPresence ? "User presence" : "Mac login",
                        systemImage: secret.requiresUserPresence ? "touchid" : "lock.fill"
                    )
                    .font(.system(size: 11))
                }
                LabeledContent("Created") {
                    Text(secret.createdAt.formatted(date: .abbreviated, time: .shortened))
                        .font(.system(size: 11))
                }
                Divider()

                if model.vaultIsLocked {
                    Button {
                        Task { await model.unlockVault() }
                    } label: {
                        Label("Authenticate and Unlock", systemImage: "lock.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                } else if model.revealedSecretID == secret.id {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Label("Revealed for 30 seconds", systemImage: "eye.fill")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.orange)
                            Spacer()
                            Button("Hide") { model.hideRevealedSecret() }
                                .buttonStyle(.borderless)
                        }
                        Text(String(decoding: model.revealedSecretData, as: UTF8.self))
                            .font(.system(size: 12).monospaced())
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(10)
                            .background(AegizTheme.canvas, in: RoundedRectangle(cornerRadius: 6))
                        Button {
                            copyRevealedValue()
                        } label: {
                            Label("Copy for 30 Seconds", systemImage: "doc.on.doc")
                        }
                    }
                } else {
                    Button {
                        Task { await model.revealSecret(secret) }
                    } label: {
                        Label(
                            secret.requiresUserPresence
                                ? "Authenticate and Reveal"
                                : "Reveal for 30 Seconds",
                            systemImage: secret.requiresUserPresence ? "touchid" : "eye"
                        )
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                }

                Spacer()
                Divider()
                Button("Delete Secret", role: .destructive) {
                    requestDeletion(secret)
                }
            }
            .padding(16)
        } else {
            ContentUnavailableView {
                Label("Select a secret", systemImage: "sidebar.right")
            } description: {
                Text("Reveal and lifecycle controls appear here.")
            }
        }
    }

    private func requestDeletion(_ secret: SecretMetadataModel) {
        pendingDeletion = secret
        showingDeleteConfirmation = true
    }

    private func copyRevealedValue() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(
            String(decoding: model.revealedSecretData, as: UTF8.self),
            forType: .string
        )
        let changeCount = pasteboard.changeCount
        model.notice = "Secret copied. Aegiz will clear it from the pasteboard in 30 seconds."
        Timer.scheduledTimer(withTimeInterval: 30, repeats: false) { _ in
            MainActor.assumeIsolated {
                let currentPasteboard = NSPasteboard.general
                guard currentPasteboard.changeCount == changeCount else { return }
                currentPasteboard.clearContents()
            }
        }
    }
}

private struct SecretRow: View {
    let secret: SecretMetadataModel

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: secret.kind.symbol)
                .foregroundStyle(AegizTheme.accent)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 3) {
                Text(secret.name)
                    .font(.system(size: 12, weight: .medium))
                Text(secret.kind.rawValue)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if secret.requiresUserPresence {
                Image(systemName: "touchid")
                    .foregroundStyle(.secondary)
                    .help("Requires user presence")
            }
        }
        .padding(.vertical, 3)
    }
}

struct NewSecretView: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var model: AppModel
    @State private var draft = SecretDraft()
    @State private var saving = false

    var body: some View {
        VStack(spacing: 0) {
            AegizSheetHeader(
                model.editingSecret == nil ? "New Local Secret" : "Update Local Secret",
                subtitle: "The value is written directly to your macOS login Keychain."
            )
            Divider()
            Form {
                TextField("Name", text: $draft.name)
                Picker("Kind", selection: $draft.kind) {
                    ForEach(SecretKindModel.allCases) { kind in
                        Label(kind.rawValue, systemImage: kind.symbol).tag(kind)
                    }
                }
                SecureField("Value", text: $draft.value)
                Toggle(
                    "Require \(model.vaultStatus?.authenticationLabel ?? "user presence") to reveal",
                    isOn: $draft.requiresUserPresence
                )
                .disabled(model.vaultStatus?.userPresenceAvailable != true)
                Text("Aegiz uses the local login Keychain and does not enable synchronization.")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button(model.editingSecret == nil ? "Save Secret" : "Replace Secret") {
                    saving = true
                    Task {
                        if await model.saveSecret(draft) {
                            draft.value.removeAll(keepingCapacity: false)
                            dismiss()
                        }
                        saving = false
                    }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(
                    saving
                        || draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        || draft.value.isEmpty
                )
            }
            .padding(16)
        }
        .aegizAdaptiveSheet(AegizSheetSizingPolicy.secretEditor)
        .onAppear {
            if let secret = model.editingSecret {
                draft.name = secret.name
                draft.kind = secret.kind
                draft.requiresUserPresence = secret.requiresUserPresence
            } else {
                draft.kind = model.pendingNewSecretKind
            }
            if model.vaultStatus?.userPresenceAvailable != true {
                draft.requiresUserPresence = false
            }
        }
    }
}
