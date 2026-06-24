import SwiftUI

struct WorkstationDockerCardView: View {
    let active: WorkspaceSession
    let onHide: () -> Void
    let onStartCheckedDocker: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Docker")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Button(action: onHide) {
                    Image(systemName: "eye.slash")
                }
                .buttonStyle(.borderless)
            }

            if active.dockerService.isScanning {
                Text("正在扫描容器...")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if active.dockerService.dockerEnvironmentMissing {
                Text("环境待安装，是否查看一键安装教程？")
                    .font(.caption)
                    .foregroundStyle(.orange)
                if let docsURL = URL(string: "https://docs.docker.com/engine/install/") {
                    Link("查看 Docker 官方安装文档", destination: docsURL)
                        .font(.caption)
                }
            } else if active.dockerService.cards.isEmpty {
                Text(active.dockerService.statusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if active.verifiedSessionLease != nil, !active.dockerService.isConnected {
                    Button("启动安全 Docker", action: onStartCheckedDocker)
                        .buttonStyle(.borderedProminent)
                }
            } else {
                ForEach(active.dockerService.cards.prefix(6)) { card in
                    HStack {
                        Circle()
                            .fill(card.isRunning ? Color.green : Color.red)
                            .frame(width: 8, height: 8)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(card.name).lineLimit(1)
                            Text(card.image).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                            Text(card.isRunning ? "运行中" : "已停止")
                                .font(.caption2)
                                .foregroundStyle(card.isRunning ? .green : .red)
                        }
                        Spacer()
                        Text(card.isRunning ? "运行中" : "已停止")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background((card.isRunning ? Color.green : Color.red).opacity(0.14), in: Capsule())
                            .foregroundStyle(card.isRunning ? .green : .red)
                        Text(String(format: "CPU %.1f%%", card.cpuPercent))
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    .contextMenu {
                        Button("查看日志") {
                            Task {
                                do {
                                    let logs = try await active.dockerService.fetchLogs(containerID: card.id, tailLines: 200)
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
                                Task { await active.dockerService.performAction(containerID: card.id, action: action) }
                            }
                        }
                    }
                }
            }
        }
        .padding(10)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}
