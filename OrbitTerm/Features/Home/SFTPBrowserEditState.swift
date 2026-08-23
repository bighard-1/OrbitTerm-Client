import Foundation

struct SFTPTextFormat: Equatable {
    enum LineEnding: String {
        case lf = "LF"
        case crlf = "CRLF"
        case cr = "CR"
    }

    let lineEnding: LineEnding
    let hasUTF8BOM: Bool

    var displayLabel: String {
        "UTF-8\(hasUTF8BOM ? " BOM" : "") · \(lineEnding.rawValue)"
    }

    static func detectAndNormalize(_ content: String) -> (content: String, format: SFTPTextFormat) {
        let hasBOM = content.first == "\u{FEFF}"
        let source = hasBOM ? String(content.dropFirst()) : content
        let crlfCount = source.components(separatedBy: "\r\n").count - 1
        let withoutCRLF = source.replacingOccurrences(of: "\r\n", with: "")
        let crCount = withoutCRLF.filter { $0 == "\r" }.count
        let lfCount = withoutCRLF.filter { $0 == "\n" }.count
        let ending: LineEnding = crlfCount >= max(crCount, lfCount) && crlfCount > 0
            ? .crlf
            : crCount > lfCount ? .cr : .lf
        let normalized = source
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        return (normalized, SFTPTextFormat(lineEnding: ending, hasUTF8BOM: hasBOM))
    }

    func serialize(_ content: String) -> String {
        let normalized = content
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let body = switch lineEnding {
        case .lf: normalized
        case .crlf: normalized.replacingOccurrences(of: "\n", with: "\r\n")
        case .cr: normalized.replacingOccurrences(of: "\n", with: "\r")
        }
        return hasUTF8BOM ? "\u{FEFF}" + body : body
    }
}

struct SFTPInAppDocument: Identifiable {
    enum Mode {
        case preview
        case editing
    }

    let item: FileItem
    let originalContent: String
    let textFormat: SFTPTextFormat
    var draftContent: String
    var mode: Mode = .preview
    var isSaving = false
    var errorMessage: String?

    var id: String { item.id }
    var hasUnsavedChanges: Bool { draftContent != originalContent }
}

struct SFTPBrowserEditState {
    var renameItem: FileItem?
    var renameName: String = ""
    var chmodItem: FileItem?
    var chmodMode: String = ""
    var isCreatingFolder = false
    var isCreatingFile = false
    var createFolderName: String = ""
    var createFileName: String = ""
    var document: SFTPInAppDocument?

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

    mutating func presentDocument(item: FileItem, content: String) {
        let decoded = SFTPTextFormat.detectAndNormalize(content)
        document = SFTPInAppDocument(
            item: item,
            originalContent: decoded.content,
            textFormat: decoded.format,
            draftContent: decoded.content
        )
    }

    mutating func beginDocumentEditing() {
        document?.mode = .editing
        document?.errorMessage = nil
    }

    mutating func updateDocumentDraft(_ content: String) {
        document?.draftContent = content
    }

    mutating func setDocumentSaving(_ saving: Bool) {
        document?.isSaving = saving
        if saving { document?.errorMessage = nil }
    }

    mutating func setDocumentError(_ message: String) {
        document?.isSaving = false
        document?.errorMessage = message
    }

    mutating func closeDocument() {
        document = nil
    }
}
