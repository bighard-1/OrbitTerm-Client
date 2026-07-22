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

/// A keyboard accessory must participate in UIKit's input-view layout rather
/// than behaving as an ordinary view. `UIInputView` reserves the correct space
/// above the keyboard's rounded chrome on modern iOS, where a plain `UIView`
/// can otherwise be visually clipped by the keyboard.
final class ShortcutAccessoryView: UIInputView {
    private static let height: CGFloat = 62

    var onSendBytes: (([UInt8]) -> Void)?
    var onHideKeyboard: (() -> Void)?

    private enum Layout {
        case common
        case symbols
    }

    private let layoutControl = UISegmentedControl(items: ["常用", "符号"])
    private let scrollView = UIScrollView()
    private let shortcutStack = UIStackView()
    private var layout: Layout = .common

    override var intrinsicContentSize: CGSize {
        // Keep the controls within a single, system-owned accessory row.
        CGSize(width: UIView.noIntrinsicMetric, height: Self.height)
    }

    init() {
        super.init(
            frame: CGRect(x: 0, y: 0, width: 0, height: Self.height),
            inputViewStyle: .keyboard
        )
        // iOS otherwise applies its compact default accessory height before
        // this view's arranged shortcut row has been measured. Keep one stable
        // system-owned height so no controls are clipped by the keyboard.
        allowsSelfSizing = false
        autoresizingMask = [.flexibleWidth]
        backgroundColor = .secondarySystemBackground

        layoutControl.selectedSegmentIndex = 0
        layoutControl.translatesAutoresizingMaskIntoConstraints = false
        layoutControl.accessibilityLabel = "终端快捷键布局"
        layoutControl.addTarget(self, action: #selector(changeLayout), for: .valueChanged)
        addSubview(layoutControl)

        let hideButton = makeButton(title: "⌄")
        hideButton.accessibilityLabel = "收起键盘与快捷键"
        hideButton.addAction(UIAction { [weak self] _ in
            self?.onHideKeyboard?()
        }, for: .touchUpInside)
        hideButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(hideButton)

        scrollView.showsHorizontalScrollIndicator = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scrollView)
        NSLayoutConstraint.activate([
            layoutControl.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            layoutControl.centerYAnchor.constraint(equalTo: centerYAnchor),
            layoutControl.widthAnchor.constraint(equalToConstant: 96),
            layoutControl.heightAnchor.constraint(equalToConstant: 32),
            hideButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            hideButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            hideButton.widthAnchor.constraint(equalToConstant: 36),
            hideButton.heightAnchor.constraint(equalToConstant: 32),
            scrollView.leadingAnchor.constraint(equalTo: layoutControl.trailingAnchor, constant: 8),
            scrollView.trailingAnchor.constraint(equalTo: hideButton.leadingAnchor, constant: -8),
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        shortcutStack.axis = .horizontal
        shortcutStack.alignment = .center
        shortcutStack.spacing = 8
        shortcutStack.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(shortcutStack)
        NSLayoutConstraint.activate([
            shortcutStack.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor, constant: 8),
            shortcutStack.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor, constant: -8),
            shortcutStack.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor, constant: 6),
            shortcutStack.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor, constant: -6),
            shortcutStack.heightAnchor.constraint(equalTo: scrollView.frameLayoutGuide.heightAnchor, constant: -12),
        ])

        renderShortcuts()
    }

    @objc private func changeLayout() {
        layout = layoutControl.selectedSegmentIndex == 0 ? .common : .symbols
        renderShortcuts()
    }

    private func renderShortcuts() {
        shortcutStack.arrangedSubviews.forEach {
            shortcutStack.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }

        let shortcuts: [(String, [UInt8])] = layout == .common ? [
            ("Tab", [9]),
            ("Ctrl+C", [3]),
            ("Esc", [27]),
            ("Ctrl+D", [4]),
            ("Ctrl+L", [12]),
            ("Ctrl+U", [21]),
            ("Enter", [13]),
        ] : [
            ("←", [27, 91, 68]),
            ("↑", [27, 91, 65]),
            ("↓", [27, 91, 66]),
            ("→", [27, 91, 67]),
            ("-", [45]),
            ("+", [43]),
            ("×", [42]),
            ("/", [47]),
            ("|", [124]),
            ("\\", [92]),
            ("~", [126]),
            ("=", [61]),
            ("_", [95]),
            ("$", [36]),
            ("#", [35]),
            (";", [59]),
            (":", [58]),
            ("?", [63]),
        ]

        for (title, bytes) in shortcuts {
            let button = makeButton(title: title)
            button.addAction(UIAction { [weak self] _ in
                self?.onSendBytes?(bytes)
            }, for: .touchUpInside)
            shortcutStack.addArrangedSubview(button)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override func systemLayoutSizeFitting(
        _ targetSize: CGSize,
        withHorizontalFittingPriority horizontalFittingPriority: UILayoutPriority,
        verticalFittingPriority: UILayoutPriority
    ) -> CGSize {
        CGSize(width: targetSize.width, height: Self.height)
    }

    private func makeButton(title: String) -> UIButton {
        var config = UIButton.Configuration.tinted()
        config.title = title
        config.cornerStyle = .medium
        let button = UIButton(configuration: config)
        button.titleLabel?.font = .systemFont(ofSize: 13, weight: .semibold)
        return button
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

    static func copyToClipboard(_ content: Data) {
#if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setData(content, forType: .string)
#else
        UIPasteboard.general.setData(content, forPasteboardType: "public.utf8-plain-text")
#endif
    }

    static func readClipboard() -> Data? {
#if os(macOS)
        return NSPasteboard.general.data(forType: .string)
#else
        return UIPasteboard.general.data(forPasteboardType: "public.utf8-plain-text")
#endif
    }
}
