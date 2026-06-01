import Foundation

struct AddServerValidationInput {
    let name: String
    let host: String
    let portText: String
    let username: String
    let authMethod: ServerAuthMethod
    let transport: ServerTransportProtocol
    let allowPasswordFallback: Bool
    let password: String
    let privateKeyContent: String
}

enum AddServerValidation {
    static func parsedPort(from portText: String) -> Int? {
        Int(portText)
    }

    static func isPortValid(_ portText: String) -> Bool {
        guard let port = parsedPort(from: portText) else { return false }
        return (1...65535).contains(port)
    }

    static func hasValidPrivateKey(_ content: String) -> Bool {
        let key = content.trimmingCharacters(in: .whitespacesAndNewlines)
        return !key.isEmpty && PrivateKeyValidator.isValid(content)
    }

    static func canSave(_ input: AddServerValidationInput) -> Bool {
        let baseValid = !input.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            !input.host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            isPortValid(input.portText) &&
            !input.username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

        guard baseValid else { return false }
        if input.transport == .telnet {
            return !input.password.isEmpty
        }

        let hasKey = hasValidPrivateKey(input.privateKeyContent)
        if !input.allowPasswordFallback && !hasKey {
            return false
        }

        switch input.authMethod {
        case .password:
            return !input.password.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .key:
            return hasKey
        }
    }

    static func canTestConnection(_ input: AddServerValidationInput) -> Bool {
        let baseReady = !input.host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            !input.username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        guard baseReady else { return false }

        if input.transport == .telnet {
            return !input.password.isEmpty
        }

        let hasKey = hasValidPrivateKey(input.privateKeyContent)
        if !input.allowPasswordFallback {
            return hasKey
        }

        return !input.password.isEmpty || hasKey
    }
}
