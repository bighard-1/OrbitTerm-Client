import Foundation

enum SFTPBrowserPathHelper {
    static func breadcrumbs(for currentPath: String) -> [SFTPBreadcrumb] {
        if currentPath == "/" {
            return [SFTPBreadcrumb(id: 0, title: "Root", path: "/", isLast: true)]
        }

        let parts = currentPath.split(separator: "/").map(String.init)
        var result: [(String, String)] = [("Root", "/")]
        var runningPath = ""

        for part in parts {
            runningPath += "/\(part)"
            result.append((part, runningPath))
        }

        return result.enumerated().map { index, element in
            SFTPBreadcrumb(
                id: index,
                title: element.0,
                path: element.1,
                isLast: index == result.count - 1
            )
        }
    }

    static func parentPath(of path: String) -> String {
        guard path != "/", !path.isEmpty else { return "/" }
        var comps = path.split(separator: "/").map(String.init)
        if !comps.isEmpty { comps.removeLast() }
        if comps.isEmpty { return "/" }
        return "/" + comps.joined(separator: "/")
    }

    static func defaultDownloadURL(fileName: String) -> URL {
#if os(macOS)
        let base = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
#else
        let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
#endif
        return base.appendingPathComponent(fileName)
    }

    static func batchDownloadDirectory() -> URL {
#if os(macOS)
        return (FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory)
            .appendingPathComponent("OrbitTerm", isDirectory: true)
#else
        return FileManager.default.temporaryDirectory
            .appendingPathComponent("OrbitTerm-Exports", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
#endif
    }
}
