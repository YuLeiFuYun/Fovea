import SwiftUI

struct WorkbenchActionButtonStyle: ButtonStyle {
    enum Emphasis: Equatable {
        case primary
        case secondary
        case quiet
    }

    let emphasis: Emphasis

    init(_ emphasis: Emphasis = .secondary) {
        self.emphasis = emphasis
    }

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.semibold))
            .multilineTextAlignment(.center)
            .lineLimit(2)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, minHeight: WorkbenchDesign.controlMinimumHeight)
            .padding(.horizontal, 14)
            .foregroundStyle(foregroundColor)
            .background(backgroundColor.opacity(configuration.isPressed ? 0.72 : 1))
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay {
                if emphasis != .primary {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(Color.primary.opacity(0.12), lineWidth: 1)
                }
            }
            .contentShape(Rectangle())
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }

    private var foregroundColor: Color {
        emphasis == .primary ? .white : .primary
    }

    private var backgroundColor: Color {
        switch emphasis {
        case .primary:
            return .accentColor
        case .secondary:
            return Color(.secondarySystemBackground)
        case .quiet:
            return Color(.tertiarySystemFill)
        }
    }
}
