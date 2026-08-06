import AppKit
import GhosttyKit
import SwiftUI

private let aegizGhosttyWakeupCallback: ghostty_runtime_wakeup_cb = { _ in
    GhosttyRuntime.shared.requestTick()
}

private let aegizGhosttyActionCallback: ghostty_runtime_action_cb = { _, _, action in
    switch action.tag {
    case GHOSTTY_ACTION_START_SEARCH, GHOSTTY_ACTION_END_SEARCH,
         GHOSTTY_ACTION_SEARCH_TOTAL, GHOSTTY_ACTION_SEARCH_SELECTED:
        true
    default:
        false
    }
}
private let aegizGhosttyReadClipboardCallback: ghostty_runtime_read_clipboard_cb = {
    _, _, _ in false
}
private let aegizGhosttyConfirmReadClipboardCallback:
    ghostty_runtime_confirm_read_clipboard_cb = { _, _, _, _ in }
private let aegizGhosttyWriteClipboardCallback: ghostty_runtime_write_clipboard_cb = {
    _, _, _, _, _ in
}
private let aegizGhosttyCloseSurfaceCallback: ghostty_runtime_close_surface_cb = { _, _ in }

/// Prevents libghostty's renderer and IO threads from flooding the AppKit
/// event queue with equivalent ticks. A new wakeup that arrives while the
/// current tick is executing is allowed to schedule the next drain.
final class GhosttyWakeupGate: @unchecked Sendable {
    private let lock = NSLock()
    private var scheduled = false

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !scheduled else { return false }
        scheduled = true
        return true
    }

    func release() {
        lock.lock()
        scheduled = false
        lock.unlock()
    }
}

struct GhosttyFramebufferMetrics: Equatable, Sendable {
    let scale: Double
    let width: UInt32
    let height: UInt32

    static func make(bounds: NSRect, scale: CGFloat) -> Self? {
        guard bounds.width > 0, bounds.height > 0, scale > 0 else { return nil }
        return Self(
            scale: Double(scale),
            width: UInt32(max(1, (bounds.width * scale).rounded())),
            height: UInt32(max(1, (bounds.height * scale).rounded()))
        )
    }
}

enum GhosttyTickThrottle {
    static let minimumInterval: TimeInterval = 1.0 / 120.0

    static func delay(now: TimeInterval, lastTick: TimeInterval) -> TimeInterval {
        let remaining = max(0, minimumInterval - max(0, now - lastTick))
        return remaining < 0.000_001 ? 0 : remaining
    }
}

enum GhosttySurfacePresentation {
    static func isVisible(
        windowAttached: Bool,
        windowVisible: Bool,
        windowMiniaturized: Bool,
        hidden: Bool
    ) -> Bool {
        windowAttached && windowVisible && !windowMiniaturized && !hidden
    }
}

enum EmbeddedTerminalError: LocalizedError {
    case initializationFailed
    case invalidHostAlias
    case surfaceCreationFailed

    var errorDescription: String? {
        switch self {
        case .initializationFailed:
            "GhosttyKit could not initialize."
        case .invalidHostAlias:
            "The SSH alias contains characters that are unsafe for an embedded terminal command."
        case .surfaceCreationFailed:
            "GhosttyKit could not create a terminal surface."
        }
    }
}

/// Owns Ghostty's process-wide runtime. The terminal surface itself remains an
/// AppKit view so libghostty can attach its Metal-backed layer directly.
final class GhosttyRuntime: @unchecked Sendable {
    static let shared = GhosttyRuntime()

    private var app: ghostty_app_t?
    private var config: ghostty_config_t?
    private var attemptedInitialization = false
    private let wakeupGate = GhosttyWakeupGate()
    private var applicationObservers: [NSObjectProtocol] = []
    private var lastTickUptime: TimeInterval = 0

    private init() {}

