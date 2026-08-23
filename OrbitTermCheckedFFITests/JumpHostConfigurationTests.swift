import Foundation
import XCTest

final class JumpHostConfigurationTests: XCTestCase {
    func testPortableJumpHostRoundTripKeepsMetadataAndSeparateCredentials() throws {
        let targetCredentialID = UUID()
        let jumpCredentialID = UUID()
        let jumpHost = JumpHostConfiguration(
            host: "bastion.example.net",
            port: 2222,
            username: "jump-user",
            authMethod: .key,
            allowPasswordFallback: false,
            credentialID: jumpCredentialID
        )
        let server = ServerEntry(
            name: "private-target",
            host: "10.0.0.42",
            username: "target-user",
            authMethod: .password,
            credentialID: targetCredentialID,
            jumpHost: jumpHost
        )
        let targetCredentials = ServerCredentials(password: "target-secret")
        let jumpCredentials = ServerCredentials(
            password: "jump-secret",
            privateKeyContent: "jump-private-key",
            privateKeyPassphrase: "jump-passphrase"
        )

        let portable = server.makePortableConfig(
            savedAtUnix: 1_727_000_000,
            credentials: targetCredentials,
            jumpHostCredentials: jumpCredentials
        )

        XCTAssertEqual(server.credentialIDs, [targetCredentialID, jumpCredentialID])
        XCTAssertEqual(portable.jumpHost?.makeConfiguration(), jumpHost)
        XCTAssertEqual(portable.jumpHost?.credentials, jumpCredentials)

        let cachedMetadata = try String(
            decoding: JSONEncoder().encode(server),
            as: UTF8.self
        )
        XCTAssertFalse(cachedMetadata.contains("target-secret"))
        XCTAssertFalse(cachedMetadata.contains("jump-secret"))
        XCTAssertFalse(cachedMetadata.contains("jump-private-key"))
        XCTAssertFalse(cachedMetadata.contains("jump-passphrase"))
    }

    func testWindowsPortableEnvelopeDecodesWithAppleJumpHostContract() throws {
        let targetCredentialID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let jumpCredentialID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
        let json = """
        {
          "id": "33333333-3333-3333-3333-333333333333",
          "credentialID": "\(targetCredentialID.uuidString)",
          "name": "Windows jump asset",
          "group": "Production",
          "tags": ["windows", "jump"],
          "host": "10.0.0.42",
          "port": 22,
          "username": "target-user",
          "authMethod": "password",
          "transport": "ssh",
          "networkDeviceProfile": "auto",
          "allowPasswordFallback": false,
          "password": "target-secret",
          "privateKeyContent": "",
          "privateKeyPassphrase": "",
          "keyReference": "",
          "savedAtUnix": 1727000000,
          "jumpHost": {
            "credentialID": "\(jumpCredentialID.uuidString)",
            "host": "bastion.example.net",
            "port": 2222,
            "username": "jump-user",
            "authMethod": "key",
            "allowPasswordFallback": true,
            "password": "",
            "privateKeyContent": "jump-private-key",
            "privateKeyPassphrase": "jump-passphrase"
          }
        }
        """

        let portable = try JSONDecoder().decode(PortableServerConfig.self, from: Data(json.utf8))

        XCTAssertEqual(portable.credentialID, targetCredentialID.uuidString)
        XCTAssertEqual(portable.jumpHost?.credentialID, jumpCredentialID.uuidString)
        XCTAssertEqual(portable.jumpHost?.makeConfiguration()?.host, "bastion.example.net")
        XCTAssertEqual(portable.jumpHost?.makeConfiguration()?.port, 2222)
        XCTAssertEqual(portable.jumpHost?.credentials.privateKeyContent, "jump-private-key")
        XCTAssertEqual(portable.jumpHost?.credentials.privateKeyPassphrase, "jump-passphrase")
        XCTAssertTrue(portable.jumpHost?.hasAuthenticationMaterial == true)
    }

    func testDirectAssetKeepsPortableJumpHostAbsent() {
        let server = ServerEntry(
            name: "direct-target",
            host: "192.0.2.24",
            username: "root",
            authMethod: .password
        )

        let portable = server.makePortableConfig(
            savedAtUnix: 1_727_000_000,
            credentials: ServerCredentials(password: "target-secret")
        )

        XCTAssertNil(server.jumpHost)
        XCTAssertNil(portable.jumpHost)
        XCTAssertEqual(server.credentialIDs, [server.credentialID])
    }

    func testInvalidPortableJumpHostDoesNotProduceConnectableConfiguration() {
        let invalid = PortableJumpHostConfiguration(
            configuration: JumpHostConfiguration(
                host: "",
                username: "jump-user",
                authMethod: .password
            ),
            credentials: ServerCredentials(password: "jump-secret")
        )

        XCTAssertNil(invalid.makeConfiguration())
    }

    func testPortableJumpHostRequiresAuthenticationMaterial() {
        let portable = PortableJumpHostConfiguration(
            configuration: JumpHostConfiguration(
                host: "bastion.example.net",
                username: "jump-user",
                authMethod: .password
            ),
            credentials: ServerCredentials()
        )

        XCTAssertNotNil(portable.makeConfiguration())
        XCTAssertFalse(portable.hasAuthenticationMaterial)
    }

    func testTargetAndJumpHostCannotShareCredentialIdentifier() {
        let sharedCredentialID = UUID()
        let server = ServerEntry(
            name: "invalid-route",
            host: "10.0.0.42",
            username: "target-user",
            authMethod: .password,
            credentialID: sharedCredentialID,
            jumpHost: JumpHostConfiguration(
                host: "bastion.example.net",
                username: "jump-user",
                authMethod: .password,
                credentialID: sharedCredentialID
            )
        )

        XCTAssertFalse(server.hasDistinctCredentialIDs)
    }

    func testWindowsRemoteDesktopEnvelopeIsPreservedWithoutSshFallback() throws {
        let id = UUID()
        let credentialID = UUID()
        let server = ServerEntry(
            id: id,
            name: "Windows desktop",
            group: "Desktop",
            tags: ["RDP"],
            host: "10.0.1.25",
            port: 3389,
            username: "Administrator",
            authMethod: .password,
            transport: .rdp,
            allowPasswordFallback: false,
            credentialID: credentialID
        )
        let portable = server.makePortableConfig(
            savedAtUnix: 1_727_000_000,
            credentials: ServerCredentials(password: "rdp-secret")
        )
        let roundTripped = try JSONDecoder().decode(
            PortableServerConfig.self,
            from: JSONEncoder().encode(portable)
        )

        XCTAssertEqual(server.transport, .rdp)
        XCTAssertTrue(server.transport.requiresRemoteDesktopWorkspace)
        XCTAssertFalse(server.transport.supportsTerminalWorkspace)
        XCTAssertEqual(server.port, 3389)
        XCTAssertEqual(server.credentialID, credentialID)
        XCTAssertEqual(roundTripped.transport, "rdp")
        XCTAssertEqual(roundTripped.password, "rdp-secret")
    }
}
