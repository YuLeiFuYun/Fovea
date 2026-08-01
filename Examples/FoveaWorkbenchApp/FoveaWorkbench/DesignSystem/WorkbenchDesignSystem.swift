import SwiftUI

/// Workbench 的共享视觉尺度。页面只能组合这些尺度，不应自行散布魔法数字。
enum WorkbenchDesign {
    static let compactHorizontalPadding: CGFloat = 16
    static let regularHorizontalPadding: CGFloat = 24
    static let sectionSpacing: CGFloat = 24
    static let cardSpacing: CGFloat = 14
    static let compactCardRadius: CGFloat = 18
    static let prominentCardRadius: CGFloat = 24
    static let controlMinimumHeight: CGFloat = 48
    static let compactContentWidth: CGFloat = 680
    static let regularContentWidth: CGFloat = 1_160

    static func horizontalPadding(isRegular: Bool) -> CGFloat {
        isRegular ? regularHorizontalPadding : compactHorizontalPadding
    }

    static func adaptiveColumnCount(
        availableWidth: CGFloat,
        minimumItemWidth: CGFloat,
        spacing: CGFloat = cardSpacing,
        maximum: Int = 4
    ) -> Int {
        guard availableWidth.isFinite, availableWidth > 0,
            minimumItemWidth.isFinite, minimumItemWidth > 0,
            spacing.isFinite, spacing >= 0,
            maximum > 0
        else { return 1 }
        let rawCount = (availableWidth + spacing) / (minimumItemWidth + spacing)
        guard rawCount.isFinite, rawCount > 0 else { return 1 }
        if rawCount >= CGFloat(maximum) { return maximum }
        return max(1, Int(rawCount.rounded(.down)))
    }
}

struct WorkbenchCardModifier: ViewModifier {
    let emphasized: Bool

    func body(content: Content) -> some View {
        content
            .padding(WorkbenchDesign.cardSpacing)
            .background(
                emphasized ? Color(.secondarySystemBackground) : Color(.tertiarySystemBackground),
                in: RoundedRectangle(
                    cornerRadius: emphasized
                        ? WorkbenchDesign.prominentCardRadius
                        : WorkbenchDesign.compactCardRadius,
                    style: .continuous
                )
            )
            .overlay {
                RoundedRectangle(
                    cornerRadius: emphasized
                        ? WorkbenchDesign.prominentCardRadius
                        : WorkbenchDesign.compactCardRadius,
                    style: .continuous
                )
                .stroke(Color.primary.opacity(0.06), lineWidth: 1)
            }
    }
}

extension View {
    func workbenchCard(emphasized: Bool = false) -> some View {
        modifier(WorkbenchCardModifier(emphasized: emphasized))
    }
}
