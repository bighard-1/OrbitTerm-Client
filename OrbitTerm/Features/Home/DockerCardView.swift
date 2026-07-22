import SwiftUI

struct DockerCardView: View {
    let card: DockerContainerCard
    @Environment(\.appThemePalette) private var palette
    @Environment(\.securitySemanticPalette) private var security

    private var presentation: DockerContainerPresentationState {
        DockerContainerPresentationState.resolve(isRunning: card.isRunning, isPaused: card.isPaused)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: presentation.symbol)
                    .foregroundStyle(presentation.themeColor(in: security, fallback: palette).color)
                    .accessibilityLabel(presentation.label)

                Text(card.name)
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(palette.textPrimary.color)
                    .layoutPriority(1)

                Spacer()
            }

            HStack(spacing: 8) {
                DockerContainerStatusBadge(presentation: presentation)
                if !card.runningFor.isEmpty {
                    Text(card.runningFor)
                        .font(.caption)
                        .foregroundStyle(palette.textSecondary.color)
                        .lineLimit(1)
                }
            }

            Text(card.image)
                .font(.subheadline)
                .foregroundStyle(palette.textSecondary.color)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)

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
        .frame(maxWidth: .infinity, alignment: .leading)
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

struct DockerContainerStatusBadge: View {
    let presentation: DockerContainerPresentationState
    @Environment(\.appThemePalette) private var palette
    @Environment(\.securitySemanticPalette) private var security

    var body: some View {
        Text(presentation.label)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                presentation.themeColor(in: security, fallback: palette).color.opacity(0.14),
                in: Capsule()
            )
            .foregroundStyle(presentation.themeColor(in: security, fallback: palette).color)
            .fixedSize(horizontal: true, vertical: false)
    }
}
