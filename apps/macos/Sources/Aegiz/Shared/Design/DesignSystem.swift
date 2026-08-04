import SwiftUI

struct AegizPageHeader<Actions: View>: View {
    let title: String
    let subtitle: String
    let symbol: String
    let actions: Actions

    init(
        _ title: String,
        subtitle: String,
        symbol: String,
        @ViewBuilder actions: @escaping () -> Actions = { EmptyView() }
    ) {
        self.title = title
        self.subtitle = subtitle
        self.symbol = symbol
        self.actions = actions()
    }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                identity
                    .frame(minWidth: 220, alignment: .leading)
                Spacer(minLength: 12)
                actions
                    .fixedSize(horizontal: true, vertical: false)
                    .layoutPriority(1)
            }

            VStack(alignment: .leading, spacing: 8) {
                identity
                actions
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        .padding(.horizontal, AegizTheme.Spacing.section)
        .padding(.vertical, 8)
        .frame(minHeight: 62)
        .background(AegizTheme.raised)
    }

    private var identity: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(AegizTheme.accent)
                .frame(width: 30, height: 30)
                .background(AegizTheme.accent.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 20, weight: .semibold))
                    .accessibilityHeading(.h1)
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

struct AegizSheetHeader<Actions: View>: View {
    let title: String
    let subtitle: String
    let actions: Actions

    init(
        _ title: String,
        subtitle: String,
        @ViewBuilder actions: () -> Actions = { EmptyView() }
    ) {
        self.title = title
        self.subtitle = subtitle
        self.actions = actions()
    }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 16) {
                identity
                Spacer(minLength: 12)
                actions
                    .fixedSize(horizontal: true, vertical: false)
            }

            VStack(alignment: .leading, spacing: 10) {
                identity
                actions
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        .padding(AegizTheme.Spacing.section)
    }

    private var identity: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.title3.weight(.semibold))
                .accessibilityHeading(.h1)
            Text(subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct AegizStatusPill: View {
    let title: String
    let color: Color
    var symbol: String?

    var body: some View {
        HStack(spacing: 5) {
            if let symbol {
                Image(systemName: symbol)
                    .font(.system(size: 9, weight: .bold))
            } else {
                Circle().frame(width: 6, height: 6)
            }
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .lineLimit(1)
        }
        .foregroundStyle(color)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(color.opacity(0.11), in: Capsule())
        .accessibilityElement(children: .combine)
    }
}

struct AegizInspectorSection<Content: View>: View {
    let title: String
    let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct AegizWorkspaceStateView<Actions: View>: View {
    let title: String
    let message: String
    let detail: String?
    let symbol: String
    let tint: Color
    let actions: Actions

    init(
        _ title: String,
        message: String,
        detail: String? = nil,
        symbol: String,
        tint: Color = AegizTheme.accent,
        @ViewBuilder actions: () -> Actions = { EmptyView() }
    ) {
        self.title = title
        self.message = message
        self.detail = detail
        self.symbol = symbol
        self.tint = tint
        self.actions = actions()
    }

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 24)
            VStack(spacing: 14) {
                Image(systemName: symbol)
                    .font(.system(size: 25, weight: .medium))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(tint)
                    .frame(width: 48, height: 48)
                    .background(tint.opacity(0.11), in: RoundedRectangle(cornerRadius: 10))
                    .accessibilityHidden(true)
                VStack(spacing: 6) {
                    Text(title)
                        .font(.system(size: 18, weight: .semibold))
                        .multilineTextAlignment(.center)
                        .textSelection(.enabled)
                    Text(message)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .textSelection(.enabled)
                    if let detail, !detail.isEmpty {
                        Text(detail)
                            .font(.system(size: 10).monospaced())
                            .foregroundStyle(.tertiary)
                            .multilineTextAlignment(.center)
                            .textSelection(.enabled)
                    }
                }
                .frame(maxWidth: 520)
                actions
                    .controlSize(.regular)
            }
            .padding(.horizontal, 28)
            Spacer(minLength: 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(AegizTheme.canvas.opacity(0.22))
        .accessibilityElement(children: .contain)
    }
}

struct AegizCapabilityUnavailableView: View {
    let tool: String
    let diagnostic: String
    let installHint: String
    let symbol: String
    let refresh: () -> Void

    var body: some View {
        AegizWorkspaceStateView(
            "\(tool) is unavailable",
            message: installHint,
            detail: diagnostic,
            symbol: symbol,
            tint: AegizTheme.warning
        ) {
            Button(action: refresh) {
                Label("Check Again", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.borderedProminent)
            .help("Refresh trusted CLI capabilities")
        }
    }
}

private struct AegizInteractiveRowModifier: ViewModifier {
    let isSelected: Bool
    @State private var isHovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var accessibilityContrast

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: AegizTheme.Radius.control)
                    .fill(
                        isSelected
                            ? AegizTheme.selected(increasedContrast: increasedContrast)
                            : isHovered
                                ? AegizTheme.hover(increasedContrast: increasedContrast)
                                : .clear
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: AegizTheme.Radius.control)
                    .stroke(
                        isSelected
                            ? AegizTheme.accent.opacity(0.58)
                            : isHovered ? AegizTheme.subtleBorder : .clear,
                        lineWidth: isSelected ? 1 : 0.8
                    )
            )
            .contentShape(Rectangle())
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
            .accessibilityAddTraits(isSelected ? .isSelected : [])
            .onHover { isHovered = $0 }
            .animation(stateAnimation, value: isHovered)
            .animation(stateAnimation, value: isSelected)
    }

    private var increasedContrast: Bool { accessibilityContrast == .increased }

    private var stateAnimation: Animation? {
        let duration = AegizInteractionPolicy.transitionDuration(reduceMotion: reduceMotion)
        return duration == 0 ? nil : .easeOut(duration: duration)
    }
}