    @MainActor
    func application(additionalConfigPath: String? = nil) throws -> ghostty_app_t {
        let application = NSApplication.shared
        if let app {
            return app
        }
        guard !attemptedInitialization else {
            throw EmbeddedTerminalError.initializationFailed
        }
        attemptedInitialization = true

        guard ghostty_init(UInt(CommandLine.argc), CommandLine.unsafeArgv) == GHOSTTY_SUCCESS else {
            throw EmbeddedTerminalError.initializationFailed
        }
        guard let config = ghostty_config_new() else {
            throw EmbeddedTerminalError.initializationFailed
        }
        ghostty_config_load_default_files(config)
        ghostty_config_load_recursive_files(config)
        if let additionalConfigPath {
            additionalConfigPath.withCString {
                ghostty_config_load_file(config, $0)
            }
        }
        ghostty_config_finalize(config)

        var runtime = ghostty_runtime_config_s(
            userdata: nil,
            supports_selection_clipboard: false,
            wakeup_cb: aegizGhosttyWakeupCallback,
            action_cb: aegizGhosttyActionCallback,
            read_clipboard_cb: aegizGhosttyReadClipboardCallback,
            confirm_read_clipboard_cb: aegizGhosttyConfirmReadClipboardCallback,
            write_clipboard_cb: aegizGhosttyWriteClipboardCallback,
            close_surface_cb: aegizGhosttyCloseSurfaceCallback
        )
        runtime.userdata = Unmanaged.passUnretained(self).toOpaque()
        guard let app = ghostty_app_new(&runtime, config) else {
            ghostty_config_free(config)
            throw EmbeddedTerminalError.initializationFailed
        }
        self.config = config
        self.app = app
        ghostty_app_set_focus(app, application.isActive)
        observeApplicationFocus(application)
        return app
    }

    func requestTick() {
        guard wakeupGate.claim() else { return }
        DispatchQueue.main.async { [self] in
            scheduleClaimedTick()
        }
    }

    @MainActor private func scheduleClaimedTick() {
        let now = ProcessInfo.processInfo.systemUptime
        let delay = GhosttyTickThrottle.delay(now: now, lastTick: lastTickUptime)
        guard delay > 0 else {
            performClaimedTick()
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [self] in
            performClaimedTick()
        }
    }

    @MainActor private func performClaimedTick() {
        lastTickUptime = ProcessInfo.processInfo.systemUptime
        wakeupGate.release()
        tick()
    }

    @MainActor private func tick() {
        guard let app else { return }
        ghostty_app_tick(app)
    }

    @MainActor private func observeApplicationFocus(_ application: NSApplication) {
        guard applicationObservers.isEmpty else { return }
        let center = NotificationCenter.default
        applicationObservers = [
            center.addObserver(
                forName: NSApplication.didBecomeActiveNotification,
                object: application,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.setApplicationFocus(true) }
            },
            center.addObserver(
                forName: NSApplication.didResignActiveNotification,
                object: application,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.setApplicationFocus(false) }
            },
        ]
    }

    @MainActor private func setApplicationFocus(_ focused: Bool) {
        guard let app else { return }
        ghostty_app_set_focus(app, focused)
    }
}

struct EmbeddedGhosttySurface: NSViewRepresentable {
    let configuration: TerminalLaunchConfiguration

    func makeNSView(context: Context) -> GhosttyTerminalContainerView {
        GhosttyTerminalContainerView(configuration: configuration)
    }

    func updateNSView(_ view: GhosttyTerminalContainerView, context: Context) {
        view.load(configuration: configuration)
    }
}

@MainActor
final class TerminalSessionController {
    let configuration: TerminalLaunchConfiguration
    let view: GhosttyTerminalContainerView

    init(configuration: TerminalLaunchConfiguration) {
        self.configuration = configuration
        self.view = GhosttyTerminalContainerView(configuration: configuration)
    }

    func attach(to mount: NSView) {
        guard view.superview !== mount else { return }
        view.removeFromSuperview()
        view.translatesAutoresizingMaskIntoConstraints = false
        mount.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: mount.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: mount.trailingAnchor),
            view.topAnchor.constraint(equalTo: mount.topAnchor),
            view.bottomAnchor.constraint(equalTo: mount.bottomAnchor),
        ])
        view.requestTerminalFocus()
    }
}

struct ManagedGhosttySurface: NSViewRepresentable {
    let controller: TerminalSessionController

    func makeNSView(context: Context) -> NSView {
        let mount = NSView()
        controller.attach(to: mount)
        return mount
    }

    func updateNSView(_ mount: NSView, context: Context) {
        controller.attach(to: mount)
    }

    static func dismantleNSView(_ mount: NSView, coordinator: Void) {
        mount.subviews.forEach { $0.removeFromSuperview() }
    }
}

final class GhosttyTerminalContainerView: NSView {
    private var loadedConfiguration: TerminalLaunchConfiguration?
    private var terminalView: EmbeddedGhosttyNSView?

