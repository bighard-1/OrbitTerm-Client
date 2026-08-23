import XCTest

final class DevicePerformanceSLOTests: XCTestCase {
    func testEveryRequiredScenarioHasAnExplicitReleaseRequirement() {
        XCTAssertEqual(DevicePerformanceScenario.allCases.count, 8)
        for scenario in DevicePerformanceScenario.allCases {
            let requirement = DevicePerformanceSLO.requirement(for: scenario)
            XCTAssertGreaterThan(requirement.maximumResponseMilliseconds, 0)
            XCTAssertGreaterThan(requirement.maximumAverageCPUPercent, 0)
            XCTAssertGreaterThan(requirement.maximumPeakFootprintBytes, 0)
            XCTAssertGreaterThan(requirement.minimumFramesPerSecond, 0)
        }
    }

    func testEvaluatorAcceptsACompleteSampleWithinItsRequirement() {
        let scenario = DevicePerformanceScenario.terminalLongOutput
        let requirement = DevicePerformanceSLO.requirement(for: scenario)
        let sample = DevicePerformanceSample(
            scenario: scenario,
            responseMilliseconds: requirement.maximumResponseMilliseconds,
            averageCPUPercent: requirement.maximumAverageCPUPercent,
            peakFootprintBytes: requirement.maximumPeakFootprintBytes,
            minimumFramesPerSecond: requirement.minimumFramesPerSecond,
            animationHitches: requirement.maximumAnimationHitches
        )

        XCTAssertTrue(DevicePerformanceSLOEvaluator.violations(for: sample).isEmpty)
    }

    func testEvaluatorReportsEachExceededDimensionWithoutInspectingContent() {
        let scenario = DevicePerformanceScenario.sftpDirectoryRefresh
        let requirement = DevicePerformanceSLO.requirement(for: scenario)
        let sample = DevicePerformanceSample(
            scenario: scenario,
            responseMilliseconds: requirement.maximumResponseMilliseconds + 1,
            averageCPUPercent: requirement.maximumAverageCPUPercent + 1,
            peakFootprintBytes: requirement.maximumPeakFootprintBytes + 1,
            minimumFramesPerSecond: requirement.minimumFramesPerSecond - 1,
            animationHitches: requirement.maximumAnimationHitches + 1
        )

        XCTAssertEqual(
            Set(DevicePerformanceSLOEvaluator.violations(for: sample)),
            Set(DevicePerformanceSLOViolation.allCases)
        )
    }
}
