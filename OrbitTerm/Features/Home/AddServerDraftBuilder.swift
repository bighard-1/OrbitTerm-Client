import Foundation

struct AddServerDraftInput {
    let name: String
    let group: String
    let tags: [String]
    let host: String
    let port: Int
    let username: String
    let authMethod: ServerAuthMethod
    let transport: ServerTransportProtocol
    let networkDeviceProfile: NetworkDeviceProfile
    let allowPasswordFallback: Bool
    let password: String
    let privateKeyContent: String
    let privateKeyPassphrase: String
    let jumpHost: JumpHostConfiguration?
    let jumpHostCredentials: ServerCredentials?
    let editingServer: ServerEntry?
}

struct AddServerDraft {
    let server: ServerEntry
    let credentials: ServerCredentials
    let jumpHostCredentials: ServerCredentials?
}

enum AddServerDraftBuilder {
    static func build(from input: AddServerDraftInput) -> AddServerDraft {
        let credentials = ServerCredentials(
            password: input.password,
            privateKeyContent: input.transport == .ssh ? input.privateKeyContent.trimmingCharacters(in: .whitespacesAndNewlines) : "",
            privateKeyPassphrase: input.transport == .ssh ? input.privateKeyPassphrase : ""
        )

        let server = makeServer(from: input)
        return AddServerDraft(
            server: server,
            credentials: credentials,
            jumpHostCredentials: input.jumpHostCredentials
        )
    }

    private static func makeServer(from input: AddServerDraftInput) -> ServerEntry {
        let normalizedAuthMethod: ServerAuthMethod = input.transport == .telnet ? .password : input.authMethod
        let normalizedFallback = input.transport == .telnet ? true : input.allowPasswordFallback

        if let existing = input.editingServer {
            return ServerEntry(
                id: existing.id,
                name: input.name.trimmingCharacters(in: .whitespacesAndNewlines),
                group: input.group.trimmingCharacters(in: .whitespacesAndNewlines),
                tags: input.tags,
                host: input.host.trimmingCharacters(in: .whitespacesAndNewlines),
                port: input.port,
                username: input.username.trimmingCharacters(in: .whitespacesAndNewlines),
                authMethod: normalizedAuthMethod,
                transport: input.transport,
                networkDeviceProfile: input.networkDeviceProfile,
                allowPasswordFallback: normalizedFallback,
                credentialID: existing.credentialID,
                jumpHost: input.transport == .ssh ? input.jumpHost : nil,
                createdAt: existing.createdAt
            )
        }

        return ServerEntry(
            name: input.name.trimmingCharacters(in: .whitespacesAndNewlines),
            group: input.group.trimmingCharacters(in: .whitespacesAndNewlines),
            tags: input.tags,
            host: input.host.trimmingCharacters(in: .whitespacesAndNewlines),
            port: input.port,
            username: input.username.trimmingCharacters(in: .whitespacesAndNewlines),
            authMethod: normalizedAuthMethod,
            transport: input.transport,
            networkDeviceProfile: input.networkDeviceProfile,
            allowPasswordFallback: normalizedFallback,
            jumpHost: input.transport == .ssh ? input.jumpHost : nil
        )
    }
}
