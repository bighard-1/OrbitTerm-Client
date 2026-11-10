import Foundation

/// The non-secret destination selected before the system file picker opens.
/// A picker callback must never silently follow a new workspace or directory.
struct SFTPUploadSelectionContext: Equatable {
    let workspaceID: UUID?
    let sessionID: UInt64
    let directory: String

    init?(workspaceID: UUID?, sessionID: UInt64?, directory: String) {
        guard let sessionID, directory.hasPrefix("/") else { return nil }
        self.workspaceID = workspaceID
        self.sessionID = sessionID
        self.directory = directory
    }

    func matches(workspaceID: UUID?, sessionID: UInt64?, directory: String) -> Bool {
        self.workspaceID == workspaceID && self.sessionID == sessionID && self.directory == directory
    }

    func remotePath(fileName: String) -> String? {
        guard !fileName.isEmpty, fileName != ".", fileName != "..",
              !fileName.contains("/"), !fileName.contains("\\"),
              !fileName.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { return nil }
        return directory == "/" ? "/\(fileName)" : "\(directory)/\(fileName)"
    }
}
