import SwiftUI

struct DiagnosticsExportView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var diagnostics: DiagnosticsManager
    @State private var exportURL: URL?
    @State private var errorMessage: String = ""

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 14) {
                Text("最近 \(diagnostics.entries.count) 条网络诊断记录（已脱敏）")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                if let exportURL {
                    ShareLink(item: exportURL) {
                        Label("分享诊断日志", systemImage: "square.and.arrow.up")
                    }
                    .buttonStyle(.borderedProminent)
                } else {
                    Button {
                        buildExport()
                    } label: {
                        Label("生成诊断日志文件", systemImage: "doc.text")
                    }
                    .buttonStyle(.borderedProminent)
                }

                if !errorMessage.isEmpty {
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundStyle(.red)
                }

                List(diagnostics.entries.suffix(10).reversed()) { item in
                    VStack(alignment: .leading, spacing: 4) {
                        Text("\(item.method) · \(item.endpoint.rawValue)")
                            .font(.caption)
                            .lineLimit(2)
                        Text("status=\(item.statusCode.map(String.init) ?? "-") latency=\(item.latencyMs)ms attempt=\(item.attempt) failure=\(item.failure?.rawValue ?? "-")")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(16)
            .navigationTitle("导出诊断日志")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
            }
            .task {
                buildExport()
            }
            .onDisappear {
                if let exportURL {
                    diagnostics.discardExport(exportURL)
                }
            }
        }
    }

    private func buildExport() {
        do {
            exportURL = try diagnostics.exportToTempFile()
            errorMessage = ""
        } catch {
            exportURL = nil
            // File-system messages can contain local paths. Keep the visible
            // recovery prompt useful without turning it into an export path.
            errorMessage = "无法生成诊断文件，请稍后重试。"
        }
    }
}
