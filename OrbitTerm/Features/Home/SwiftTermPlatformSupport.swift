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

final class ContextMenuTerminalView: TerminalView {
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
        menu.addItem(withTitle: "剪切", action: #selector(handleCutAction(_:)), keyEquivalent: "")
        menu.addItem(withTitle: "全选", action: #selector(selectAll(_:)), keyEquivalent: "")
        menu.items.forEach { $0.target = self }
        return menu
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

final class ShortcutAccessoryView: UIView {
    var onSendBytes: (([UInt8]) -> Void)?
    var onHideKeyboard: (() -> Void)?

    override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: 44)
    }

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        backgroundColor = .secondarySystemBackground

        let scroll = UIScrollView()
        scroll.showsHorizontalScrollIndicator = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        let stack = UIStackView()
        stack.axis = .horizontal
        stack.alignment = .center
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor, constant: 10),
            stack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor, constant: -10),
            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: 6),
            stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -6),
            stack.heightAnchor.constraint(equalTo: scroll.frameLayoutGuide.heightAnchor, constant: -12),
        ])

        let shortcuts: [(String, [UInt8])] = [
            ("Tab", [9]),
            ("Ctrl+C", [3]),
            ("Esc", [27]),
            ("Ctrl+D", [4]),
        ]

        for (title, bytes) in shortcuts {
            let button = makeButton(title: title)
            button.addAction(UIAction { [weak self] _ in
                self?.onSendBytes?(bytes)
            }, for: .touchUpInside)
            stack.addArrangedSubview(button)
        }

        let hideButton = makeButton(title: "收起")
        hideButton.addAction(UIAction { [weak self] _ in
            self?.onHideKeyboard?()
        }, for: .touchUpInside)
        stack.addArrangedSubview(hideButton)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
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
