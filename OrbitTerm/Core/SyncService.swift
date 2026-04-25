import Foundation
import Network
import os

@MainActor
final class SyncService: ObservableObject {
    static let shared = SyncService()

    @Published var lastSyncMessage: String = "尚未同步"

    private let network: NetworkService
    private let orbitManager: OrbitManager
    private let vault: CredentialVault

    init(network: NetworkService = .shared, orbitManager: OrbitManager? = nil, vault: CredentialVault = .shared) {
        self.network = network
        self.orbitManager = orbitManager ?? OrbitManager()
        self.vault = vault
    }

    // 将本地明文配置先交给 Rust 核心加密，再上传密文到后端 /upload。
    func uploadEncryptedConfig(
        token: String,
        masterPassword: String,
        plaintextConfig: String,
        vectorClock: [String: Int],
        configID: UInt? = nil,
        allowQueueOnNetworkFailure: Bool = false
    ) async -> Bool {
        do {
            let encrypted = try orbitManager.encrypt(password: masterPassword, data: plaintextConfig)
            let vectorClockData = try JSONSerialization.data(withJSONObject: vectorClock)
            guard let vectorClockString = String(data: vectorClockData, encoding: .utf8) else {
                lastSyncMessage = "同步失败: 版本号编码失败"
                return false
            }

            let payload = UploadConfigRequest(
                id: configID,
                encrypted_blob_base64: encrypted.base64EncodedString(),
                vector_clock: vectorClockString
            )

            do {
                let response = try await network.uploadConfig(token: token, payload: payload)
                lastSyncMessage = "同步成功，配置ID: \(response.id)"
                return true
            } catch {
                // P2：静默同步在网络异常下进入本地离线重试队列。
                if allowQueueOnNetworkFailure, NetworkService.isRetriableNetworkError(error) {
                    await SyncQueue.shared.enqueueUpload(payload: payload, reason: error.localizedDescription)
                    lastSyncMessage = "网络波动，已加入后台同步队列"
                    return true
                }
                throw error
            }
        } catch {
            lastSyncMessage = "同步失败: \(error.localizedDescription)"
            return false
        }
    }

    // 从云端拉取并解包配置：
    // 1) 使用主密码解密 Blob
    // 2) 解析 PortableServerConfig
    // 3) 本地 ServerStore 更新普通配置
    // 4) 所有敏感字段（密码/私钥/私钥口令）统一写回 Keychain
    func pullAndApplyConfigs(
        token: String,
        masterPassword: String,
        store: ServerStore
    ) async -> Bool {
        do {
            let remoteItems = try await network.pullConfigs(token: token)
            if remoteItems.isEmpty {
                lastSyncMessage = "拉取完成: 云端暂无配置"
                return true
            }

            var applied = 0
            var skipped = 0

            for item in remoteItems {
                guard let encrypted = Data(base64Encoded: item.encrypted_blob_base64) else {
                    skipped += 1
                    continue
                }

                let plainData = try orbitManager.decrypt(password: masterPassword, encrypted: encrypted)
                guard let plainText = String(data: plainData, encoding: .utf8),
                      let portableData = plainText.data(using: .utf8) else {
                    skipped += 1
                    continue
                }

                let portable = try JSONDecoder().decode(PortableServerConfig.self, from: portableData)
                guard let serverID = UUID(uuidString: portable.id) else {
                    skipped += 1
                    continue
                }

                let credentialID = store.servers.first(where: { $0.id == serverID })?.credentialID ?? serverID
                let createdAt = Date(timeIntervalSince1970: TimeInterval(portable.savedAtUnix))
                let server = ServerEntry(
                    id: serverID,
                    name: portable.name,
                    group: portable.group,
                    host: portable.host,
                    port: portable.port,
                    username: portable.username,
                    authMethod: portable.authMethod == ServerAuthMethod.key.rawValue ? .key : .password,
                    allowPasswordFallback: portable.allowPasswordFallback,
                    credentialID: credentialID,
                    createdAt: createdAt
                )

                // P1 修复：无论当前主认证方式是什么，都完整回写全部敏感字段。
                let credentials = ServerCredentials(
                    password: portable.password,
                    privateKeyContent: portable.privateKeyContent,
                    privateKeyPassphrase: portable.privateKeyPassphrase
                )
                try vault.save(credentials, for: credentialID)
                store.addOrUpdate(server)
                applied += 1
            }

            lastSyncMessage = "拉取完成: 已应用 \(applied) 条，跳过 \(skipped) 条"
            return applied > 0 || skipped == 0
        } catch {
            lastSyncMessage = "拉取失败: \(error.localizedDescription)"
            return false
        }
    }
}

struct SyncQueueItem: Codable, Identifiable {
    let id: UUID
    let payload: UploadConfigRequest
    let createdAt: Date
    var updatedAt: Date
    var attemptCount: Int
    var nextRetryAt: Date
    var lastError: String?

    init(
        id: UUID = UUID(),
        payload: UploadConfigRequest,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        attemptCount: Int = 0,
        nextRetryAt: Date = Date(),
        lastError: String? = nil
    ) {
        self.id = id
        self.payload = payload
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.attemptCount = attemptCount
        self.nextRetryAt = nextRetryAt
        self.lastError = lastError
    }
}

