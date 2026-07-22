import SwiftUI

struct AppChromeBackground: View {
    @Environment(\.appThemePalette) private var palette
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    var body: some View {
        GeometryReader { bounds in
            ZStack {
                LinearGradient(
                    colors: [
                        palette.pageBackground.color,
                        palette.backgroundGlowPrimary.color.opacity(0.18),
                        palette.surfaceReadable.color
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                if !reduceTransparency {
                    Circle()
                        .fill(palette.backgroundGlowPrimary.color)
                        .frame(width: 540, height: 540)
                        .blur(radius: 104)
                        .offset(x: -190, y: -260)
                    Circle()
                        .fill(palette.backgroundGlowSecondary.color)
                        .frame(width: 430, height: 430)
                        .blur(radius: 92)
                        .offset(x: 190, y: 270)
                }
            }
            // The glow may extend past the screen, but it must never enlarge the
            // layout proposal of the page layered above it.
            .frame(width: bounds.size.width, height: bounds.size.height)
            .clipped()
        }
        .ignoresSafeArea()
    }
}

struct ThemedGlassSurface: ViewModifier {
    @Environment(\.appThemePalette) private var palette
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    func body(content: Content) -> some View { content.background((AppAccessibilityPresentation.usesOpaqueSurface(reduceTransparency: reduceTransparency) ? palette.surfaceReadable : palette.surfaceGlassStrong).color, in: RoundedRectangle(cornerRadius: 20, style: .continuous)).overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(palette.borderGlass.color, lineWidth: AppAccessibilityPresentation.borderWidth(for: contrast))) }
}
struct ThemedReadableSurface: ViewModifier {
    @Environment(\.appThemePalette) private var palette
    @Environment(\.colorSchemeContrast) private var contrast
    func body(content: Content) -> some View { content.background(palette.surfaceReadable.color, in: RoundedRectangle(cornerRadius: 16, style: .continuous)).overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(palette.borderGlass.color, lineWidth: AppAccessibilityPresentation.borderWidth(for: contrast))) }
}
struct ThemedInputSurface: ViewModifier {
    let focused: Bool
    @Environment(\.appThemePalette) private var palette
    @Environment(\.colorSchemeContrast) private var contrast
    func body(content: Content) -> some View { content.background(palette.surfaceInput.color, in: RoundedRectangle(cornerRadius: 12, style: .continuous)).overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke((focused ? palette.focusRing : palette.borderGlass).color, lineWidth: focused ? max(2, AppAccessibilityPresentation.borderWidth(for: contrast)) : AppAccessibilityPresentation.borderWidth(for: contrast))) }
}
struct ThemedPrimaryButtonStyle: ButtonStyle {
    @Environment(\.appThemePalette) private var palette
    func makeBody(configuration: Configuration) -> some View { configuration.label.foregroundStyle(palette.textOnAccent.color).padding(.horizontal, 16).padding(.vertical, 13).frame(maxWidth: .infinity).background(LinearGradient(colors: [palette.accentPrimary.color, palette.accentSecondary.color], startPoint: .topLeading, endPoint: .bottomTrailing), in: RoundedRectangle(cornerRadius: 14, style: .continuous)).opacity(configuration.isPressed ? 0.86 : 1) }
}
struct ThemedSecondaryButtonStyle: ButtonStyle {
    @Environment(\.appThemePalette) private var palette
    func makeBody(configuration: Configuration) -> some View { configuration.label.foregroundStyle(palette.textPrimary.color).padding(.horizontal, 14).padding(.vertical, 10).background(palette.surfaceInput.color, in: Capsule()).overlay(Capsule().stroke(palette.borderGlass.color)).opacity(configuration.isPressed ? 0.76 : 1) }
}
struct ThemedDivider: View {
    @Environment(\.appThemePalette) private var palette

    var body: some View {
        Rectangle()
            .fill(palette.divider.color)
            .frame(height: 1)
    }
}
struct ThemedToolbarButtonStyle: ButtonStyle {
    let isPrimary: Bool
    @Environment(\.appThemePalette) private var palette

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(isPrimary ? palette.textOnAccent.color : palette.textPrimary.color)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                isPrimary ? palette.accentPrimary.color : palette.surfaceInput.color,
                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(isPrimary ? Color.clear : palette.borderGlass.color, lineWidth: 1)
            }
            .opacity(configuration.isPressed ? 0.78 : 1)
    }
}
struct ThemedFocusBorder: ViewModifier { let focused: Bool; @Environment(\.appThemePalette) private var palette; @Environment(\.colorSchemeContrast) private var contrast; func body(content: Content) -> some View { content.overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(focused ? palette.focusRing.color : Color.clear, lineWidth: max(2, AppAccessibilityPresentation.borderWidth(for: contrast)))) } }
struct SecurityStatusStyle: ViewModifier {
    let kind: SecurityStatusKind
    @Environment(\.securitySemanticPalette) private var security
    func body(content: Content) -> some View { let status = security.presentation(for: kind); content.foregroundStyle(status.color.color).padding(.horizontal, 12).padding(.vertical, 10).background(status.color.color.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous)).overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(status.color.color.opacity(0.35))) }
}
extension View {
    func themedGlassSurface() -> some View { modifier(ThemedGlassSurface()) }
    func themedReadableSurface() -> some View { modifier(ThemedReadableSurface()) }
    func themedInputSurface(focused: Bool = false) -> some View { modifier(ThemedInputSurface(focused: focused)) }
    func securityStatusStyle(_ kind: SecurityStatusKind) -> some View { modifier(SecurityStatusStyle(kind: kind)) }
}
