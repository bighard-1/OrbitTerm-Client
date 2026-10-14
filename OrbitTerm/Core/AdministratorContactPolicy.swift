import Foundation

/// Deliberately bounded product contact address, not an arbitrary mailto URL.
enum AdministratorContactPolicy {
    static let defaultEmail = "orbitterm@163.com"
    static let subject = "OrbitTerm 反馈"
    static let unavailableMessage = "未找到可用的邮件应用，可复制邮箱后发送。"

    static func validatedEmail(_ raw: String) -> String? {
        guard raw.utf8.count <= 254, raw.unicodeScalars.allSatisfy({ $0.isASCII }) else { return nil }
        let parts = raw.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2 else { return nil }
        let local = String(parts[0])
        let domain = String(parts[1]).lowercased()
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._+-")
        guard !local.isEmpty, local.utf8.count <= 64,
              local.unicodeScalars.allSatisfy({ allowed.contains($0) }),
              !local.hasPrefix("."), !local.hasSuffix("."), !local.contains("..") else { return nil }
        let labels = domain.split(separator: ".", omittingEmptySubsequences: false)
        let domainAllowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789-")
        guard labels.count >= 2, labels.allSatisfy({ label in
            !label.isEmpty && label.utf8.count <= 63 && !label.hasPrefix("-") && !label.hasSuffix("-") &&
                label.unicodeScalars.allSatisfy { domainAllowed.contains($0) }
        }) else { return nil }
        return "\(local)@\(domain)"
    }

    static func emailOrDefault(_ candidate: String?) -> String {
        candidate.flatMap(validatedEmail) ?? defaultEmail
    }

    static func mailURL(email: String) -> URL? {
        guard let validated = validatedEmail(email) else { return nil }
        // Encode the address as a path; never interpolate server data as a query.
        var components = URLComponents()
        components.scheme = "mailto"
        components.path = validated
        components.queryItems = [URLQueryItem(name: "subject", value: subject)]
        return components.url
    }
}
