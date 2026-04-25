import Foundation

@MainActor
final class TerminalService {
    static let shared = TerminalService()

    private var handlers: [UInt64: (String) -> Void] = [:]
    private var isCallbackInstalled = false

    private init() {
        installCallbackIfNeeded()
    }

    func bind(channelID: UInt64, onData: @escaping (String) -> Void) {
        handlers[channelID] = onData
    }

    func unbind(channelID: UInt64) {
        handlers.removeValue(forKey: channelID)
    }

    func openPTY(sessionOrChannelID: UInt64, cols: UInt32, rows: UInt32) async -> UInt64? {
        installCallbackIfNeeded()
        guard let ptyID = parseChannelID(
            from: "pty".withCString { typePtr in
                orbit_request_channel(sessionOrChannelID, typePtr)
            }
        ) else {
            return nil
        }

        _ = parseOK("resize") {
            orbit_terminal_resize(ptyID, cols, rows)
        }
        return ptyID
    }

    func write(channelID: UInt64, text: String) async -> Bool {
        let bytes = Array(text.utf8)
        return await writeRaw(channelID: channelID, bytes: bytes)
    }

    func writeRaw(channelID: UInt64, bytes: [UInt8]) async -> Bool {
        bytes.withUnsafeBufferPointer { buf in
            parseOK("write") {
                orbit_terminal_write(channelID, buf.baseAddress, bytes.count)
            }
        }
    }

    func resize(channelID: UInt64, cols: UInt32, rows: UInt32) async {
        _ = parseOK("resize") {
            orbit_terminal_resize(channelID, cols, rows)
        }
    }

    func unbindAndClose(channelID: UInt64) async {
        unbind(channelID: channelID)
        _ = parseOK("close") {
            orbit_terminal_close(channelID)
        }
    }

    private func installCallbackIfNeeded() {
        guard !isCallbackInstalled else { return }
        orbit_terminal_set_callback(TerminalService.callbackBridge)
        isCallbackInstalled = true
    }

    private static let callbackBridge: @convention(c) (UInt64, UnsafePointer<UInt8>?, Int) -> Void = { channelID, dataPtr, len in
        guard let dataPtr, len > 0 else { return }
        let data = Data(bytes: dataPtr, count: len)
        let text = String(decoding: data, as: UTF8.self)
        Task { @MainActor in
            TerminalService.shared.handlers[channelID]?(text)
        }
    }

    private func parseChannelID(from ptr: UnsafeMutablePointer<CChar>?) -> UInt64? {
        guard let raw = parseRaw(ptr), raw.hasPrefix("OK:") else { return nil }
        let payload = String(raw.dropFirst(3))
        return UInt64(payload)
    }

    private func parseOK(_ action: String, _ call: () -> UnsafeMutablePointer<CChar>?) -> Bool {
        guard let raw = parseRaw(call()) else { return false }
        return raw.hasPrefix("OK:")
    }

    private func parseRaw(_ ptr: UnsafeMutablePointer<CChar>?) -> String? {
        guard let ptr else { return nil }
        defer { orbit_free_string(ptr) }
        return String(cString: ptr)
    }
}
