import SwiftUI

struct WorkstationLayoutMetrics {
    static func widths(
        totalWidth: CGFloat,
        leftCollapsed: Bool,
        rightCollapsed: Bool,
        preferredLeft: CGFloat = 300,
        preferredRight: CGFloat = 328
    ) -> (left: CGFloat, middle: CGFloat, right: CGFloat) {
        let dividerSpace: CGFloat = (leftCollapsed ? 0 : 6) + (rightCollapsed ? 0 : 6)
        let available = max(0, totalWidth - dividerSpace)
        let leftRail: CGFloat = 0
        let rightRail: CGFloat = 0

        let responsiveLeft = min(max(220, totalWidth * 0.234_375), 320)
        let responsiveRight = min(max(280, totalWidth * 0.256_25), 420)
        let requestedLeft = abs(preferredLeft - 300) < 0.5 ? responsiveLeft : preferredLeft
        let requestedRight = abs(preferredRight - 328) < 0.5 ? responsiveRight : preferredRight
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
