import Foundation

enum AddServerKeyFileLoader {
    static func loadUTF8PrivateKey(from url: URL) throws -> String {
        let didStart = url.startAccessingSecurityScopedResource()
        defer {
            if didStart {
                url.stopAccessingSecurityScopedResource()
            }
        }

        let data = try Data(contentsOf: url)
        guard let key = String(data: data, encoding: .utf8) else {
            throw AddServerKeyFileLoaderError.notUTF8
        }
        return key
    }
}

enum AddServerKeyFileLoaderError: LocalizedError {
    case notUTF8

    var errorDescription: String? {
        switch self {
        case .notUTF8:
            return "私钥文件不是 UTF-8 文本"
        }
    }
}
