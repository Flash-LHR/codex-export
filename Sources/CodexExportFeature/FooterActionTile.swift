import SwiftUI

enum FooterActionAppearance {
    case regular
    case selected
    case upToDate
    case updateAvailable
    case exit
    case secondary
    case prominent
}

enum FooterActionIcon {
    case system(String)
    case asset(String)
}

struct FooterActionTile: View {
    let title: String
    let icon: FooterActionIcon
    let isBusy: Bool
    let appearance: FooterActionAppearance
    let isDisabled: Bool
    let action: () -> Void

    @State private var isHovering = false

    init(
        title: String,
        icon: FooterActionIcon,
        isBusy: Bool,
        appearance: FooterActionAppearance,
        isDisabled: Bool,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.icon = icon
        self.isBusy = isBusy
        self.appearance = appearance
        self.isDisabled = isDisabled
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            VStack(spacing: 3) {
                if isBusy {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    iconView
                        .frame(width: 18, height: 16)
                }

                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(textColor)
                    .lineLimit(1)
                    .frame(height: 24)
            }
        }
        .buttonStyle(
            FooterActionButtonStyle(
                appearance: appearance,
                isHovering: isHovering
            )
        )
        .disabled(isDisabled)
        .onHover { isHovering = $0 }
        .accessibilityLabel(isBusy ? "正在\(title)" : title)
    }

    @ViewBuilder
    private var iconView: some View {
        switch icon {
        case let .system(name):
            Image(systemName: name)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(iconColor)
        case let .asset(name):
            Image(name, bundle: .main)
                .resizable()
                .renderingMode(.template)
                .scaledToFit()
                .frame(width: 16, height: 16)
                .foregroundStyle(iconColor)
        }
    }

    private var iconColor: Color {
        guard !isDisabled else { return .secondary }
        switch appearance {
        case .selected:
            return .accentColor
        case .upToDate:
            return Color(nsColor: .systemGreen)
        case .updateAvailable:
            return Color(nsColor: .systemOrange)
        case .exit where isHovering:
            return .red
        case .secondary:
            return .primary
        case .prominent:
            return .white
        case .regular, .exit:
            return .secondary
        }
    }

    private var textColor: Color {
        guard !isDisabled else { return .secondary }
        switch appearance {
        case .secondary, .selected, .upToDate, .updateAvailable:
            return .primary
        case .prominent:
            return .white
        case .exit where isHovering:
            return .red
        case .regular, .exit:
            return .secondary
        }
    }
}

private struct FooterActionButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let appearance: FooterActionAppearance
    let isHovering: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .frame(maxWidth: .infinity)
            .frame(height: 58)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(backgroundColor)
            )
            .overlay {
                if isHovering && isEnabled && appearance == .prominent {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.white.opacity(0.08))
                }
            }
            .shadow(
                color: appearance == .prominent && isEnabled
                    ? Color.accentColor.opacity(0.16)
                    : .clear,
                radius: 4,
                y: 1
            )
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.985 : 1)
            .opacity(isEnabled ? 1 : 0.62)
            .animation(
                reduceMotion ? nil : .easeOut(duration: 0.12),
                value: configuration.isPressed
            )
    }

    private var backgroundColor: Color {
        switch appearance {
        case .regular, .selected, .exit:
            if appearance == .exit && isHovering && isEnabled {
                return Color.red.opacity(0.10)
            }
            return Color.primary.opacity(isHovering ? 0.12 : 0.085)
        case .upToDate:
            return Color(nsColor: .systemGreen).opacity(
                isHovering && isEnabled ? 0.14 : 0.08
            )
        case .updateAvailable:
            return Color(nsColor: .systemOrange).opacity(
                isHovering && isEnabled ? 0.17 : 0.10
            )
        case .secondary:
            return Color.primary.opacity(isHovering ? 0.14 : 0.105)
        case .prominent:
            return .accentColor
        }
    }
}