    init(configuration: TerminalLaunchConfiguration) {
        super.init(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        load(configuration: configuration)
    }

    required init?(coder: NSCoder) {
        nil
    }

    func load(configuration: TerminalLaunchConfiguration) {
        guard configuration != loadedConfiguration else { return }
        loadedConfiguration = configuration
        terminalView?.removeFromSuperview()
        terminalView = nil
        subviews.forEach { $0.removeFromSuperview() }

        do {
            let app = try GhosttyRuntime.shared.application(
                additionalConfigPath: AegizTerminalIdentity.preparedConfigurationPath()
            )
            let terminal = try EmbeddedGhosttyNSView(app: app, configuration: configuration)
            terminal.translatesAutoresizingMaskIntoConstraints = false
            addSubview(terminal)
            NSLayoutConstraint.activate([
                terminal.leadingAnchor.constraint(equalTo: leadingAnchor),
                terminal.trailingAnchor.constraint(equalTo: trailingAnchor),
                terminal.topAnchor.constraint(equalTo: topAnchor),
                terminal.bottomAnchor.constraint(equalTo: bottomAnchor),
            ])
            terminalView = terminal
            requestTerminalFocus()
        } catch {
            let label = NSTextField(wrappingLabelWithString: error.localizedDescription)
            label.alignment = .center
            label.textColor = .secondaryLabelColor
            label.translatesAutoresizingMaskIntoConstraints = false
            addSubview(label)
            NSLayoutConstraint.activate([
                label.centerXAnchor.constraint(equalTo: centerXAnchor),
                label.centerYAnchor.constraint(equalTo: centerYAnchor),
                label.widthAnchor.constraint(lessThanOrEqualToConstant: 460),
            ])
        }
    }

    func requestTerminalFocus(attemptsRemaining: Int = 4) {
        DispatchQueue.main.async { [weak self] in
            guard let self, let terminal = self.terminalView else { return }
            if let window = terminal.window, window.isVisible {
                window.makeFirstResponder(terminal)
            } else if attemptsRemaining > 0, self.superview != nil {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.025) { [weak self] in
                    self?.requestTerminalFocus(attemptsRemaining: attemptsRemaining - 1)
                }
            }
        }
    }

    var hasTerminalFocus: Bool {
        window?.firstResponder === terminalView
    }
}

private final class GhosttySurfaceHandle: @unchecked Sendable {
    let rawValue: ghostty_surface_t

    init(_ rawValue: ghostty_surface_t) {
        self.rawValue = rawValue
    }

    deinit {
        ghostty_surface_free(rawValue)
    }
}

final class EmbeddedGhosttyNSView: NSView {
    private var surfaceHandle: GhosttySurfaceHandle?
    private var trackingArea: NSTrackingArea?
    private var searchField: NSSearchField?
    private var windowObservers: [NSObjectProtocol] = []
    private var lastFramebufferMetrics: GhosttyFramebufferMetrics?
    private(set) var reportedVisible: Bool?

    override var acceptsFirstResponder: Bool { true }
    private var surface: ghostty_surface_t? { surfaceHandle?.rawValue }
    var isSurfaceReady: Bool { surface != nil }

    @MainActor
    convenience init(
        app: ghostty_app_t,
        configuration: TerminalLaunchConfiguration
    ) throws {
        guard !configuration.command.isEmpty,
              !configuration.validatesSSHHostAlias
                || Self.isSafeHostAlias(configuration.hostAlias)
        else {
            throw EmbeddedTerminalError.invalidHostAlias
        }
        try self.init(
            app: app,
            command: configuration.command,
            workingDirectory: configuration.localWorkingDirectory,
            environment: configuration.environment,
            fontSize: configuration.fontSize,
            initialInput: configuration.initialInput
        )
    }