private struct AegizHoverBackgroundModifier: ViewModifier {
    let isSelected: Bool
    @State private var isHovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var accessibilityContrast

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: AegizTheme.Radius.control)
                    .fill(
                        isSelected
                            ? AegizTheme.selected(increasedContrast: increasedContrast)
                            : isHovered
                                ? AegizTheme.hover(increasedContrast: increasedContrast)
                                : .clear
                    )
            )
            .contentShape(Rectangle())
            .accessibilityAddTraits(isSelected ? .isSelected : [])
            .onHover { isHovered = $0 }
            .animation(stateAnimation, value: isHovered)
    }

    private var increasedContrast: Bool { accessibilityContrast == .increased }

    private var stateAnimation: Animation? {
        let duration = AegizInteractionPolicy.transitionDuration(reduceMotion: reduceMotion)
        return duration == 0 ? nil : .easeOut(duration: duration)
    }
}

private struct AegizIconActionModifier: ViewModifier {
    let label: String
    let help: String

    func body(content: Content) -> some View {
        content
            .frame(
                minWidth: AegizInteractionPolicy.minimumPointerTarget,
                minHeight: AegizInteractionPolicy.minimumPointerTarget
            )
            .contentShape(Rectangle())
            .accessibilityLabel(label)
            .help(help)
    }
}

private struct AegizControlSurfaceModifier: ViewModifier {
    let radius: CGFloat

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        content
            .background(AegizTheme.raised, in: shape)
            .overlay(shape.stroke(AegizTheme.subtleBorder, lineWidth: 0.8))
    }
}

extension View {
    func aegizInteractiveRow(isSelected: Bool = false) -> some View {
        modifier(AegizInteractiveRowModifier(isSelected: isSelected))
    }

    func aegizHoverBackground(isSelected: Bool = false) -> some View {
        modifier(AegizHoverBackgroundModifier(isSelected: isSelected))
    }

    func aegizIconAction(_ label: String, help: String? = nil) -> some View {
        modifier(AegizIconActionModifier(label: label, help: help ?? label))
    }

    func aegizAdaptiveSheet(_ size: AegizSheetSize) -> some View {
        frame(
            minWidth: size.minWidth,
            idealWidth: size.idealWidth,
            maxWidth: size.maxWidth,
            minHeight: size.minHeight,
            idealHeight: size.idealHeight,
            maxHeight: size.maxHeight
        )
    }

    func aegizControlSurface(radius: CGFloat = AegizTheme.Radius.control) -> some View {
        modifier(AegizControlSurfaceModifier(radius: radius))
    }
}
