import SwiftUI

struct RecentlyDeletedView: View {
    @EnvironmentObject private var session: AppSession
    @StateObject private var syncService = SyncService.shared
    @ObservedObject private var store = ServerStore.shared

    @State private var items: [RecentlyDeletedAsset] = []
    @State private var isLoading = false
    @State private var operatingID: String?
    @State private var errorMessage: String?
    @State private var pendingPurge: RecentlyDeletedAsset?

    var body: some View {
        List {
            if isLoading && items.isEmpty {
                HStack {
                    Spacer()
                    ProgressView("正在读取最近删除...")
                    Spacer()
                }
                .listRowBackground(Color.clear)
            } else if items.isEmpty {
                ContentUnavailableView(
                    "最近删除为空",
                    systemImage: "trash",
                    description: Text("删除的云端资产会在保留期内显示在这里")
                )
            } else {
                ForEach(items) { item in
                    deletedRow(item)
                }
            }
        }
        .navigationTitle("最近删除")
#if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
#endif
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    Task { await reload() }
                } label: {
                    Label("刷新", systemImage: "arrow.clockwise")
                }
                .disabled(isLoading)
            }
        }
        .task { await reload() }
        .refreshable { await reload() }
        .alert("操作失败", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("知道了", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "未知错误")
        }
        .confirmationDialog(
            "永久删除后无法恢复",
            isPresented: Binding(
                get: { pendingPurge != nil },
                set: { if !$0 { pendingPurge = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("永久删除", role: .destructive) {
                guard let item = pendingPurge else { return }
                pendingPurge = nil
                Task { await purge(item) }
            }
            Button("取消", role: .cancel) { pendingPurge = nil }
        } message: {
            Text("此操作会清除云端密文与恢复能力，所有设备均无法找回该资产。")
        }
    }

    @ViewBuilder
    private func deletedRow(_ item: RecentlyDeletedAsset) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "server.rack")
                .foregroundStyle(item.portable == nil ? .orange : .secondary)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 4) {
                Text(item.displayName)
                    .font(.body.weight(.semibold))
                Text(item.endpoint)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let days = item.remainingDays {
                    Text(days == 0 ? "即将自动清理" : "剩余 \(days) 天")
                        .font(.caption2)
                        .foregroundStyle(days <= 3 ? .orange : .secondary)
                }
                if let decryptionError = item.decryptionError {
                    Text(decryptionError)
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
            }

            Spacer(minLength: 8)

            if operatingID == item.id {
                ProgressView()
                    .controlSize(.small)
            } else {
                Button("恢复") {
                    Task { await restore(item) }
                }
                .buttonStyle(.borderedProminent)
                .disabled(item.portable == nil)

                Menu {
                    Button("永久删除", role: .destructive) {
                        pendingPurge = item
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .padding(.vertical, 4)
    }

    @MainActor
    private func reload() async {
        guard !isLoading else { return }
        guard session.isAuthenticated,
              session.isUnlocked,
              var masterPassword = session.readMasterPassword() else {
            errorMessage = "请先登录并解锁主密码"
            return
        }

        isLoading = true
        defer {
            SecurityPrimitives.secureZero(&masterPassword)
            isLoading = false
        }
        do {
            items = try await syncService.loadRecentlyDeleted(
                masterPassword: masterPassword,
                accountID: session.username
            )
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    @MainActor
    private func restore(_ item: RecentlyDeletedAsset) async {
        guard operatingID == nil else { return }
        operatingID = item.id
        defer { operatingID = nil }
        do {
            let outcome = try await syncService.restoreRecentlyDeleted(
                item,
                store: store,
                accountID: session.username
            )
            if case .completed = outcome {
                items.removeAll { $0.id == item.id }
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    @MainActor
    private func purge(_ item: RecentlyDeletedAsset) async {
        guard operatingID == nil else { return }
        operatingID = item.id
        defer { operatingID = nil }
        do {
            let outcome = try await syncService.purgeRecentlyDeleted(item, accountID: session.username)
            switch outcome {
            case .completed, .queued:
                items.removeAll { $0.id == item.id }
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
