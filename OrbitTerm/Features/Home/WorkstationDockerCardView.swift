import SwiftUI

struct WorkstationDockerCardView: View {
    @ObservedObject var active: WorkspaceSession
    @ObservedObject var dockerService: DockerService
    let onStartCheckedDocker: () -> Void
    @Environment(\.appThemePalette) private var palette
    @Environment(\.securitySemanticPalette) private var security

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Docker")
                    .font(.subheadline.weight(.semibold))
                Spacer()
            }

            if dockerService.isScanning {
                Text("正在扫描容器...")
                    .font(.caption)
                    .foregroundStyle(security.information.color)
            } else if dockerService.dockerEnvironmentMissing {
                Text("环境待安装，是否查看一键安装教程？")
                    .font(.caption)
                    .foregroundStyle(security.warning.color)
                if let docsURL = URL(string: "https://docs.docker.com/engine/install/") {
                    Link("查看 Docker 官方安装文档", destination: docsURL)
                        .font(.caption)
                }
            } else if dockerService.cards.isEmpty {
                Text(dockerService.statusText)
                    .font(.caption)
                    .foregroundStyle(palette.textSecondary.color)
                if active.verifiedSessionLease != nil, !dockerService.isConnected {
                    Button("启动安全 Docker", action: onStartCheckedDocker)
                        .buttonStyle(.borderedProminent)
                }
            } else {
                ForEach(dockerService.cards.prefix(6)) { card in
                    let presentation = DockerContainerPresentationState.resolve(isRunning: card.isRunning)
                    HStack {
                        Image(systemName: presentation.symbol)
                            .foregroundStyle(presentation.themeColor(in: security, fallback: palette).color)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(card.name).lineLimit(1)
                            Text(card.image).font(.caption2).foregroundStyle(palette.textSecondary.color).lineLimit(1)
                            Text(presentation.label)
                                .font(.caption2)
                                .foregroundStyle(presentation.themeColor(in: security, fallback: palette).color)
                        }
                        Spacer()
                        Text(presentation.label)
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(presentation.themeColor(in: security, fallback: palette).color.opacity(0.14), in: Capsule())
                            .foregroundStyle(presentation.themeColor(in: security, fallback: palette).color)
                        Text(String(format: "CPU %.1f%%", card.cpuPercent))
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(palette.textSecondary.color)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("\(card.name)，\(presentation.label)，CPU \(String(format: "%.1f%%", card.cpuPercent))")
                    .contextMenu {
                        Button("查看日志") {
                            Task {
                                do {
                                    let logs = try await dockerService.fetchLogs(containerID: card.id, tailLines: 200)
                                    active.appendTerminal("[docker-logs][\(card.name)]")
                                    logs.split(separator: "\n").suffix(60).forEach { line in
                                        active.appendTerminal(String(line))
                                    }
                                } catch {
                                    active.appendTerminal("[docker-logs][error] \(error.localizedDescription)")
                                }
                            }
                        }
                        ForEach(DockerAction.allCases, id: \.self) { action in
                            Button(action.label) {
                                Task { await dockerService.performAction(containerID: card.id, action: action) }
                            }
                        }
                    }
                }
            }
        }
        .padding(10)
        .foregroundStyle(palette.textPrimary.color)
        .background(palette.surfaceGlassStrong.color, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(palette.borderGlass.color, lineWidth: 1))
    }
}
