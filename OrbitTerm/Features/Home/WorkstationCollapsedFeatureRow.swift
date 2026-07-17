import SwiftUI

struct WorkstationCollapsedFeatureRow: View {
    @Environment(\.appThemePalette) private var palette
    let title: String
    let onShow: () -> Void

    var body: some View {
        HStack {
            Text("\(title) 已隐藏")
                .font(.caption)
                .foregroundStyle(palette.textSecondary.color)
            Spacer()
            Button("显示") { onShow() }
                .buttonStyle(.bordered)
        }
        .padding(10)
        .themedGlassSurface()
    }
}

struct WorkstationRightRailView: View {
    let onExpand: () -> Void

    var body: some View {
        VStack {
            Button(action: onExpand) {
                Image(systemName: "sidebar.right")
                    .rotationEffect(.degrees(180))
            }
            .buttonStyle(.borderless)
            .padding(.top, 12)
            Spacer()
        }
    }
}
