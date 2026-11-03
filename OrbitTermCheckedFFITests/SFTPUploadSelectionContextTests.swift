import XCTest

final class SFTPUploadSelectionContextTests: XCTestCase {
    func testPickerResultCannotFollowAnotherWorkspaceConnectionOrDirectory() throws {
        let workspace = UUID()
        let target = try XCTUnwrap(SFTPUploadSelectionContext(workspaceID: workspace, sessionID: 42, directory: "/upload"))
        XCTAssertTrue(target.matches(workspaceID: workspace, sessionID: 42, directory: "/upload"))
        XCTAssertFalse(target.matches(workspaceID: UUID(), sessionID: 42, directory: "/upload"))
        XCTAssertFalse(target.matches(workspaceID: workspace, sessionID: 43, directory: "/upload"))
        XCTAssertFalse(target.matches(workspaceID: workspace, sessionID: nil, directory: "/upload"))
        XCTAssertFalse(target.matches(workspaceID: workspace, sessionID: 42, directory: "/other"))
    }

    func testUploadNameStaysWithinTheOriginalDestination() throws {
        let root = try XCTUnwrap(SFTPUploadSelectionContext(workspaceID: nil, sessionID: 42, directory: "/"))
        let directory = try XCTUnwrap(SFTPUploadSelectionContext(workspaceID: nil, sessionID: 42, directory: "/upload"))
        XCTAssertEqual(root.remotePath(fileName: "virtual.txt"), "/virtual.txt")
        XCTAssertEqual(directory.remotePath(fileName: "virtual.txt"), "/upload/virtual.txt")
        for invalid in ["", ".", "..", "../outside", "a/b", "a\\b", "bad\nname", "bad\u{0}name"] {
            XCTAssertNil(directory.remotePath(fileName: invalid))
        }
        XCTAssertNil(SFTPUploadSelectionContext(workspaceID: nil, sessionID: nil, directory: "/"))
        XCTAssertNil(SFTPUploadSelectionContext(workspaceID: nil, sessionID: 42, directory: "relative"))
    }
}
