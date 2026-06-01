import SwiftUI

enum KeyInputMode: String, CaseIterable, Identifiable {
    case paste
    case file

    var id: String { rawValue }

    var title: String {
        switch self {
        case .paste: return "粘贴字符串"
        case .file: return "选择文件"
        }
    }
}

enum PrivateKeyValidator {
    static func isValid(_ content: String) -> Bool {
        let key = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return false }
        let pattern = #"(?s)-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----.*-----END [A-Z0-9 ]*PRIVATE KEY-----"#
        return key.range(of: pattern, options: .regularExpression) != nil
    }

    static func validationMessage(for content: String) -> String {
        if content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "未提供私钥（可选）"
        }
        return isValid(content) ? "私钥格式校验通过" : "私钥格式不合法，需包含 BEGIN/END PRIVATE KEY"
    }

    static func validationColor(for content: String) -> Color {
        if content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .secondary
        }
        return isValid(content) ? .green : .red
    }
}
