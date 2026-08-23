import Foundation

/// Defines which terminal bytes may briefly coalesce before crossing the FFI
/// boundary. Editing characters can share one write; terminal controls must
/// retain their immediate interactive semantics.
enum TerminalInputDispatchPolicy {
    static let coalescingDelayNanoseconds: UInt64 = 4_000_000
    static let maximumCoalescedBytes = 512

    static func sendsImmediately(_ bytes: [UInt8]) -> Bool {
        guard !bytes.isEmpty else { return false }
        return bytes.count >= maximumCoalescedBytes || bytes.contains { byte in
            switch byte {
            case 0...31, 127:
                // Includes Ctrl combinations, Tab, Return, Escape, and the
                // escape-prefixed sequences used for arrow keys.
                true
            default:
                false
            }
        }
    }
}
