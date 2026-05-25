import SwiftUI
import SwiftTerm
#if os(macOS)
import AppKit
#else
import UIKit
#endif

enum TerminalSearchAction: Equatable {
    case next
    case previous
    case clear
}

struct TerminalSearchCommand: Equatable {
    let id = UUID()
    let action: TerminalSearchAction
}

struct SwiftTermTerminalView: View {
    let channelID: UInt64?
    let onResize: (Int, Int) -> Void
    let onInput: ([UInt8]) -> Void
    let searchText: String
    let searchCommand: TerminalSearchCommand?
    let onSearchFeedback: (Bool, TerminalSearchAction) -> Void
    @AppStorage(TerminalThemeManager.storageKey) private var terminalThemeID: String = TerminalThemeManager.defaultThemeID
    @AppStorage("orbitterm.terminal.font.size") private var terminalFontSize: Double = 13

    var body: some View {
        let theme = TerminalThemeManager.theme(for: terminalThemeID)
        Group {
            if let channelID {
                TerminalRepresentable(
                    channelID: channelID,
                    theme: theme,
                    fontSize: terminalFontSize,
                    onResize: onResize,
                    onInput: onInput,
                    searchText: searchText,
                    searchCommand: searchCommand,
                    onSearchFeedback: onSearchFeedback
                )
            } else {
                ContentUnavailableView(
                    "终端未连接",
                    systemImage: "terminal",
                    description: Text("连接成功后将自动进入 ANSI 终端")
                )
            }
        }
    }
}

extension Notification.Name {
    static let terminalFontScaleUp = Notification.Name("orbitterm.terminal.font.scale.up")
    static let terminalFontScaleDown = Notification.Name("orbitterm.terminal.font.scale.down")
}

#if os(macOS)
private typealias PlatformRepresentable = NSViewRepresentable
private typealias PlatformView = TerminalView
private typealias PlatformColor = NSColor
private typealias PlatformFont = NSFont

