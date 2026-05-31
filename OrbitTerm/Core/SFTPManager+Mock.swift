import Foundation
#if os(iOS)
import UIKit
#endif

extension SFTPManager {
    static func mockItems(path: String) -> [FileItem] {
        let now = UInt64(Date().timeIntervalSince1970)
        switch path {
        case "/":
            return [
                FileItem(name: "var", size: 0, permissions: "drwxr-xr-x", permissionsOctal: 0o040755, modifiedAtUnix: now - 3600),
                FileItem(name: "home", size: 0, permissions: "drwxr-xr-x", permissionsOctal: 0o040755, modifiedAtUnix: now - 7200),
                FileItem(name: "readme.txt", size: 1_280, permissions: "-rw-r--r--", permissionsOctal: 0o100644, modifiedAtUnix: now - 90)
            ]
        case "/var":
            return [
                FileItem(name: "www", size: 0, permissions: "drwxr-xr-x", permissionsOctal: 0o040755, modifiedAtUnix: now - 200),
                FileItem(name: "log", size: 0, permissions: "drwxr-x---", permissionsOctal: 0o040750, modifiedAtUnix: now - 400)
            ]
        case "/var/www":
            return [
                FileItem(name: "index.html", size: 8_920, permissions: "-rw-r--r--", permissionsOctal: 0o100644, modifiedAtUnix: now - 20),
                FileItem(name: "assets", size: 0, permissions: "drwxr-xr-x", permissionsOctal: 0o040755, modifiedAtUnix: now - 360)
            ]
        default:
            return []
        }
    }

    func successHaptic() {
        #if os(iOS)
        let generator = UINotificationFeedbackGenerator()
        generator.prepare()
        generator.notificationOccurred(.success)
        #endif
    }
}