    @MainActor
    init(
        app: ghostty_app_t,
        command: String,
        workingDirectory: String = "",
        environment: [TerminalEnvironmentVariable] = [],
        fontSize: Double = 0,
        initialInput: String = ""
    ) throws {
        super.init(frame: NSRect(x: 0, y: 0, width: 800, height: 600))

        var configuration = ghostty_surface_config_new()
        configuration.userdata = Unmanaged.passUnretained(self).toOpaque()
        configuration.platform_tag = GHOSTTY_PLATFORM_MACOS
        configuration.platform = ghostty_platform_u(
            macos: ghostty_platform_macos_s(
                nsview: Unmanaged.passUnretained(self).toOpaque()
            )
        )
        configuration.scale_factor = Double(NSScreen.main?.backingScaleFactor ?? 2)
        configuration.context = GHOSTTY_SURFACE_CONTEXT_TAB
        configuration.font_size = Float(fontSize)

        let commandPointer = strdup(command)
        let workingDirectoryPointer = workingDirectory.isEmpty ? nil : strdup(workingDirectory)
        let initialInputPointer = initialInput.isEmpty ? nil : strdup(initialInput)
        var environmentPointers: [(UnsafeMutablePointer<CChar>, UnsafeMutablePointer<CChar>)] = []
        var environmentValues: [ghostty_env_var_s] = []
        for variable in environment {
            guard let key = strdup(variable.name), let value = strdup(variable.value) else {
                environmentPointers.forEach {
                    free($0.0)
                    free($0.1)
                }
                free(commandPointer)
                free(workingDirectoryPointer)
                free(initialInputPointer)
                throw EmbeddedTerminalError.surfaceCreationFailed
            }
            environmentPointers.append((key, value))
            environmentValues.append(ghostty_env_var_s(key: key, value: value))
        }
        defer {
            environmentPointers.forEach {
                free($0.0)
                free($0.1)
            }
            free(commandPointer)
            free(workingDirectoryPointer)
            free(initialInputPointer)
        }
        configuration.command = UnsafePointer(commandPointer)
        configuration.working_directory = UnsafePointer(workingDirectoryPointer)
        configuration.initial_input = UnsafePointer(initialInputPointer)

        let createdSurface = environmentValues.withUnsafeMutableBufferPointer { buffer in
            configuration.env_vars = buffer.baseAddress
            configuration.env_var_count = buffer.count
            return ghostty_surface_new(app, &configuration)
        }
        guard let createdSurface else {
            throw EmbeddedTerminalError.surfaceCreationFailed
        }
        self.surfaceHandle = GhosttySurfaceHandle(createdSurface)
        updateSurfaceMetrics()
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted, let surface {
            ghostty_surface_set_focus(surface, true)
        }
        return accepted
    }

    override func resignFirstResponder() -> Bool {
        let accepted = super.resignFirstResponder()
        if accepted, let surface {
            ghostty_surface_set_focus(surface, false)
        }
        return accepted
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        observeWindowVisibility()
        updateSurfaceMetrics()
        updateSurfaceVisibility()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateSurfaceMetrics()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateSurfaceMetrics()
        layoutSearchField()
    }

    override func viewDidHide() {
        super.viewDidHide()
        updateSurfaceVisibility()
    }

