import SwiftUI

struct DockerCardView: View {
    let card: DockerContainerCard
    @Environment(\.appThemePalette) private var palette
    @Environment(\.securitySemanticPalette) private var security

    private var presentation: DockerContainerPresentationState {
        DockerContainerPresentationState.resolve(isRunning: card.isRunning)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 8) {
                Image(systemName: presentation.symbol)
                    .foregroundStyle(presentation.themeColor(in: security, fallback: palette).color)
                    .accessibilityLabel(presentation.label)

                Text(card.name)
                    .font(.headline)
                    .lineLimit(1)
                    .foregroundStyle(palette.textPrimary.color)

                Text(presentation.label)
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(presentation.themeColor(in: security, fallback: palette).color.opacity(0.14), in: Capsule())
                    .foregroundStyle(presentation.themeColor(in: security, fallback: palette).color)

                Spacer()

                Text(card.runningFor.isEmpty ? card.state : card.runningFor)
                    .font(.caption)
                    .foregroundStyle(palette.textSecondary.color)
            }

            Text(card.image)
                .font(.subheadline)
                .foregroundStyle(palette.textSecondary.color)
                .lineLimit(1)

            VStack(alignment: .leading, spacing: 6) {
                metricBar(title: "CPU", value: card.cpuPercent)
                metricBar(title: "内存", value: card.memPercent, subtitle: card.memUsage)
            }

            Text(card.status)
                .font(.caption)
                .foregroundStyle(palette.textSecondary.color)
                .lineLimit(1)
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(card.name)，\(presentation.label)，镜像 \(card.image)")
    }

    private func metricBar(title: String, value: Double, subtitle: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                    .font(.caption2)
                    .foregroundStyle(palette.textSecondary.color)
                Spacer()
                Text(String(format: "%.1f%%", value))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(palette.textSecondary.color)
            }
            ProgressView(value: max(0, min(100, value)), total: 100)
                .tint(palette.accentPrimary.color)
            if let subtitle, !subtitle.isEmpty {
                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(palette.textSecondary.color)
            }
        }
    }
}
