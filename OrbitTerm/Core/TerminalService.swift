import Foundation

extension Notification.Name {
    static let orbitConnectionLost = Notification.Name("OrbitTerm.ConnectionLost")
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
    private var queuedInput: [UInt64: Data] = [:]
    private var queuedInputFlushTasks: [UInt64: Task<Void, Never>] = [:]
    private var inputOwners: [UInt64: OperationOwner] = [:]
    private var inputLeases: [UInt64: OperationLease] = [:]
    private var firstFrameSpans: [UInt64: PerformanceSignpost.Span] = [:]
    private let flushIntervalNanos = OperationResourceBudget.terminalFlushIntervalNanoseconds
    private let ffiQueue = DispatchQueue(label: "com.orbitterm.terminal.ffi", qos: .userInitiated)

    private init() {
        installCallbackIfNeeded()
    }

    func bind(channelID: UInt64, onData: @escaping (String) -> Void) {
        if textHandlers[channelID] == nil, byteHandlers[channelID] == nil {
            beginInputOwnership(for: channelID)
        }
        textHandlers[channelID] = onData
        startFlushLoopIfNeeded()
    }

    @discardableResult
    func bindBytes(channelID: UInt64, onData: @escaping (Data) -> Void) -> UUID {
        if textHandlers[channelID] == nil, byteHandlers[channelID] == nil {
            beginInputOwnership(for: channelID)
        }
        let subscriberID = UUID()
        var handlers = byteHandlers[channelID] ?? [:]
        handlers[subscriberID] = onData
        byteHandlers[channelID] = handlers
        startFlushLoopIfNeeded()

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
        if byteHandlers[channelID] == nil, textHandlers[channelID] == nil {
            invalidateInputOwnership(for: channelID)
        }
        stopFlushLoopIfIdle()
    }

    func unbind(channelID: UInt64) {
        invalidateInputOwnership(for: channelID)
        firstFrameSpans.removeValue(forKey: channelID)?.cancel()
        textHandlers.removeValue(forKey: channelID)
        byteHandlers.removeValue(forKey: channelID)
        stopFlushLoopIfIdle()
    }

    func openPTY(sessionOrChannelID: UInt64, cols: UInt32, rows: UInt32) async -> UInt64? {
        #if DEBUG && ORBITTERM_INTERNAL_LEGACY_NETWORK
        installCallbackIfNeeded()
        let ptyPtr = await performFFI {
            RustFFI.requestChannel(baseSessionID: sessionOrChannelID, type: "pty")
        }
        guard let ptyID = parseChannelID(from: ptyPtr) else {
            return nil
        }

        let resizePtr = await performFFI {
            orbit_terminal_resize(ptyID, cols, rows)
        }
        _ = parseOK("resize", rawPtr: resizePtr)
        return ptyID
        #else
        return nil
        #endif
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
        #if DEBUG && ORBITTERM_INTERNAL_LEGACY_NETWORK
        installCallbackIfNeeded()
        let sessionPtr = await performFFI {
            RustFFI.connectSSH(
                host: host,
                port: port,
                username: username,
                password: password,
                privateKeyContent: privateKeyContent,
                privateKeyPassphrase: privateKeyPassphrase,
                allowPasswordFallback: allowPasswordFallback
            )
        }
        return parseChannelID(from: sessionPtr)
        #else
        return nil
        #endif
    }

    func closeSSHSession(baseSessionID: UInt64) async {
        let ptr = await performFFI {
            orbit_ssh_disconnect(baseSessionID)
        }
        _ = parseOK("ssh_disconnect", rawPtr: ptr)
    }