    override func viewDidUnhide() {
        super.viewDidUnhide()
        updateSurfaceVisibility()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let next = NSTrackingArea(
            rect: bounds,
            options: [.activeInKeyWindow, .inVisibleRect, .mouseMoved],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(next)
        trackingArea = next
    }

    override func keyDown(with event: NSEvent) {
        _ = sendKey(event, action: event.isARepeat ? GHOSTTY_ACTION_REPEAT : GHOSTTY_ACTION_PRESS)
    }

    override func keyUp(with event: NSEvent) {
        _ = sendKey(event, action: GHOSTTY_ACTION_RELEASE)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
              let character = event.charactersIgnoringModifiers?.lowercased()
        else {
            return super.performKeyEquivalent(with: event)
        }
        switch character {
        case "f":
            beginSearch()
            return true
        case "v":
            guard let value = NSPasteboard.general.string(forType: .string) else { return true }
            sendText(value)
            return true
        case "c":
            return copySelection() || super.performKeyEquivalent(with: event)
        default:
            return super.performKeyEquivalent(with: event)
        }
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        sendMousePosition(event)
        sendMouseButton(event, state: GHOSTTY_MOUSE_PRESS, button: GHOSTTY_MOUSE_LEFT)
    }

    override func mouseUp(with event: NSEvent) {
        sendMousePosition(event)
        sendMouseButton(event, state: GHOSTTY_MOUSE_RELEASE, button: GHOSTTY_MOUSE_LEFT)
    }

    override func rightMouseDown(with event: NSEvent) {
        sendMousePosition(event)
        sendMouseButton(event, state: GHOSTTY_MOUSE_PRESS, button: GHOSTTY_MOUSE_RIGHT)
    }

    override func rightMouseUp(with event: NSEvent) {
        sendMousePosition(event)
        sendMouseButton(event, state: GHOSTTY_MOUSE_RELEASE, button: GHOSTTY_MOUSE_RIGHT)
    }

    override func otherMouseDown(with event: NSEvent) {
        sendMousePosition(event)
        sendMouseButton(event, state: GHOSTTY_MOUSE_PRESS, button: GHOSTTY_MOUSE_MIDDLE)
    }

    override func otherMouseUp(with event: NSEvent) {
        sendMousePosition(event)
        sendMouseButton(event, state: GHOSTTY_MOUSE_RELEASE, button: GHOSTTY_MOUSE_MIDDLE)
    }

    override func mouseMoved(with event: NSEvent) {
        sendMousePosition(event)
    }

    override func mouseDragged(with event: NSEvent) {
        sendMousePosition(event)
    }

    override func rightMouseDragged(with event: NSEvent) {
        sendMousePosition(event)
    }

    override func otherMouseDragged(with event: NSEvent) {
        sendMousePosition(event)
    }

    override func scrollWheel(with event: NSEvent) {
        guard let surface else { return }
        // libghostty needs these bits to distinguish trackpad pixels from
        // mouse-wheel lines; omitting them makes a trackpad scroll too far.
        let multiplier = event.hasPreciseScrollingDeltas ? 0.65 : 0.70
        ghostty_surface_mouse_scroll(
            surface,
            Double(event.scrollingDeltaX) * multiplier,
            Double(event.scrollingDeltaY) * multiplier,
            Self.ghosttyScrollModifiers(for: event)
        )
    }

    override func cancelOperation(_ sender: Any?) {
        guard searchField?.isHidden == false else {
            super.cancelOperation(sender)
            return
        }
        endSearch()
    }

    private func updateSurfaceMetrics() {
        guard let surface else { return }
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        guard let metrics = GhosttyFramebufferMetrics.make(bounds: bounds, scale: scale),
              metrics != lastFramebufferMetrics
        else {
            return
        }
        let previous = lastFramebufferMetrics
        lastFramebufferMetrics = metrics
        if previous?.scale != metrics.scale {
            ghostty_surface_set_content_scale(surface, metrics.scale, metrics.scale)
            layer?.contentsScale = metrics.scale
        }
        if previous?.width != metrics.width || previous?.height != metrics.height {
            ghostty_surface_set_size(surface, metrics.width, metrics.height)
        }
    }

    private func observeWindowVisibility() {
        let center = NotificationCenter.default
        windowObservers.forEach(center.removeObserver)
        windowObservers.removeAll(keepingCapacity: true)
        guard let window else { return }
        for name in [
            NSWindow.didChangeOcclusionStateNotification,
            NSWindow.didMiniaturizeNotification,
            NSWindow.didDeminiaturizeNotification,
            NSWindow.didBecomeKeyNotification,
        ] {
            windowObservers.append(
                center.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated {
                        self?.updateSurfaceVisibility()
                    }
                }
            )
        }
    }

    private func updateSurfaceVisibility() {
        guard let surface else { return }
        let visible = Self.presentationVisibility(
            windowAttached: window != nil,
            windowVisible: window?.isVisible == true,
            windowMiniaturized: window?.isMiniaturized == true,
            hidden: isHiddenOrHasHiddenAncestor
        )
        guard visible != reportedVisible else { return }
        reportedVisible = visible
        ghostty_surface_set_occlusion(surface, visible)
    }

    private func sendKey(_ event: NSEvent, action: ghostty_input_action_e) -> Bool {
        guard let surface else { return false }
        var key = ghostty_input_key_s()
        key.action = action
        key.keycode = UInt32(event.keyCode)
        key.mods = Self.ghosttyModifiers(event.modifierFlags)
        key.consumed_mods = Self.ghosttyModifiers(
            event.modifierFlags.subtracting([.control, .command])
        )
        key.composing = false
        if let scalar = event.characters(byApplyingModifiers: [])?.unicodeScalars.first {
            key.unshifted_codepoint = scalar.value
        }

        guard action != GHOSTTY_ACTION_RELEASE,
              let text = Self.terminalText(for: event),
              !text.isEmpty
        else {
            return ghostty_surface_key(surface, key)
        }
        return text.withCString { pointer in
            key.text = pointer
            return ghostty_surface_key(surface, key)
        }
    }

    private func sendText(_ value: String) {
        guard let surface, !value.isEmpty else { return }
        value.withCString { pointer in
            ghostty_surface_text(surface, pointer, UInt(value.utf8.count))
        }
    }

    private func beginSearch() {
        _ = performBindingAction("start_search")
        let field = searchField ?? makeSearchField()
        field.isHidden = false
        layoutSearchField()
        window?.makeFirstResponder(field)
        field.selectText(nil)
    }

    private func endSearch() {
        _ = performBindingAction("end_search")
        searchField?.isHidden = true
        window?.makeFirstResponder(self)
    }

