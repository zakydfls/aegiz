import AppKit
import SwiftUI

struct SessionWorkspaceView: View {
    @Bindable var model: AppModel
    @State private var pendingClose: TerminalSessionModel?
    @State private var showingCloseConfirmation = false
    @State private var settingsSession: TerminalSessionModel?

    var body: some View {
        VStack(spacing: 0) {
            if let session = model.selectedTerminalSession {
                sessionToolbar(session)
                Divider()
                sessionTabs
                Divider()
                terminalContent(session)
            } else {
                AegizWorkspaceStateView(
                    "No active session",
                    message: "Double-click a host in Command Center to open an SSH session.",
                    symbol: "terminal"
                ) {
                    Button("Open Command Center") {
                        model.selectedSection = .commandCenter
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        }
        .background(AegizTheme.raised)
        .navigationTitle("Sessions")
        .confirmationDialog(
            "Close this terminal session?",
            isPresented: $showingCloseConfirmation,
            titleVisibility: .visible
        ) {
            Button("Close “\(pendingClose?.hostAlias ?? "Session")”", role: .destructive) {
                guard let pendingClose else { return }
                model.closeTerminalSession(pendingClose)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The PTY and its SSH process will be terminated. Terminal scrollback is not persisted.")
        }
        .sheet(item: $settingsSession) { session in
            TerminalSettingsView(
                hostAlias: session.hostAlias,
                settings: model.terminalSettings(for: session.hostID)
            ) { settings in
                try model.saveTerminalSettings(settings, forHostID: session.hostID)
            }
        }
    }

    private func sessionToolbar(_ session: TerminalSessionModel) -> some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 7)
                    .fill(AegizTheme.Terminal.accent.opacity(0.13))
                Image(systemName: "terminal.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(AegizTheme.Terminal.accent)
            }
            .frame(width: 30, height: 30)

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 7) {
                    Text(session.hostAlias)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(AegizTheme.Terminal.text)
                    Text(session.isLocalProcess ? "LOCAL" : "SSH")
                        .font(.system(size: 8, weight: .bold).monospaced())
                        .foregroundStyle(AegizTheme.Terminal.accent)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(
                            AegizTheme.Terminal.accent.opacity(0.11),
                            in: RoundedRectangle(cornerRadius: 4)
                        )
                }
                Text(session.endpoint)
                    .font(.system(size: 10).monospaced())
                    .foregroundStyle(AegizTheme.Terminal.muted)
                    .lineLimit(1)
            }
            Spacer()

            Label(
                session.isLocalProcess ? "Local process" : "OpenSSH transport",
                systemImage: session.isLocalProcess ? "desktopcomputer" : "lock.fill"
            )
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(AegizTheme.Terminal.muted)

            Menu {
                Button("Split Horizontally") {
                    model.createTerminalSplit(session, axis: .horizontal)
                }
                Button("Split Vertically") {
                    model.createTerminalSplit(session, axis: .vertical)
                }
                if model.splitTerminalSession != nil {
                    Button("Close Split") {
                        model.closeTerminalSplit()
                    }
                }
            } label: {
                Image(systemName: "rectangle.split.2x1")
            }
            .aegizIconAction("Split terminal", help: "Create or close a terminal split")

            Button {
                model.reconnectTerminalSession(session)
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.plain)
            .aegizIconAction("Reconnect", help: "Restart this terminal session")

            Button {
                model.duplicateTerminalSession(session)
            } label: {
                Image(systemName: "plus.square.on.square")
            }
            .buttonStyle(.plain)
            .aegizIconAction("Duplicate", help: "Open another session to this target")

            Menu {
                if !session.isLocalProcess {
                    Button("Session Settings…") {
                        settingsSession = session
                    }
                    Divider()
                }
                Button("Open in Ghostty App") {
                    do {
                        if let executable = session.localExecutable {
                            try TerminalLauncher.open(
                                executable: executable,
                                arguments: session.localArguments ?? []
                            )
                        } else {
                            try TerminalLauncher.open(hostAlias: session.hostAlias)
                        }
                    } catch {
                        model.notice = error.localizedDescription
                    }
                }
                Divider()
                Button("Close Session", role: .destructive) {
                    requestClose(session)
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .aegizIconAction("Session actions", help: "Open session settings and actions")
        }
        .padding(.horizontal, 14)
        .frame(height: 50)
        .background(AegizTheme.Terminal.chrome)
    }

    private var sessionTabs: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 2) {
                ForEach(model.terminalSessions) { session in
                    let isSelected = model.selectedTerminalSessionID == session.id
                    HStack(spacing: 5) {
                        Button {
                            model.selectTerminalSession(session)
                        } label: {
                            HStack(spacing: 6) {
                                Circle()
                                    .fill(
                                        isSelected
                                            ? AegizTheme.accent
                                            : AegizTheme.Terminal.muted.opacity(0.55)
                                    )
                                    .frame(width: 6, height: 6)
                                Text(session.hostAlias)
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundStyle(
                                        isSelected
                                            ? AegizTheme.Terminal.text
                                            : AegizTheme.Terminal.muted
                                    )
                                    .lineLimit(1)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(session.hostAlias)
                        .accessibilityValue(
                            isSelected
                                ? "Selected session"
                                : "Session"
                        )
                        .accessibilityAddTraits(
                            isSelected ? .isSelected : []
                        )
                        Button {
                            requestClose(session)
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 8, weight: .bold))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(AegizTheme.Terminal.muted)
                        .aegizIconAction(
                            "Close \(session.hostAlias)",
                            help: "Close this terminal session"
                        )
                    }
                    .padding(.horizontal, 9)
                    .frame(height: 30)
                    .background(
                        isSelected
                            ? AegizTheme.Terminal.raised
                            : Color.clear,
                        in: RoundedRectangle(cornerRadius: 6)
                    )
                    .overlay(alignment: .bottom) {
                        if isSelected {
                            Capsule()
                                .fill(AegizTheme.Terminal.accent)
                                .frame(height: 2)
                                .padding(.horizontal, 8)
                        }
                    }
                    .aegizHoverBackground(
                        isSelected: isSelected
                    )
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
        }
        .scrollIndicators(.hidden)
        .frame(height: 36)
        .background(AegizTheme.Terminal.chrome)
    }

    @ViewBuilder
    private func terminalContent(_ primary: TerminalSessionModel) -> some View {
        if let secondary = model.splitTerminalSession, secondary.id != primary.id {
            if model.terminalSplitAxis == .horizontal {
                HSplitView {
                    terminalSurface(primary)
                    terminalSurface(secondary)
                }
            } else {
                VSplitView {
                    terminalSurface(primary)
                    terminalSurface(secondary)
                }
            }
        } else {
            terminalSurface(primary)
        }
    }

    private func terminalSurface(_ session: TerminalSessionModel) -> some View {
        VStack(spacing: 0) {
            if model.splitTerminalSession != nil {
                HStack(spacing: 7) {
                    Circle()
                        .fill(
                            model.selectedTerminalSessionID == session.id
                                ? AegizTheme.Terminal.accent
                                : AegizTheme.Terminal.muted.opacity(0.45)
                        )
                        .frame(width: 6, height: 6)
                    Text(session.hostAlias)
                        .font(.system(size: 9, weight: .semibold).monospaced())
                        .foregroundStyle(AegizTheme.Terminal.text)
                    Spacer()
                    Text(session.isLocalProcess ? "LOCAL PTY" : "SSH")
                        .font(.system(size: 8, weight: .medium).monospaced())
                        .foregroundStyle(AegizTheme.Terminal.muted)
                }
                .padding(.horizontal, 10)
                .frame(height: 28)
                .background(AegizTheme.Terminal.raised)
                Divider().overlay(AegizTheme.Terminal.border)
            }

            ManagedGhosttySurface(controller: model.terminalController(for: session))
                .id(session.generation)
                .frame(minWidth: 240, minHeight: 160)
        }
        .background(AegizTheme.Terminal.background)
        .overlay {
            Rectangle()
                .stroke(AegizTheme.Terminal.border, lineWidth: 1)
                .allowsHitTesting(false)
        }
    }

    private func requestClose(_ session: TerminalSessionModel) {
        pendingClose = session
        showingCloseConfirmation = true
    }
}

enum TerminalLauncher {
    static func open(hostAlias: String) throws {
        guard !hostAlias.hasPrefix("-"), !hostAlias.contains("\n") else {
            throw NSError(
                domain: "Aegiz.Terminal",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "The SSH host alias is not safe to launch."]
            )
        }
        let binary = URL(filePath: "/Applications/Ghostty.app/Contents/MacOS/ghostty")
        guard FileManager.default.isExecutableFile(atPath: binary.path) else {
            throw NSError(
                domain: "Aegiz.Terminal",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Ghostty is not installed in /Applications."]
            )
        }
        let process = Process()
        process.executableURL = binary
        process.arguments = ["+new-window", "-e", "/usr/bin/ssh", hostAlias]
        try process.run()
    }

    static func open(executable: String, arguments: [String]) throws {
        guard TerminalLocalCommand.encoded(
            executable: executable,
            arguments: arguments
        ) != nil else {
            throw NSError(
                domain: "Aegiz.Terminal",
                code: 3,
                userInfo: [NSLocalizedDescriptionKey: "The local command is outside Aegiz's trusted boundary."]
            )
        }
        let binary = URL(filePath: "/Applications/Ghostty.app/Contents/MacOS/ghostty")
        guard FileManager.default.isExecutableFile(atPath: binary.path) else {
            throw NSError(
                domain: "Aegiz.Terminal",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Ghostty is not installed in /Applications."]
            )
        }
        let process = Process()
        process.executableURL = binary
        process.arguments = ["+new-window", "-e", executable] + arguments
        try process.run()
    }
}
