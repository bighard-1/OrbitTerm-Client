import SwiftUI
#if os(macOS)
import AppKit
#endif

struct WorkstationLayoutMetrics {
    static let compactMinimumSize = CGSize(width: 820, height: 560)
    static let comfortableMinimumSize = CGSize(width: 980, height: 700)
    static let preferredWindowSize = CGSize(width: 1280, height: 800)
    static let initialWorkAreaRatio: CGFloat = 0.88

    static func initialWindowSize(for workArea: CGSize) -> CGSize {
        guard workArea.width > 0, workArea.height > 0 else {
            return preferredWindowSize
        }

        let usesCompactFloor = workArea.width < 1_280 || workArea.height < 800
        let floor = usesCompactFloor ? compactMinimumSize : comfortableMinimumSize
        let target = CGSize(
            width: min(preferredWindowSize.width, floorToPixel(workArea.width * initialWorkAreaRatio)),
            height: min(preferredWindowSize.height, floorToPixel(workArea.height * initialWorkAreaRatio))
        )
        return CGSize(
            width: min(workArea.width, max(min(floor.width, workArea.width), target.width)),
            height: min(workArea.height, max(min(floor.height, workArea.height), target.height))
        )
    }

    private static func floorToPixel(_ value: CGFloat) -> CGFloat {
        floor(value)
    }

    static func widths(
        totalWidth: CGFloat,
        leftCollapsed: Bool,
        rightCollapsed: Bool,
        preferredLeft: CGFloat = 220,
        preferredRight: CGFloat = 280
    ) -> (left: CGFloat, middle: CGFloat, right: CGFloat) {
        let dividerSpace: CGFloat = (leftCollapsed ? 0 : 6) + (rightCollapsed ? 0 : 6)
        let available = max(0, totalWidth - dividerSpace)
        let leftRail: CGFloat = 0
        let rightRail: CGFloat = 0

        let requestedLeft = preferredLeft
        let requestedRight = preferredRight
        var left = leftCollapsed ? leftRail : min(max(220, requestedLeft), 320)
        var right = rightCollapsed ? rightRail : min(max(280, requestedRight), 420)
        let minMiddle: CGFloat = 560

        // Keep the terminal usable on narrower macOS windows by shrinking side panels
        // before the center workspace is allowed to overflow.
        let sideMinimum = (leftCollapsed ? leftRail : 220) + (rightCollapsed ? rightRail : 280)
        let targetMiddle = min(minMiddle, max(0, available - sideMinimum))
        let overflow = max(0, left + right + targetMiddle - available)
        if overflow > 0 {
            let rightFloor = rightCollapsed ? rightRail : 280
            let rightShrink = min(overflow, max(0, right - rightFloor))
            right -= rightShrink

            let remainingOverflow = overflow - rightShrink
            let leftFloor = leftCollapsed ? leftRail : 220
            let leftShrink = min(remainingOverflow, max(0, left - leftFloor))
            left -= leftShrink
        }

        let middle = max(0, available - left - right)
        return (left, middle, right)
    }
}

#if os(macOS)
/// Connects SwiftUI's workstation scene to native screen geometry without
/// replacing AppKit's DPI, accessibility scaling, snapping or restoration.
struct WorkstationWindowGeometryInstaller: NSViewRepresentable {
    // Version the native restoration key when the responsive geometry contract
    // changes so a legacy 1360x840 default is not mistaken for a deliberate
    // user size forever. Subsequent user resizing is still restored normally.
    private static let autosaveName = "OrbitTerm.MainWorkstation.v2"

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async { configure(window: view.window) }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async { configure(window: view.window) }
    }

    private func configure(window: NSWindow?) {
        guard let window, window.identifier?.rawValue != Self.autosaveName else { return }
        window.identifier = NSUserInterfaceItemIdentifier(Self.autosaveName)
        window.contentMinSize = WorkstationLayoutMetrics.compactMinimumSize

        let frameKey = "NSWindow Frame \(Self.autosaveName)"
        let hasSavedFrame = UserDefaults.standard.string(forKey: frameKey) != nil
        window.setFrameAutosaveName(Self.autosaveName)
        guard !hasSavedFrame else { return }

        let workArea = (window.screen ?? NSScreen.main)?.visibleFrame.size
            ?? WorkstationLayoutMetrics.preferredWindowSize
        window.setContentSize(WorkstationLayoutMetrics.initialWindowSize(for: workArea))
        window.center()
    }
}
#endif
