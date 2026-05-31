import SwiftUI

struct WorkstationLayoutMetrics {
    static func widths(
        totalWidth: CGFloat,
        leftCollapsed: Bool,
        rightCollapsed: Bool
    ) -> (left: CGFloat, middle: CGFloat, right: CGFloat) {
        let dividerSpace: CGFloat = 2
        let available = max(0, totalWidth - dividerSpace)
        let leftRail: CGFloat = 34
        let rightRail: CGFloat = 34

        var left = leftCollapsed ? leftRail : min(max(220, available * 0.20), 320)
        var right = rightCollapsed ? rightRail : min(max(260, available * 0.30), 420)
        let minMiddle: CGFloat = 420

        // Keep the terminal usable on narrower macOS windows by shrinking side panels
        // before the center workspace is allowed to overflow.
        let sideMinimum = (leftCollapsed ? leftRail : 200) + (rightCollapsed ? rightRail : 220)
        let targetMiddle = min(minMiddle, max(0, available - sideMinimum))
        let overflow = max(0, left + right + targetMiddle - available)
        if overflow > 0 {
            let rightFloor = rightCollapsed ? rightRail : 220
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