    private func makeSearchField() -> NSSearchField {
        let field = NSSearchField()
        field.placeholderString = "Find in terminal"
        field.sendsSearchStringImmediately = true
        field.target = self
        field.action = #selector(updateSearch(_:))
        field.autoresizingMask = [.minXMargin, .minYMargin]
        addSubview(field)
        searchField = field
        return field
    }

    @objc private func updateSearch(_ sender: NSSearchField) {
        _ = performBindingAction("search:\(sender.stringValue)")
    }

    private func layoutSearchField() {
        guard let searchField, !searchField.isHidden else { return }
        searchField.frame = NSRect(
            x: max(12, bounds.maxX - 252),
            y: max(8, bounds.maxY - 40),
            width: min(240, max(120, bounds.width - 24)),
            height: 28
        )
    }

    @discardableResult
    private func performBindingAction(_ action: String) -> Bool {
        guard let surface else { return false }
        return action.withCString { pointer in
            ghostty_surface_binding_action(surface, pointer, UInt(action.utf8.count))
        }
    }

    private func copySelection() -> Bool {
        guard let surface else { return false }
        var text = ghostty_text_s()
        guard ghostty_surface_read_selection(surface, &text) else { return false }
        defer { ghostty_surface_free_text(surface, &text) }
        guard let pointer = text.text, text.text_len > 0 else { return false }
        let value = String(
            decoding: UnsafeBufferPointer(
                start: UnsafeRawPointer(pointer).assumingMemoryBound(to: UInt8.self),
                count: Int(text.text_len)
            ),
            as: UTF8.self
        )
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
        return true
    }

    private func sendMouseButton(
        _ event: NSEvent,
        state: ghostty_input_mouse_state_e,
        button: ghostty_input_mouse_button_e
    ) {
        guard let surface else { return }
        _ = ghostty_surface_mouse_button(
            surface,
            state,
            button,
            Self.ghosttyModifiers(event.modifierFlags)
        )
    }

    private func sendMousePosition(_ event: NSEvent) {
        guard let surface else { return }
        let point = convert(event.locationInWindow, from: nil)
        ghostty_surface_mouse_pos(
            surface,
            Double(point.x),
            Double(bounds.height - point.y),
            Self.ghosttyModifiers(event.modifierFlags)
        )
    }

    private static func terminalText(for event: NSEvent) -> String? {
        guard let characters = event.characters else { return nil }
        if characters.count == 1, let scalar = characters.unicodeScalars.first {
            if scalar.value < 0x20 {
                return event.characters(byApplyingModifiers: event.modifierFlags.subtracting(.control))
            }
            if (0xF700...0xF8FF).contains(scalar.value) {
                return nil
            }
        }
        return characters
    }

    private static func ghosttyModifiers(_ flags: NSEvent.ModifierFlags) -> ghostty_input_mods_e {
        var raw = GHOSTTY_MODS_NONE.rawValue
        if flags.contains(.shift) { raw |= GHOSTTY_MODS_SHIFT.rawValue }
        if flags.contains(.control) { raw |= GHOSTTY_MODS_CTRL.rawValue }
        if flags.contains(.option) { raw |= GHOSTTY_MODS_ALT.rawValue }
        if flags.contains(.command) { raw |= GHOSTTY_MODS_SUPER.rawValue }
        if flags.contains(.capsLock) { raw |= GHOSTTY_MODS_CAPS.rawValue }
        return ghostty_input_mods_e(raw)
    }

    private static func ghosttyScrollModifiers(for event: NSEvent) -> ghostty_input_scroll_mods_t {
        let precision = event.hasPreciseScrollingDeltas ? 1 : 0
        let momentum = Int32(event.momentumPhase.rawValue) << 1
        return ghostty_input_scroll_mods_t(Int32(precision) | momentum)
    }

    nonisolated static func presentationVisibility(
        windowAttached: Bool,
        windowVisible: Bool,
        windowMiniaturized: Bool,
        hidden: Bool
    ) -> Bool {
        GhosttySurfacePresentation.isVisible(
            windowAttached: windowAttached,
            windowVisible: windowVisible,
            windowMiniaturized: windowMiniaturized,
            hidden: hidden
        )
    }

    nonisolated static func isSafeHostAlias(_ alias: String) -> Bool {
        guard !alias.isEmpty, alias.utf8.count <= 253, !alias.hasPrefix("-") else {
            return false
        }
        return alias.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.contains($0) || ".-_".unicodeScalars.contains($0)
        }
    }
}
