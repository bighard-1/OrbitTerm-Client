import SwiftUI

struct RecentlyDeletedView: View {
    @EnvironmentObject private var session: AppSession
    @EnvironmentObject private var syncService: SyncService
    @ObservedObject private var store = ServerStore.shared

    @State private var items: [RecentlyDeletedAsset] = []
    @State private var isLoading = false
    @State private var operatingID: String?
    @State private var errorMessage: String?
    @State private var successMessage: String?
    @State private var pendingPurge: RecentlyDeletedAsset?

    private var presentation: RecentlyDeletedPresentation {
        RecentlyDeletedPresentationMapper.make(
            isLoading: isLoading,
            itemCount: items.count,
            failureDetail: errorMessage,
            isMutating: operatingID != nil
        )
    }

    var body: some View {
        ZStack {
            AppChromeBackground()

            List {
                if isLoading && items.isEmpty {
                    HStack {
                        Spacer()
                        ProgressView(presentation.headline)
                        Spacer()
                    }
                    .listRowBackground(Color.clear)
                } else if items.isEmpty && errorMessage == nil {
                    ContentUnavailableView(
                        presentation.headline,
                        systemImage: "trash",
                        description: Text(presentation.detail)
                    )
                } else {
                    ForEach(items) { item in
                        deletedRow(item)
                    }
                }
                if presentation.phase == .failed {
                    VStack(alignment: .leading, spacing: 8) {
                        Label(
                            [presentation.detail, presentation.staleContentMessage]
                                .compactMap { $0 }
                                .joined(separator: " "),
                            systemImage: "exclamationmark.triangle.fill"
                        )
                        .font(.caption)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .securityStatusStyle(.danger)
                        Button("重试") { Task { await reload() } }
                            .buttonStyle(.bordered)
                    }
                    .listRowBackground(Color.clear)
                }
                if let successMessage {
                    OperationalTransientSuccessBanner(message: successMessage)
                        .listRowBackground(Color.clear)
                }
            }
            .scrollContentBackground(.hidden)
            .background(Color.clear)
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
                    Label(presentation.refreshLabel, systemImage: "arrow.clockwise")
                }
                .disabled(!presentation.refreshEnabled)
            }
        }
        .task { await reload() }
        .refreshable { await reload() }
        .task(id: successMessage) {
            guard successMessage != nil,
                  let delay = OperationalFeedbackPolicy.lifetime(kind: .success).autoDismissAfterNanoseconds else {
                return
            }
            try? await Task.sleep(nanoseconds: delay)
            guard !Task.isCancelled else { return }
            successMessage = nil
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

        errorMessage = nil
        successMessage = nil
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
            errorMessage = "无法加载最近删除，请检查网络或登录状态。"
        }
    }

    @MainActor
    private func restore(_ item: RecentlyDeletedAsset) async {
        guard operatingID == nil else { return }
        errorMessage = nil
        successMessage = nil
        operatingID = item.id
        defer { operatingID = nil }
        do {
            let outcome = try await syncService.restoreRecentlyDeleted(
                item,
                store: store,
                accountID: session.username
            )
            items.removeAll { $0.id == item.id }
            let queued: Bool
            switch outcome {
            case .completed: queued = false
            case .queued: queued = true
            }
            successMessage = RecentlyDeletedPresentationMapper.successMessage(
                action: "恢复",
                queued: queued
            )
        } catch {
            errorMessage = "操作未完成，请检查网络、登录状态和主密码。"
        }
    }

    @MainActor
    private func purge(_ item: RecentlyDeletedAsset) async {
        guard operatingID == nil else { return }
        errorMessage = nil
        successMessage = nil
        operatingID = item.id
        defer { operatingID = nil }
        do {
            let outcome = try await syncService.purgeRecentlyDeleted(item, accountID: session.username)
            let queued: Bool
            switch outcome {
            case .completed:
                queued = false
                items.removeAll { $0.id == item.id }
            case .queued:
                queued = true
                items.removeAll { $0.id == item.id }
            }
            successMessage = RecentlyDeletedPresentationMapper.successMessage(
                action: "永久删除",
                queued: queued
            )
        } catch {
            errorMessage = "操作未完成，请检查网络、登录状态和主密码。"
        }
    }
}
