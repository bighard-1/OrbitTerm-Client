import Foundation

extension Notification.Name {
    static let orbitConnectionLost = Notification.Name("OrbitTerm.ConnectionLost")
}

actor TerminalChunkBuffer {
    private var storage: [UInt64: Data] = [:]
    private var history: [UInt64: Data] = [:]
    private let maxHistoryBytesPerChannel = 8_388_608

    func ingest(channelID: UInt64, bytes: Data) {
        guard !bytes.isEmpty else { return }
        if var existing = storage[channelID] {
            existing.append(bytes)
            storage[channelID] = existing
        } else {
            storage[channelID] = bytes
        }

        if var existingHistory = history[channelID] {
            existingHistory.append(bytes)
            if existingHistory.count > maxHistoryBytesPerChannel {
                let overflow = existingHistory.count - maxHistoryBytesPerChannel
                existingHistory.removeFirst(overflow)
            }
            history[channelID] = existingHistory
        } else {
            if bytes.count > maxHistoryBytesPerChannel {
                history[channelID] = bytes.suffix(maxHistoryBytesPerChannel)
            } else {
                history[channelID] = bytes
            }
        }
    }

    func drainAll() -> [UInt64: Data] {
        let snapshot = storage
        storage.removeAll(keepingCapacity: true)
        return snapshot
    }

    func replay(channelID: UInt64) -> Data {
        history[channelID] ?? Data()
    }

    func clear(channelID: UInt64) {
        storage.removeValue(forKey: channelID)
        history.removeValue(forKey: channelID)
    }
}

@MainActor
final class TerminalService {
    static let shared = TerminalService()

    private var textHandlers: [UInt64: (String) -> Void] = [:]
    private var byteHandlers: [UInt64: [UUID: (Data) -> Void]] = [:]
    private var isCallbackInstalled = false
    private var virtualWriters: [UInt64: @Sendable ([UInt8]) async -> Bool] = [:]
    private var nextVirtualChannelID: UInt64 = 9_000_000_000_000_000_000
    private let chunkBuffer = TerminalChunkBuffer()
    private var flushTask: Task<Void, Never>?
    private let flushIntervalNanos: UInt64 = 33_000_000
    private let ffiQueue = DispatchQueue(label: "com.orbitterm.terminal.ffi", qos: .userInitiated)

    private init() {
        installCallbackIfNeeded()
    }

    func bind(channelID: UInt64, onData: @escaping (String) -> Void) {
        textHandlers[channelID] = onData
    }

    @discardableResult
    func bindBytes(channelID: UInt64, onData: @escaping (Data) -> Void) -> UUID {
        let subscriberID = UUID()
        var handlers = byteHandlers[channelID] ?? [:]
        handlers[subscriberID] = onData
        byteHandlers[channelID] = handlers

        Task { [weak self] in
            guard let self else { return }
            let replay = await chunkBuffer.replay(channelID: channelID)
            guard !replay.isEmpty else { return }
            await MainActor.run {
                self.byteHandlers[channelID]?[subscriberID]?(replay)
            }
        }
        return subscriberID
    }

    func unbindBytes(channelID: UInt64, subscriberID: UUID) {
        guard var handlers = byteHandlers[channelID] else { return }
        handlers.removeValue(forKey: subscriberID)
        if handlers.isEmpty {
            byteHandlers.removeValue(forKey: channelID)
        } else {
            byteHandlers[channelID] = handlers
        }
    }

    func unbind(channelID: UInt64) {
        textHandlers.removeValue(forKey: channelID)
        byteHandlers.removeValue(forKey: channelID)
    }

    func openPTY(sessionOrChannelID: UInt64, cols: UInt32, rows: UInt32) async -> UInt64? {
        installCallbackIfNeeded()
        let ptyPtr = await performFFI {
            "pty".withCString { typePtr in
                orbit_request_channel(sessionOrChannelID, typePtr)
            }
        }
        guard let ptyID = parseChannelID(from: ptyPtr) else {
            return nil
        }

        let resizePtr = await performFFI {
            orbit_terminal_resize(ptyID, cols, rows)
        }
        _ = parseOK("resize", rawPtr: resizePtr)
        return ptyID
    }

    func openSSHSession(
        host: String,
        port: Int,
        username: String,
        password: String,
        privateKeyContent: String,
        privateKeyPassphrase: String,
        allowPasswordFallback: Bool
    ) async -> UInt64? {
        installCallbackIfNeeded()
        let cleanHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanUser = username.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanKey = privateKeyContent.trimmingCharacters(in: .whitespacesAndNewlines)

        let sessionPtr = await performFFI {
            cleanHost.withCString { h in
                cleanUser.withCString { u in
                    password.withCString { p in
                        cleanKey.withCString { k in
                            privateKeyPassphrase.withCString { passphrase in
                                orbit_ssh_connect(
                                    h,
                                    Int32(max(1, min(65535, port))),
                                    u,
                                    p,
                                    k,
                                    passphrase,
                                    allowPasswordFallback ? 1 : 0
                                )
                            }
                        }
                    }
                }
            }
        }
        return parseChannelID(from: sessionPtr)
    }

