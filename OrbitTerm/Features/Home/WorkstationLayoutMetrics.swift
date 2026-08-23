import SwiftUI

struct WorkstationLayoutMetrics {
    static func widths(
        totalWidth: CGFloat,
        leftCollapsed: Bool,
        rightCollapsed: Bool,
        preferredLeft: CGFloat = 260,
        preferredRight: CGFloat = 340
    ) -> (left: CGFloat, middle: CGFloat, right: CGFloat) {
        let dividerSpace: CGFloat = 12
        let available = max(0, totalWidth - dividerSpace)
        let leftRail: CGFloat = 34
        let rightRail: CGFloat = 34

        var left = leftCollapsed ? leftRail : min(max(220, preferredLeft), 320)
        var right = rightCollapsed ? rightRail : min(max(280, preferredRight), 420)
        let minMiddle: CGFloat = 520

        // Keep the terminal usable on narrower macOS windows by shrinking side panels
        // before the center workspace is allowed to overflow.
        let sideMinimum = (leftCollapsed ? leftRail : 200) + (rightCollapsed ? rightRail : 240)
        let targetMiddle = min(minMiddle, max(0, available - sideMinimum))
        let overflow = max(0, left + right + targetMiddle - available)
        if overflow > 0 {
            let rightFloor = rightCollapsed ? rightRail : 240
            let rightShrink = min(overflow, max(0, right - rightFloor))
            right -= rightShrink

            let remainingOverflow = overflow - rightShrink
            let leftFloor = leftCollapsed ? leftRail : 200
            let leftShrink = min(remainingOverflow, max(0, left - leftFloor))
            left -= leftShrink
        }

        let middle = max(0, available - left - right)
        return (left, middle, right)
    }
}