    func resolveBaseSessionID(sessionOrChannelID: UInt64) -> UInt64? {
        #if DEBUG && ORBITTERM_INTERNAL_LEGACY_NETWORK
        parseChannelID(
            from: RustFFI.requestChannel(baseSessionID: sessionOrChannelID, type: "exec")
        )
        #else
        nil
        #endif
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

    /// Keyboard delegates can be invoked once per character. Keep that hot
    /// path on the main actor and coalesce only ordinary text for one short
    /// scheduling window; control sequences always flush immediately.
    func enqueueInput(channelID: UInt64, bytes: [UInt8]) {
        guard !bytes.isEmpty else { return }
        let lease = currentInputLease(for: channelID)
        queuedInput[channelID, default: Data()].append(contentsOf: bytes)

        if TerminalInputDispatchPolicy.sendsImmediately(bytes) ||
            (queuedInput[channelID]?.count ?? 0) >= TerminalInputDispatchPolicy.maximumCoalescedBytes {
            flushQueuedInputImmediately(channelID: channelID, lease: lease)
            return
        }

        guard queuedInputFlushTasks[channelID] == nil else { return }
        queuedInputFlushTasks[channelID] = Task { [weak self] in
            do {
                try await Task.sleep(
                    nanoseconds: TerminalInputDispatchPolicy.coalescingDelayNanoseconds
                )
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            await self?.flushQueuedInput(channelID: channelID, lease: lease)
        }
    }

    func resize(channelID: UInt64, cols: UInt32, rows: UInt32) async {
        let ptr = await performFFI {
            orbit_terminal_resize(channelID, cols, rows)
        }
        _ = parseOK("resize", rawPtr: ptr)
    }

    func unbindAndClose(channelID: UInt64) async {
        invalidateInputOwnership(for: channelID)
        firstFrameSpans.removeValue(forKey: channelID)?.cancel()
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
        let hasVisibleSubscriber = textHandlers[channelID] != nil || byteHandlers[channelID] != nil
        await chunkBuffer.ingest(
            channelID: channelID,
            bytes: data,
            queueForDelivery: hasVisibleSubscriber
        )
        if hasVisibleSubscriber {
            startFlushLoopIfNeeded()
        }
    }

    /// Starts at a successfully opened terminal channel and ends only after
    /// its first bytes have been handed to the platform terminal view.
    func beginFirstFrameMeasurement(channelID: UInt64) {
        firstFrameSpans.removeValue(forKey: channelID)?.cancel()
        firstFrameSpans[channelID] = PerformanceSignpost.begin(.terminalFirstFrame)
    }

    func markFirstFrameRendered(channelID: UInt64) {
        firstFrameSpans.removeValue(forKey: channelID)?.finish()
    }

    private func installCallbackIfNeeded() {
        guard !isCallbackInstalled else { return }
        orbit_terminal_set_callback(TerminalService.callbackBridge)
        orbit_connection_set_callback(TerminalService.connectionCallbackBridge)
        isCallbackInstalled = true
    }

    private func startFlushLoopIfNeeded() {
        guard flushTask == nil else { return }
        flushTask = Task(priority: .userInitiated) { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: self?.flushIntervalNanos ?? 33_000_000)
                } catch {
                    return
                }
                guard let self else { return }
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

    private func stopFlushLoopIfIdle() {
        guard textHandlers.isEmpty, byteHandlers.isEmpty else { return }
        flushTask?.cancel()
        flushTask = nil
    }

    private func flushQueuedInputImmediately(channelID: UInt64, lease: OperationLease) {
        queuedInputFlushTasks.removeValue(forKey: channelID)?.cancel()
        guard let bytes = queuedInput.removeValue(forKey: channelID), !bytes.isEmpty else { return }
        Task { [weak self] in
            guard let self, self.ownsInput(lease, channelID: channelID) else { return }
            _ = await self.writeRaw(channelID: channelID, bytes: Array(bytes))
        }
    }

    private func flushQueuedInput(channelID: UInt64, lease: OperationLease) async {
        queuedInputFlushTasks.removeValue(forKey: channelID)
        guard let bytes = queuedInput.removeValue(forKey: channelID), !bytes.isEmpty else { return }
        guard ownsInput(lease, channelID: channelID) else { return }
        _ = await writeRaw(channelID: channelID, bytes: Array(bytes))
    }

    private func beginInputOwnership(for channelID: UInt64) {
        var owner = inputOwners[channelID] ?? OperationOwner()
        let lease = owner.begin(scope: .terminalChannel(channelID))
        inputOwners[channelID] = owner
        inputLeases[channelID] = lease
    }

    private func currentInputLease(for channelID: UInt64) -> OperationLease {
        if let lease = inputLeases[channelID], ownsInput(lease, channelID: channelID) {
            return lease
        }
        beginInputOwnership(for: channelID)
        // `beginInputOwnership` always installs a matching lease.
        return inputLeases[channelID]!
    }

    private func invalidateInputOwnership(for channelID: UInt64) {
        var owner = inputOwners[channelID] ?? OperationOwner()
        owner.invalidate()
        inputOwners[channelID] = owner
        inputLeases.removeValue(forKey: channelID)
        queuedInputFlushTasks.removeValue(forKey: channelID)?.cancel()
        queuedInput.removeValue(forKey: channelID)
    }

    private func ownsInput(_ lease: OperationLease, channelID: UInt64) -> Bool {
        inputOwners[channelID]?.owns(lease, scope: .terminalChannel(channelID)) == true
    }

    private func receiveTerminalBytes(channelID: UInt64, data: Data) async {
        let hasVisibleSubscriber = textHandlers[channelID] != nil || byteHandlers[channelID] != nil
        await chunkBuffer.ingest(
            channelID: channelID,
            bytes: data,
            queueForDelivery: hasVisibleSubscriber
        )
        if hasVisibleSubscriber {
            startFlushLoopIfNeeded()
        }
    }

    private static let callbackBridge: @convention(c) (UInt64, UnsafePointer<UInt8>?, Int) -> Void = { channelID, dataPtr, len in
        guard let dataPtr, len > 0 else { return }
        let data = Data(bytes: dataPtr, count: len)
        Task(priority: .userInitiated) {
            await TerminalService.shared.receiveTerminalBytes(channelID: channelID, data: data)
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
        guard let raw = parseRaw(ptr),
              let payload = try? RustFFI.parseOKPayload(raw) else { return nil }
        return RustFFI.parseSessionID(payload)
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