    func closeSSHSession(baseSessionID: UInt64) async {
        let ptr = await performFFI {
            orbit_ssh_disconnect(baseSessionID)
        }
        _ = parseOK("ssh_disconnect", rawPtr: ptr)
    }

    func resolveBaseSessionID(sessionOrChannelID: UInt64) -> UInt64? {
        parseChannelID(
            from: "exec".withCString { typePtr in
                orbit_request_channel(sessionOrChannelID, typePtr)
            }
        )
    }

    func write(channelID: UInt64, text: String) async -> Bool {
        let bytes = Array(text.utf8)
        return await writeRaw(channelID: channelID, bytes: bytes)
    }

    func writeRaw(channelID: UInt64, bytes: [UInt8]) async -> Bool {
        if let writer = virtualWriters[channelID] {
            return await writer(bytes)
        }
        let ptr = await performFFI {
            bytes.withUnsafeBufferPointer { buf in
                orbit_terminal_write(channelID, buf.baseAddress, bytes.count)
            }
        }
        return parseOK("write", rawPtr: ptr)
    }

    func resize(channelID: UInt64, cols: UInt32, rows: UInt32) async {
        let ptr = await performFFI {
            orbit_terminal_resize(channelID, cols, rows)
        }
        _ = parseOK("resize", rawPtr: ptr)
    }

    func unbindAndClose(channelID: UInt64) async {
        unbind(channelID: channelID)
        await chunkBuffer.clear(channelID: channelID)
        if virtualWriters[channelID] != nil {
            virtualWriters.removeValue(forKey: channelID)
            return
        }
        let ptr = await performFFI {
            orbit_terminal_close(channelID)
        }
        _ = parseOK("close", rawPtr: ptr)
    }

    func createVirtualChannel(writer: @escaping @Sendable ([UInt8]) async -> Bool) -> UInt64 {
        let channelID = nextVirtualChannelID
        nextVirtualChannelID = nextVirtualChannelID &+ 1
        virtualWriters[channelID] = writer
        return channelID
    }

    func feedVirtualChannel(channelID: UInt64, data: Data) async {
        guard virtualWriters[channelID] != nil else { return }
        await chunkBuffer.ingest(channelID: channelID, bytes: data)
    }

    private func installCallbackIfNeeded() {
        guard !isCallbackInstalled else { return }
        orbit_terminal_set_callback(TerminalService.callbackBridge)
        orbit_connection_set_callback(TerminalService.connectionCallbackBridge)
        isCallbackInstalled = true
        startFlushLoopIfNeeded()
    }

    private func startFlushLoopIfNeeded() {
        guard flushTask == nil else { return }
        flushTask = Task.detached(priority: .userInitiated) { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: self?.flushIntervalNanos ?? 33_000_000)
                guard let self else { continue }
                let batches = await self.chunkBuffer.drainAll()
                if batches.isEmpty {
                    continue
                }
                await MainActor.run {
                    for (channelID, data) in batches {
                        if let handlers = self.byteHandlers[channelID] {
                            for handler in handlers.values {
                                handler(data)
                            }
                        }
                        if let textHandler = self.textHandlers[channelID] {
                            let text = String(decoding: data, as: UTF8.self)
                            textHandler(text)
                        }
                    }
                }
            }
        }
    }

    private static let callbackBridge: @convention(c) (UInt64, UnsafePointer<UInt8>?, Int) -> Void = { channelID, dataPtr, len in
        guard let dataPtr, len > 0 else { return }
        let data = Data(bytes: dataPtr, count: len)
        Task.detached(priority: .userInitiated) {
            await TerminalService.shared.chunkBuffer.ingest(channelID: channelID, bytes: data)
        }
    }

    private static let connectionCallbackBridge: @convention(c) (UInt64, UnsafePointer<CChar>?) -> Void = { baseSessionID, messagePtr in
        guard let messagePtr else { return }
        let message = String(cString: messagePtr)
        guard message == "ERR_CONNECTION_LOST" else { return }
        Task { @MainActor in
            NotificationCenter.default.post(
                name: .orbitConnectionLost,
                object: nil,
                userInfo: ["baseSessionID": baseSessionID, "message": message]
            )
        }
    }

    private func parseChannelID(from ptr: UnsafeMutablePointer<CChar>?) -> UInt64? {
        guard let raw = parseRaw(ptr), raw.hasPrefix("OK:") else { return nil }
        var payload = String(raw.dropFirst(3))
        if payload.hasPrefix("session:") {
            payload = String(payload.dropFirst("session:".count))
        }
        return UInt64(payload)
    }

    private func parseOK(_ action: String, rawPtr: UnsafeMutablePointer<CChar>?) -> Bool {
        guard let raw = parseRaw(rawPtr) else { return false }
        return raw.hasPrefix("OK:")
    }

    private func performFFI<T>(_ work: @escaping () -> T) async -> T {
        await withCheckedContinuation { continuation in
            ffiQueue.async {
                continuation.resume(returning: work())
            }
        }
    }

    private func parseRaw(_ ptr: UnsafeMutablePointer<CChar>?) -> String? {
        guard let ptr else { return nil }
        defer { orbit_free_string(ptr) }
        return String(cString: ptr)
    }
}
