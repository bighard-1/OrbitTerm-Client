import SwiftUI
import SwiftTerm
#if os(macOS)
import AppKit
#else
import UIKit
#endif

#if os(macOS)
typealias PlatformRepresentable = NSViewRepresentable
typealias PlatformView = TerminalView
typealias PlatformColor = NSColor
typealias PlatformFont = NSFont

final class ContextMenuTerminalView: TerminalView, NSMenuItemValidation {
    override func copy(_ sender: Any?) {
        super.copy(sender ?? self)

        // SwiftTerm performs the selection extraction. Route the resulting
        // text back through OrbitTerm's central policy so terminal output has
        // the same conditional expiry as every other terminal-copy path.
        guard let data = NSPasteboard.general.data(forType: .string) else { return }
        Task { @MainActor in
            _ = SecureClipboard.copy(data, kind: .terminalOutput)
        }
    }

    override func paste(_ sender: Any?) {
        guard let raw = NSPasteboard.general.string(forType: .string) else { return }
        let normalized = raw
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .unicodeScalars
            .filter { $0.value >= 0x20 || $0.value == 0x0A || $0.value == 0x09 }
            .map(String.init)
            .joined()
        guard !normalized.isEmpty,
              normalized.lengthOfBytes(using: .utf8) <= 8 * 1024 else { return }

        guard normalized.contains("\n") else {
            // Insert the sanitized text rather than asking AppKit to read the
            // original clipboard again; this keeps control characters out of
            // the remote PTY on both single-line and multi-line paths.
            insertText(normalized, replacementRange: NSRange(location: 0, length: 0))
            return
        }

        let lineCount = normalized.reduce(1) { $1 == "\n" ? $0 + 1 : $0 }
        let alert = NSAlert()
        alert.messageText = "确认粘贴多行终端内容"
        alert.informativeText = "检测到 \(lineCount) 行内容。“合并为单行并执行”会用分号连接每一行后执行一次；“逐行粘贴并执行”会保留换行并按原顺序执行。请确认内容可信。"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "合并为单行并执行")
        alert.addButton(withTitle: "逐行粘贴并执行")
        alert.addButton(withTitle: "取消")

        let apply: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard let self else { return }
            switch response {
            case .alertFirstButtonReturn:
                let commands = normalized
                    .split(separator: "\n", omittingEmptySubsequences: true)
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                guard !commands.isEmpty else { return }
                self.insertText(commands.joined(separator: "; ") + "\r", replacementRange: NSRange(location: 0, length: 0))
            case .alertSecondButtonReturn:
                let payload = normalized.last.map({ $0 == "\n" }) == true ? normalized : normalized + "\r"
                self.insertText(payload, replacementRange: NSRange(location: 0, length: 0))
            default:
                break
            }
        }

        if let window {
            alert.beginSheetModal(for: window, completionHandler: apply)
        } else {
            apply(alert.runModal())
        }
    }

    @objc func clearLocalTerminalDisplay(_ sender: Any?) {
        // Feed standard erase sequences into the *local* terminal emulator.
        // `resetNormalBuffer()` only replaces SwiftTerm's normal-buffer
        // reference and can leave its active display buffer unchanged. These
        // sequences instead erase the active viewport and scrollback without
        // sending a command or byte to the remote shell.
        feed(byteArray: [0x1B, 0x5B, 0x33, 0x4A, 0x1B, 0x5B, 0x32, 0x4A, 0x1B, 0x5B, 0x48][...])
        setNeedsDisplay(bounds)
    }

    @objc private func handleCutAction(_ sender: Any?) {
        copy(sender ?? self)
        if let scalar = UnicodeScalar(21) {
            insertText(String(scalar), replacementRange: NSRange(location: 0, length: 0))
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu(title: "Terminal Menu")
        menu.addItem(withTitle: "复制", action: #selector(copy(_:)), keyEquivalent: "")
        menu.addItem(withTitle: "粘贴", action: #selector(paste(_:)), keyEquivalent: "")
        menu.addItem(NSMenuItem.separator())
        let clearItem = menu.addItem(
            withTitle: "清除本地终端显示",
            action: #selector(clearLocalTerminalDisplay(_:)),
            keyEquivalent: ""
        )
        clearItem.isEnabled = true
        menu.addItem(NSMenuItem.separator())
        menu.addItem(withTitle: "剪切", action: #selector(handleCutAction(_:)), keyEquivalent: "")
        menu.addItem(withTitle: "全选", action: #selector(selectAll(_:)), keyEquivalent: "")
        menu.items.forEach { $0.target = self }
        return menu
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(clearLocalTerminalDisplay(_:)) {
            // SwiftTerm's inherited validation does not know this local action.
            // It is always safe because it only resets this view's scrollback.
            return true
        }
        return responds(to: menuItem.action)
    }

    override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(clearLocalTerminalDisplay(_:)) {
            return true
        }
        return responds(to: item.action)
    }

    override func rightMouseDown(with event: NSEvent) {
        let menu = self.menu(for: event) ?? NSMenu(title: "Terminal Menu")
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }
}
#else
typealias PlatformRepresentable = UIViewRepresentable
typealias PlatformView = TerminalView
typealias PlatformColor = UIColor
typealias PlatformFont = UIFont

final class MobileTerminalView: TerminalView {
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesBegan(touches, with: event)
        // SwiftTerm is a UIKit terminal rather than a SwiftUI TextField. Make
        // input activation explicit so tapping any terminal cell reliably opens
        // the iOS keyboard on a touch-only device.
        _ = becomeFirstResponder()
    }
}


/// Keeps terminal-only keys attached to the system keyboard lifecycle.  This
/// avoids leaving a second, SwiftUI-owned shortcut strip visible after the
/// keyboard is dismissed.
func installMobileTerminalShortcutAccessory(
    on terminal: TerminalView,
    sendBytes: @escaping ([UInt8]) -> Void
) {
    let accessory = ShortcutAccessoryView()
    accessory.onSendBytes = sendBytes
    accessory.onHideKeyboard = { [weak terminal] in
        _ = terminal?.resignFirstResponder()
    }
    terminal.inputAccessoryView = accessory
    terminal.reloadInputViews()
}
#endif

enum TerminalPlatformSupport {
    static func open(link: String) {
#if os(macOS)
        if let url = URL(string: link) {
            NSWorkspace.shared.open(url)
        }
#else
        guard let url = URL(string: link) else { return }
        UIApplication.shared.open(url)
#endif
    }

    static func copyToClipboard(_ content: Data, kind: ClipboardContentKind = .terminalOutput) {
        // Terminal delegates are not actor-isolated. Clipboard access itself is
        // always promoted to the main actor by the central policy.
        Task { @MainActor in
            _ = SecureClipboard.copy(content, kind: kind)
        }
    }

    static func readClipboard() -> Data? {
#if os(macOS)
        return NSPasteboard.general.data(forType: .string)
#else
        return UIPasteboard.general.data(forPasteboardType: "public.utf8-plain-text")
#endif
    }
}
