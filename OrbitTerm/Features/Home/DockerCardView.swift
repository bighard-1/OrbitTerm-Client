import SwiftUI

struct DockerCardView: View {
    let card: DockerContainerCard

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 8) {
                Circle()
                    .fill(card.isRunning ? Color.green : Color.red)
                    .frame(width: 9, height: 9)

                Text(card.name)
                    .font(.headline)
                    .lineLimit(1)

                Text(card.isRunning ? "运行中" : "已停止")
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background((card.isRunning ? Color.green : Color.red).opacity(0.14), in: Capsule())
                    .foregroundStyle(card.isRunning ? .green : .red)

                Spacer()

                Text(card.runningFor.isEmpty ? card.state : card.runningFor)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Text(card.image)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1)

            VStack(alignment: .leading, spacing: 6) {
                metricBar(title: "CPU", value: card.cpuPercent, tint: .blue)
                metricBar(title: "内存", value: card.memPercent, tint: .orange, subtitle: card.memUsage)
            }

            Text(card.status)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.vertical, 6)
    }

    private func metricBar(title: String, value: Double, tint: Color, subtitle: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(String(format: "%.1f%%", value))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            ProgressView(value: max(0, min(100, value)), total: 100)
                .tint(tint)
            if let subtitle, !subtitle.isEmpty {
                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
