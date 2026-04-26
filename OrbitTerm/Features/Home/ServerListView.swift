import SwiftUI

struct ServerListView: View {
    @EnvironmentObject private var session: AppSession
    @EnvironmentObject private var store: ServerStore
    @State private var showingAddServer = false

    var body: some View {
        List {
            if store.servers.isEmpty {
                Section("服务器") {
                    Text("还没有服务器，点击右上角 + 添加")
                        .foregroundStyle(.secondary)
                }
            } else {
                ForEach(store.groupedServers, id: \.group) { section in
                    Section(section.group) {
                        ForEach(section.items) { server in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(server.name)
                                Text("\(server.username)@\(server.endpointText)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .contextMenu {
                                Button("删除", role: .destructive) {
                                    store.remove(server)
                                }
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("服务器")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showingAddServer = true
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .sheet(isPresented: $showingAddServer) {
            AddServerView(store: store) { _ in }
                .environmentObject(session)
        }
    }
}
