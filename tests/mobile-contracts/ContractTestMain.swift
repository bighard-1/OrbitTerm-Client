import XCTest
import Foundation

@main
enum ContractTestMain {
    static func main() {
        let suite = XCTestSuite(name: "MobileContracts")
        suite.addTest(XCTestSuite(forTestCaseClass: MobileContractPolicyTests.self))
        suite.addTest(XCTestSuite(forTestCaseClass: AdministratorContactStoreTests.self))
        suite.addTest(XCTestSuite(forTestCaseClass: TerminalCustomKeyContractTests.self))
        suite.run()
        guard let run = suite.testRun, run.executionCount == 20, run.totalFailureCount == 0 else {
            exit(1)
        }
    }
}
