import SwiftUI

struct DockerManagerView: View {
    @StateObject private var service = DockerService()

    @State private var host = ""
    @State private var username = ""
    @State private var password = ""

    var body: some View {
        Group {
            if !service.isConnected {
                connectPanel
            } else {
                containerList
            }
        }
        .navigationTitle("Docker 管理")
    }

    private var connectPanel: some View {
        Form {
            Section("SSH 信息") {
                TextField("主机/IP", text: $host)
                    .applyInputPolish()
                TextField("用户名", text: $username)
                    .applyInputPolish()
                SecureField("密码", text: $password)
            }

            Section("操作") {
                Button("连接 Docker") {
                    Task {
                        await service.connect(host: host, username: username, password: password)
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(service.isLoading)
            }

            Section("状态") {
                Text(service.statusText)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var containerList: some View {
        List {
            Section {
                ForEach(service.cards) { card in
                    NavigationLink(destination: DockerLogStreamView(service: service, container: card)) {
                        DockerCardView(card: card)
                    }
                    .contextMenu {
                        ForEach(DockerAction.allCases, id: \.self) { action in
                            Button(action.label) {
                                Task { await service.performAction(containerID: card.id, action: action) }
                            }
                        }
                    }
                }
            } header: {
                HStack {
                    Text("容器列表")
                    Spacer()
                    Text(service.statusText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        #if os(iOS)
        .listStyle(.insetGrouped)
        #else
        .listStyle(.inset)
        #endif
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("刷新") {
                    Task { try? await service.refreshNow() }
                }
            }
            ToolbarItem(placement: .primaryAction) {
                Button("断开") {
                    Task { await service.disconnect() }
                }
            }
        }
    }
}

private struct DockerCardView: View {
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

struct DockerLogStreamView: View {
    @ObservedObject var service: DockerService
    let container: DockerContainerCard

    @State private var logs: String = "加载日志中..."
    @State private var isAutoRefresh: Bool = true
    @State private var logTask: Task<Void, Never>?

    var body: some View {
        ScrollView {
            Text(logs)
                .font(.system(.caption, design: .monospaced))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
        }
        .background(Color.black.opacity(0.9))
        .foregroundStyle(.green)
        .navigationTitle("\(container.name) 日志")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("刷新") { Task { await fetchOnce() } }
            }
            ToolbarItem(placement: .primaryAction) {
                Toggle("自动", isOn: $isAutoRefresh)
                    .toggleStyle(.switch)
                    .onChange(of: isAutoRefresh) { _, newValue in
                        if newValue {
                            startStreaming()
                        } else {
                            stopStreaming()
                        }
                    }
            }
        }
        .onAppear {
            startStreaming()
        }
        .onDisappear {
            stopStreaming()
        }
    }

    private func startStreaming() {
        stopStreaming()
        logTask = Task(priority: .utility) {
            while !Task.isCancelled {
                await fetchOnce()
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }

    private func stopStreaming() {
        logTask?.cancel()
        logTask = nil
    }

    private func fetchOnce() async {
        do {
            let text = try await service.fetchLogs(containerID: container.id)
            logs = text.isEmpty ? "(暂无日志)" : text
        } catch {
            logs = "日志拉取失败: \(error.localizedDescription)"
        }
    }
}