actor SyncQueueStore {
    private(set) var items: [SyncQueueItem]
    private let fileURL: URL
    private let encoder = JSONEncoder()

    init(fileURL: URL) {
        self.fileURL = fileURL
        self.items = Self.loadFromDisk(fileURL: fileURL)
        encoder.outputFormatting = [.sortedKeys]
    }

    func append(_ item: SyncQueueItem) {
        items.append(item)
        items.sort { $0.createdAt < $1.createdAt }
        persist()
    }

    func remove(id: UUID) {
        items.removeAll { $0.id == id }
        persist()
    }

    func update(_ item: SyncQueueItem) {
        guard let index = items.firstIndex(where: { $0.id == item.id }) else { return }
        items[index] = item
        items.sort { $0.createdAt < $1.createdAt }
        persist()
    }

    func firstItem() -> SyncQueueItem? {
        items.sorted { $0.createdAt < $1.createdAt }.first
    }

    private func persist() {
        do {
            let data = try encoder.encode(items)
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true,
                attributes: nil
            )
            try data.write(to: fileURL, options: [.atomic])
        } catch {
            // 队列持久化失败时忽略，避免影响主流程。
        }
    }

    private static func loadFromDisk(fileURL: URL) -> [SyncQueueItem] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        guard let items = try? JSONDecoder().decode([SyncQueueItem].self, from: data) else { return [] }
        return items.sorted { $0.createdAt < $1.createdAt }
    }
}

final class SyncQueue {
    static let shared = SyncQueue()

    private let logger = Logger(subsystem: "com.orbitterm.app", category: "sync_queue")
    private let network = NetworkService.shared
    private let monitor = NWPathMonitor()
    private let monitorQueue = DispatchQueue(label: "com.orbitterm.syncqueue.monitor")
    private let stateQueue = DispatchQueue(label: "com.orbitterm.syncqueue.state")

    private var isNetworkReachable = true
    private var processingTask: Task<Void, Never>?
    private var wakeTask: Task<Void, Never>?
    private var authTokenProvider: (() -> String?)?

    private let store: SyncQueueStore

    private init() {
        let fileURL = Self.queueFileURL()
        self.store = SyncQueueStore(fileURL: fileURL)
        startMonitor()
    }

    func setAuthTokenProvider(_ provider: @escaping () -> String?) {
        stateQueue.sync {
            authTokenProvider = provider
        }
        triggerProcessing(reason: "token_provider_updated")
    }

    func enqueueUpload(payload: UploadConfigRequest, reason: String?) async {
        let item = SyncQueueItem(
            payload: payload,
            attemptCount: 0,
            nextRetryAt: Date(),
            lastError: reason
        )
        await store.append(item)
        logger.debug("[SYNCQ] enqueue id=\(item.id.uuidString, privacy: .public)")
        triggerProcessing(reason: "enqueue")
    }

    private func startMonitor() {
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            let available = self.stateQueue.sync { () -> Bool in
                self.isNetworkReachable = (path.status == .satisfied)
                return self.isNetworkReachable
            }
            if available {
                self.triggerProcessing(reason: "network_restored")
            }
        }
        monitor.start(queue: monitorQueue)
    }

    private func triggerProcessing(reason: String) {
        stateQueue.sync {
            let canStart = isNetworkReachable && processingTask == nil
            guard canStart else { return }
            let task = Task(priority: .utility) { [weak self] in
                guard let self else { return }
                await self.processLoop(reason: reason)
                self.stateQueue.sync {
                    self.processingTask = nil
                }
            }
            processingTask = task
        }
    }

    private func processLoop(reason: String) async {
        logger.debug("[SYNCQ] process start reason=\(reason, privacy: .public)")
        while !Task.isCancelled {
            guard isNetworkUp else { return }

            guard let token = currentToken(), !token.isEmpty else {
                logger.debug("[SYNCQ] process paused: token unavailable")
                return
            }

            guard let head = await store.firstItem() else {
                logger.debug("[SYNCQ] queue empty")
                return
            }

            if head.nextRetryAt > Date() {
                scheduleWake(at: head.nextRetryAt)
                return
            }

            do {
                _ = try await network.uploadConfig(token: token, payload: head.payload)
                await store.remove(id: head.id)
                logger.debug("[SYNCQ] sent id=\(head.id.uuidString, privacy: .public)")
            } catch {
                var failed = head
                failed.attemptCount += 1
                failed.updatedAt = Date()
                failed.lastError = error.localizedDescription
                failed.nextRetryAt = Date().addingTimeInterval(Self.backoffSeconds(for: failed.attemptCount))
                await store.update(failed)
                logger.debug("[SYNCQ] retry id=\(failed.id.uuidString, privacy: .public) attempt=\(failed.attemptCount)")
                scheduleWake(at: failed.nextRetryAt)
                return
            }
        }
    }

    private func scheduleWake(at date: Date) {
        let task = Task(priority: .utility) { [weak self] in
            guard let self else { return }
            let sleepNanos = max(0, date.timeIntervalSinceNow) * 1_000_000_000
            if sleepNanos > 0 {
                try? await Task.sleep(nanoseconds: UInt64(sleepNanos))
            }
            self.triggerProcessing(reason: "backoff_elapsed")
        }
        stateQueue.sync {
            wakeTask?.cancel()
            wakeTask = task
        }
    }

    private var isNetworkUp: Bool {
        stateQueue.sync { isNetworkReachable }
    }

    private func currentToken() -> String? {
        stateQueue.sync { authTokenProvider?() }
    }

    private static func backoffSeconds(for attempt: Int) -> TimeInterval {
        let steps: [TimeInterval] = [10, 30, 120, 300, 600, 900, 1800]
        let index = min(max(0, attempt - 1), steps.count - 1)
        return steps[index]
    }

    private static func queueFileURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base
            .appendingPathComponent("OrbitTerm", isDirectory: true)
            .appendingPathComponent("sync_queue.json", isDirectory: false)
    }
}
