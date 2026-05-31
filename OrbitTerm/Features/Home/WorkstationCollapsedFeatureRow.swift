import SwiftUI

struct WorkstationCollapsedFeatureRow: View {
    let title: String
    let onShow: () -> Void

    var body: some View {
        HStack {
            Text("\(title) 已隐藏")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Button("显示") { onShow() }
                .buttonStyle(.bordered)
        }
        .padding(10)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
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
