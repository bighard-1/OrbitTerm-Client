#if os(iOS)
import UIKit
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
    private struct CustomButton: Equatable {
        let id: String
        let label: String
        let section: String
    }
    private var customButtons: [CustomButton] = []
    private var onSendCustomKey: ((String) -> Void)?
    private var onManageCustomKeys: (() -> Void)?
    private var canManageCustomKeys = false

    func updateCustomKeys(_ keys: [TerminalCustomKeyRevision], onSend: ((String) -> Void)?,
                          onManage: (() -> Void)?, canManage: Bool) {
        let buttons = keys.compactMap { row in
            row.value.map { CustomButton(id: row.id, label: $0.label, section: $0.section) }
        }
        onSendCustomKey = onSend
        onManageCustomKeys = onManage
        guard buttons != customButtons || canManage != canManageCustomKeys else { return }
        customButtons = buttons
        canManageCustomKeys = canManage
        renderShortcuts()
    }

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
            layoutControl.heightAnchor.constraint(equalToConstant: 44),
            hideButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            hideButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            hideButton.widthAnchor.constraint(equalToConstant: 44),
            hideButton.heightAnchor.constraint(equalToConstant: 44),
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
        let section = layout == .common ? "common" : "symbols"
        for key in customButtons where key.section == section {
            let button = makeButton(title: key.label)
            button.accessibilityLabel = "发送自定义按键：\(key.label)"
            button.accessibilityIdentifier = "terminal.customKeys.send.\(key.id)"
            // Retain only identity, never payload bytes, in a UIKit action.
            button.addAction(UIAction { [weak self] _ in self?.onSendCustomKey?(key.id) }, for: .touchUpInside)
            shortcutStack.addArrangedSubview(button)
        }
        if canManageCustomKeys {
            let button = makeButton(title: "编辑")
            button.accessibilityLabel = "管理自定义按键"
            button.accessibilityIdentifier = "terminal.customKeys.accessoryManage"
            button.addAction(UIAction { [weak self] _ in self?.onManageCustomKeys?() }, for: .touchUpInside)
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
        button.titleLabel?.numberOfLines = 1
        button.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
        button.widthAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
        return button
    }
}
#endif
