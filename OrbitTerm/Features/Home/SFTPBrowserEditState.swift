import Foundation

struct SFTPBrowserEditState {
    var renameItem: FileItem?
    var renameName: String = ""
    var chmodItem: FileItem?
    var chmodMode: String = ""
    var isCreatingFolder = false
    var isCreatingFile = false
    var createFolderName: String = ""
    var createFileName: String = ""

    var isRenaming: Bool {
        get { renameItem != nil }
        set {
            if !newValue {
                cancelRename()
            }
        }
    }

    var isChangingPermissions: Bool {
        get { chmodItem != nil }
        set {
            if !newValue {
                cancelChmod()
            }
        }
    }

    mutating func beginRename(_ item: FileItem) {
        renameItem = item
        renameName = item.name
    }

    mutating func cancelRename() {
        renameItem = nil
        renameName = ""
    }

    mutating func beginChmod(_ item: FileItem) {
        chmodItem = item
        chmodMode = String(format: "%03o", item.permissionsOctal & 0o777)
    }

    mutating func cancelChmod() {
        chmodItem = nil
        chmodMode = ""
    }

    mutating func beginCreateFolder() {
        isCreatingFolder = true
    }

    mutating func finishCreateFolder() {
        createFolderName = ""
        isCreatingFolder = false
    }

    mutating func beginCreateFile() {
        isCreatingFile = true
    }

    mutating func finishCreateFile() {
        createFileName = ""
        isCreatingFile = false
    }
}