private final class ContextMenuTerminalView: TerminalView {
    @objc private func handleCutAction(_ sender: Any?) {
        copy(sender ?? self)
        // SwiftTerm 默认 cut 为 no-op，这里以 Ctrl+U 清空当前输入行，符合终端常见行为。
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
private typealias PlatformRepresentable = UIViewRepresentable
private typealias PlatformView = TerminalView
private typealias PlatformColor = UIColor
private typealias PlatformFont = UIFont

private final class ShortcutAccessoryView: UIView {
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

private struct TerminalRepresentable: PlatformRepresentable {
    let channelID: UInt64
    let theme: TerminalTheme
    let fontSize: Double
    let onResize: (Int, Int) -> Void
    let onInput: ([UInt8]) -> Void
    let searchText: String
    let searchCommand: TerminalSearchCommand?
    let onSearchFeedback: (Bool, TerminalSearchAction) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onResize: onResize, onInput: onInput, onSearchFeedback: onSearchFeedback)
    }

#if os(macOS)
    func makeNSView(context: Context) -> TerminalView {
        let view = configuredTerminalView(context: context)
        context.coordinator.attach(view: view, channelID: channelID, theme: theme, fontSize: fontSize)
        return view
    }

    func updateNSView(_ nsView: TerminalView, context: Context) {
        context.coordinator.update(
            channelID: channelID,
            view: nsView,
            theme: theme,
            fontSize: fontSize,
            searchText: searchText,
            searchCommand: searchCommand
        )
    }
#else
    func makeUIView(context: Context) -> TerminalView {
        let view = configuredTerminalView(context: context)
        context.coordinator.attach(view: view, channelID: channelID, theme: theme, fontSize: fontSize)
        DispatchQueue.main.async {
            _ = view.becomeFirstResponder()
        }
        return view
    }

    func updateUIView(_ uiView: TerminalView, context: Context) {
        context.coordinator.update(
            channelID: channelID,
            view: uiView,
            theme: theme,
            fontSize: fontSize,
            searchText: searchText,
            searchCommand: searchCommand
        )
    }
#endif

    private func configuredTerminalView(context: Context) -> TerminalView {
        #if os(macOS)
        let terminalView = ContextMenuTerminalView()
        #else
        let terminalView = TerminalView()
        #endif
        terminalView.terminalDelegate = context.coordinator
        terminalView.nativeBackgroundColor = PlatformColor.clear
        let target = CGFloat(max(8, min(24, fontSize)))
        terminalView.font = PlatformFont(name: "JetBrainsMono-Regular", size: target) ?? PlatformFont(name: "Menlo", size: target) ?? terminalView.font
        return terminalView
    }

    final class Coordinator: NSObject, TerminalViewDelegate {
        private let onResize: (Int, Int) -> Void
        private let onInput: ([UInt8]) -> Void
        private let onSearchFeedback: (Bool, TerminalSearchAction) -> Void
        private weak var terminalView: TerminalView?
        private var boundChannelID: UInt64?
        private var byteSubscriberID: UUID?
        private var appliedThemeID: String?
        private var lastSearchCommandID: UUID?

        init(
            onResize: @escaping (Int, Int) -> Void,
            onInput: @escaping ([UInt8]) -> Void,
            onSearchFeedback: @escaping (Bool, TerminalSearchAction) -> Void
        ) {
            self.onResize = onResize
            self.onInput = onInput
            self.onSearchFeedback = onSearchFeedback
        }

        func emitInput(_ bytes: [UInt8]) {
            onInput(bytes)
        }

        deinit {
            if let channelID = boundChannelID, let byteSubscriberID {
                Task { @MainActor in
                    TerminalService.shared.unbindBytes(channelID: channelID, subscriberID: byteSubscriberID)
                }
            }
        }

        func attach(view: TerminalView, channelID: UInt64, theme: TerminalTheme, fontSize: Double) {
            terminalView = view
            update(
                channelID: channelID,
                view: view,
                theme: theme,
                fontSize: fontSize,
                searchText: "",
                searchCommand: nil
            )
        }

        func update(
            channelID: UInt64,
            view: TerminalView,
            theme: TerminalTheme,
            fontSize: Double,
            searchText: String,
            searchCommand: TerminalSearchCommand?
        ) {
            terminalView = view
            applyThemeIfNeeded(theme, to: view)
            applyFontIfNeeded(fontSize: fontSize, to: view)
            let shouldRebind = boundChannelID != channelID

            if shouldRebind {
                if let old = boundChannelID, let byteSubscriberID {
                    Task { @MainActor in
                        TerminalService.shared.unbindBytes(channelID: old, subscriberID: byteSubscriberID)
                    }
                }
                byteSubscriberID = nil

                boundChannelID = channelID
                Task { @MainActor [weak self, weak view] in
                    let subscriberID = TerminalService.shared.bindBytes(channelID: channelID) { data in
                        guard let view else { return }
                        let bytes = Array(data)
                        view.feed(byteArray: bytes[...])
                        self?.terminalView = view
                    }
                    self?.byteSubscriberID = subscriberID
                }
            }

            applySearchCommandIfNeeded(searchText: searchText, searchCommand: searchCommand, view: view)
        }

        private func applyFontIfNeeded(fontSize: Double, to view: TerminalView) {
            let target = CGFloat(max(8, min(24, fontSize)))
            let current = view.font.pointSize
            guard abs(current - target) > 0.1 else { return }
            view.font = PlatformFont(name: "JetBrainsMono-Regular", size: target) ?? PlatformFont(name: "Menlo", size: target) ?? view.font
        }

        private func applySearchCommandIfNeeded(
            searchText: String,
            searchCommand: TerminalSearchCommand?,
            view: TerminalView
        ) {
            guard let searchCommand else { return }
            guard lastSearchCommandID != searchCommand.id else { return }
            lastSearchCommandID = searchCommand.id

            switch searchCommand.action {
            case .clear:
                view.clearSearch()
                onSearchFeedback(true, .clear)
            case .next:
                let term = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !term.isEmpty else {
                    onSearchFeedback(false, .next)
                    return
                }
                let found = view.findNext(term, options: SearchOptions(), scrollToResult: true)
                onSearchFeedback(found, .next)
            case .previous:
                let term = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !term.isEmpty else {
                    onSearchFeedback(false, .previous)
                    return
                }
                let found = view.findPrevious(term, options: SearchOptions(), scrollToResult: true)
                onSearchFeedback(found, .previous)
            }
        }

        private func applyThemeIfNeeded(_ theme: TerminalTheme, to view: TerminalView) {
            guard appliedThemeID != theme.id else { return }
            appliedThemeID = theme.id

            view.nativeBackgroundColor = PlatformColor(
                red: CGFloat(theme.background.r) / 255.0,
                green: CGFloat(theme.background.g) / 255.0,
                blue: CGFloat(theme.background.b) / 255.0,
                alpha: 1
            )
            view.nativeForegroundColor = PlatformColor(
                red: CGFloat(theme.foreground.r) / 255.0,
                green: CGFloat(theme.foreground.g) / 255.0,
                blue: CGFloat(theme.foreground.b) / 255.0,
                alpha: 1
            )

            let palette: [SwiftTerm.Color] = theme.ansi16.map { item in
                SwiftTerm.Color(
                    red: UInt16(item.r) * 257,
                    green: UInt16(item.g) * 257,
                    blue: UInt16(item.b) * 257
                )
            }
            view.getTerminal().installPalette(colors: palette)

#if os(macOS)
            view.needsDisplay = true
#else
            view.setNeedsDisplay(view.bounds)
#endif
        }

        func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
            onResize(newCols, newRows)
        }

        func setTerminalTitle(source: TerminalView, title: String) {
        }

        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
        }

        func send(source: TerminalView, data: ArraySlice<UInt8>) {
            onInput(Array(data))
        }

        func scrolled(source: TerminalView, position: Double) {
        }

        func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
#if os(macOS)
            if let url = URL(string: link) {
                NSWorkspace.shared.open(url)
            }
#else
            guard let url = URL(string: link) else { return }
            UIApplication.shared.open(url)
#endif
        }

        func bell(source: TerminalView) {
        }

        func clipboardCopy(source: TerminalView, content: Data) {
#if os(macOS)
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setData(content, forType: .string)
#else
            UIPasteboard.general.setData(content, forPasteboardType: "public.utf8-plain-text")
#endif
        }

        func clipboardRead(source: TerminalView) -> Data? {
#if os(macOS)
            return NSPasteboard.general.data(forType: .string)
#else
            return UIPasteboard.general.data(forPasteboardType: "public.utf8-plain-text")
#endif
        }

        func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {
        }

        func rangeChanged(source: TerminalView, startY: Int, endY: Int) {
        }
    }
}
