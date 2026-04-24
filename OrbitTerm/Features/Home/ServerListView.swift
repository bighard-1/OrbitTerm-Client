import SwiftUI

struct ServerListView: View {
    var body: some View {
        List {
            Section("服务器列表") {
                Text("暂无服务器，请先在云同步页上传配置")
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("服务器")
    }
}
