import Foundation

/// Bounded terminal delivery and replay storage.  This actor deliberately
/// owns no terminal handle or view callback, so high-output behavior can be
/// verified without opening an SSH session.
actor TerminalChunkBuffer {
    private var storage: [UInt64: Data] = [:]
    private var history: [UInt64: Data] = [:]

    /// Keeps bounded replay history for a detached view. Pending delivery is
    /// only accumulated while a visible subscriber exists, so a backgrounded
    /// terminal cannot build an unbounded render queue.
    func ingest(channelID: UInt64, bytes: Data, queueForDelivery: Bool) {
        guard !bytes.isEmpty else { return }
        if queueForDelivery {
            if var existing = storage[channelID] {
                existing.append(bytes)
                storage[channelID] = OperationResourceBudget.tail(
                    existing,
                    maximumBytes: OperationResourceBudget.terminalPendingBytesPerChannel
                )
            } else {
                storage[channelID] = OperationResourceBudget.tail(
                    bytes,
                    maximumBytes: OperationResourceBudget.terminalPendingBytesPerChannel
                )
            }
        }

        if var existingHistory = history[channelID] {
            existingHistory.append(bytes)
            history[channelID] = OperationResourceBudget.tail(
                existingHistory,
                maximumBytes: OperationResourceBudget.terminalReplayBytesPerChannel
            )
        } else {
            history[channelID] = OperationResourceBudget.tail(
                bytes,
                maximumBytes: OperationResourceBudget.terminalReplayBytesPerChannel
            )
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
