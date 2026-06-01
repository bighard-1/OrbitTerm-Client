import SwiftUI

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
