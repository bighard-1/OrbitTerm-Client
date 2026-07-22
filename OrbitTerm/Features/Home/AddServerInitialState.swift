import Foundation

struct AddServerInitialState {
    let name: String
    let group: String
    let tagsText: String
    let host: String
    let portText: String
    let username: String
    let authMethod: ServerAuthMethod
    let transport: ServerTransportProtocol
    let networkDeviceProfile: NetworkDeviceProfile
    let allowPasswordFallback: Bool
    let password: String
    let privateKeyContent: String
    let privateKeyPassphrase: String
    let keyInputMode: KeyInputMode
    let testStatus: String

    static func editing(server: ServerEntry, credentials: ServerCredentials?) -> AddServerInitialState {
        let transport = server.transport
        let privateKey = credentials?.privateKeyContent ?? ""

        return AddServerInitialState(
            name: server.name,
            group: server.group,
            tagsText: server.tags.joined(separator: ", "),
            host: server.host,
            portText: String(server.port),
            username: server.username,
            authMethod: transport == .telnet ? .password : server.authMethod,
            transport: transport,
            networkDeviceProfile: server.networkDeviceProfile,
            allowPasswordFallback: server.allowPasswordFallback,
            password: credentials?.password ?? "",
            privateKeyContent: privateKey,
            privateKeyPassphrase: credentials?.privateKeyPassphrase ?? "",
            keyInputMode: privateKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .paste : .paste,
            testStatus: "已载入现有凭据"
        )
    }

    static func prefill(_ prefill: ServerAddPrefill) -> AddServerInitialState {
        AddServerInitialState(
            name: prefill.name,
            group: prefill.group,
            tagsText: "",
            host: prefill.host,
            portText: String(prefill.port),
            username: prefill.username,
            authMethod: .password,
            transport: .ssh,
            networkDeviceProfile: .auto,
            allowPasswordFallback: true,
            password: "",
            privateKeyContent: "",
            privateKeyPassphrase: "",
            keyInputMode: .paste,
            testStatus: "已通过链接填充连接信息，请先测试再保存"
        )
    }
}
