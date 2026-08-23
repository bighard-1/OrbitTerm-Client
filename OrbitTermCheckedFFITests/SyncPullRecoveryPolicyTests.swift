import XCTest
import CryptoKit

final class SyncPullRecoveryPolicyTests: XCTestCase {
    private struct RemoteRecord: Equatable {
        let recordID: UInt
        let assetID: String?
        let state: String
    }

    func testWindowsSshKeyEnvelopeUsesSharedV1Contract() throws {
        let privateKey = "-----BEGIN OPENSSH PRIVATE KEY-----\ntest\n-----END OPENSSH PRIVATE KEY-----\n"
        let fingerprint = "SHA256:" + Data(SHA256.hash(data: Data(privateKey.utf8))).base64EncodedString()
            .trimmingCharacters(in: CharacterSet(charactersIn: "="))
        let json = """
        {"kind":"orbit_ssh_keys","version":1,"updatedAtUnix":1770000000,"keys":[{"id":"ABCDEF00-1234-5678-9ABC-DEF012345678","name":"Work Key","format":"OpenSSH","materialFingerprint":"\(fingerprint)","createdAtUnix":1760000000,"updatedAtUnix":1770000000,"assignedAssetIds":["11111111-2222-3333-4444-555555555555"],"privateKey":"-----BEGIN OPENSSH PRIVATE KEY-----\\ntest\\n-----END OPENSSH PRIVATE KEY-----\\n","passphrase":""}],"tombstones":[]}
        """
        let envelope = try XCTUnwrap(SshKeySyncContract.decode(Data(json.utf8)))
        XCTAssertEqual(envelope.keys.count, 1)
        XCTAssertEqual(envelope.keys.first?.id, "abcdef00-1234-5678-9abc-def012345678")
    }

    func testSshKeyVaultMergeHonorsTombstonesAndAccountScopesRemainDistinct() throws {
        let privateKey = "-----BEGIN OPENSSH PRIVATE KEY-----\ntest\n-----END OPENSSH PRIVATE KEY-----\n"
        let fingerprint = "SHA256:" + Data(SHA256.hash(data: Data(privateKey.utf8))).base64EncodedString()
            .trimmingCharacters(in: CharacterSet(charactersIn: "="))
        let id = UUID().uuidString.lowercased()
        let key = SshKeySyncWire(id: id, name: "测试密钥", format: "OpenSSH", materialFingerprint: fingerprint,
            createdAtUnix: 100, updatedAtUnix: 101, assignedAssetIds: [], privateKey: privateKey, passphrase: "")
        let inserted = SshKeyMergePolicy.merge(local: [], localOnly: [], tombstones: [:], remote:
            .init(kind: SshKeySyncContract.marker, version: 1, updatedAtUnix: 101, keys: [key], tombstones: []))
        XCTAssertEqual(inserted.keys.map(\.id), [id])
        let deleted = SshKeyMergePolicy.merge(local: inserted.keys, localOnly: [], tombstones: inserted.tombstones, remote:
            .init(kind: SshKeySyncContract.marker, version: 1, updatedAtUnix: 102, keys: [],
                tombstones: [.init(id: id, deletedAtUnix: 102)]))
        XCTAssertTrue(deleted.keys.isEmpty)
        XCTAssertNotEqual(
            AccountScope(username: "first@example.invalid")?.storageIdentifier,
            AccountScope(username: "second@example.invalid")?.storageIdentifier
        )
    }

    func testPortForwardProfileContractNeverCarriesLiveTunnelState() throws {
        let profileJSON = """
        {"kind":"orbit_port_forwards","version":1,"updatedAtUnix":1770000000,"profiles":[{"id":"ABCDEF00-1234-5678-9ABC-DEF012345678","assetId":"11111111-2222-3333-4444-555555555555","name":" db ","mode":"local","bindHost":"127.0.0.1","bindPort":15432,"destinationHost":"127.0.0.1","destinationPort":5432,"createdAtUnix":1760000000,"updatedAtUnix":1770000000}],"tombstones":[]}
        """
        let envelope = try XCTUnwrap(PortForwardProfileSyncContract.decode(Data(profileJSON.utf8)))
        XCTAssertEqual(envelope.profiles.first?.name, "db")
        XCTAssertFalse(String(decoding: try PortForwardProfileSyncContract.encode(envelope), as: UTF8.self).contains("tunnelId"))

        let liveJSON = profileJSON.replacingOccurrences(
            of: "\"updatedAtUnix\":1770000000}",
            with: "\"updatedAtUnix\":1770000000,\"tunnelId\":7}"
        )
        XCTAssertNil(PortForwardProfileSyncContract.decode(Data(liveJSON.utf8)))
    }

    func testEmptyLocalCacheAndEmptyIncrementalPageRequestsFullPull() {
        XCTAssertTrue(
            SyncPullRecoveryPolicy.shouldPerformFullPull(
                localAssetCount: 0,
                incrementalResponseHadChanges: false
            )
        )
    }

    func testExistingLocalCacheDoesNotRequestFullPullForEmptyIncrementalPage() {
        XCTAssertFalse(
            SyncPullRecoveryPolicy.shouldPerformFullPull(
                localAssetCount: 1,
                incrementalResponseHadChanges: false
            )
        )
    }

    func testAnyIncrementalChangeAvoidsRedundantFullPullForEmptyCache() {
        XCTAssertFalse(
            SyncPullRecoveryPolicy.shouldPerformFullPull(
                localAssetCount: 0,
                incrementalResponseHadChanges: true
            )
        )
    }

    func testCloudMissingLocalAssetsRequireExplicitPublication() {
        XCTAssertEqual(
            SyncPullRecoveryPolicy.localAssetIDsPendingExplicitPublication(
                localAssetIDs: ["a", "b", "c"],
                cloudKnownAssetIDs: ["a"]
            ),
            ["b", "c"]
        )
    }

    func testCloudKnownAssetsAndEmptyLocalCacheDoNotOfferPublicationRecovery() {
        XCTAssertEqual(
            SyncPullRecoveryPolicy.localAssetIDsPendingExplicitPublication(
                localAssetIDs: ["a"],
                cloudKnownAssetIDs: ["a"]
            ),
            []
        )
        XCTAssertEqual(
            SyncPullRecoveryPolicy.localAssetIDsPendingExplicitPublication(
                localAssetIDs: [],
                cloudKnownAssetIDs: ["a"]
            ),
            []
        )
    }

    func testSnippetOnlyCloudStillOffersExplicitLocalAssetPublication() {
        XCTAssertEqual(
            SyncPullRecoveryPolicy.localAssetIDsPendingExplicitPublication(
                localAssetIDs: ["local-a", "local-b"],
                cloudKnownAssetIDs: []
            ),
            ["local-a", "local-b"]
        )
    }

    func testUndecryptableRemoteAssetsRequestMasterPasswordRecoveryInsteadOfPublication() {
        XCTAssertTrue(
            SyncPullRecoveryPolicy.remoteAssetsRequireMasterPasswordRecovery(
                remoteAssetCount: 2,
                decodedRemoteAssetCount: 0
            )
        )
        XCTAssertFalse(
            SyncPullRecoveryPolicy.remoteAssetsRequireMasterPasswordRecovery(
                remoteAssetCount: 2,
                decodedRemoteAssetCount: 1
            )
        )
    }

    func testVerificationKeepsOnlyPublishedAssetIDsMissingFromFollowUpInventory() {
        XCTAssertEqual(
            SyncPullRecoveryPolicy.unverifiedPublishedAssetIDs(
                attemptedLocalAssetIDs: ["a", "b", "c"],
                cloudKnownAssetIDs: ["a", "c", "remote-tombstone"]
            ),
            ["b"]
        )
    }

    func testTrashWinsWhenActiveAndDeletedRecordsUseDifferentRecordIDs() {
        let assetID = UUID().uuidString
        let active = RemoteRecord(recordID: 101, assetID: assetID, state: "active")
        let deleted = RemoteRecord(recordID: 202, assetID: assetID.lowercased(), state: "deleted")

        let merged = SyncPullRecoveryPolicy.mergeRemoteInventory(
            activeItems: [active],
            trashItems: [deleted],
            assetID: { $0.assetID },
            recordID: { String($0.recordID) }
        )

        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged.first?.recordID, deleted.recordID)
        XCTAssertEqual(merged.first?.state, "deleted")
    }

    func testTrashIdentityIgnoresUuidWhitespaceAndCasing() {
        let assetID = UUID().uuidString
        let active = RemoteRecord(recordID: 101, assetID: "  \(assetID.uppercased())  ", state: "active")
        let deleted = RemoteRecord(recordID: 202, assetID: assetID.lowercased(), state: "deleted")

        let merged = SyncPullRecoveryPolicy.mergeRemoteInventory(
            activeItems: [active],
            trashItems: [deleted],
            assetID: { $0.assetID },
            recordID: { String($0.recordID) }
        )

        XCTAssertEqual(merged.map(\.recordID), [202])
    }

    func testRecordsWithoutAssetIdentityRemainDistinct() {
        let first = RemoteRecord(recordID: 101, assetID: nil, state: "active")
        let second = RemoteRecord(recordID: 202, assetID: nil, state: "deleted")

        let merged = SyncPullRecoveryPolicy.mergeRemoteInventory(
            activeItems: [first],
            trashItems: [second],
            assetID: { $0.assetID },
            recordID: { String($0.recordID) }
        )

        XCTAssertEqual(merged.map(\.recordID), [101, 202])
    }

    func testMigratedTombstoneRecordIsNeverPermanentlyPurged() {
        XCTAssertEqual(
            SyncPullRecoveryPolicy.remoteRecordIDsSafeToPurge(
                candidateRecordIDs: [10, 11, 12],
                migratedTombstoneRecordIDs: [11]
            ),
            [10, 12]
        )
    }

    func testTCPLatencyPolicyRejectsFailureAndUsesRecentMedian() {
        XCTAssertNil(TCPLatencySamplePolicy.stabilized(current: nil, recent: [12, 14]))
        XCTAssertEqual(
            TCPLatencySamplePolicy.stabilized(current: 160, recent: [12, 14]),
            14
        )
        XCTAssertEqual(
            TCPLatencySamplePolicy.stabilized(current: 18, recent: [nil, 16]),
            18
        )
    }

    func testTCPLatencyStatisticsReportConnectionFailuresAndPercentiles() {
        let statistics = TCPLatencySamplePolicy.statistics(samples: [10, nil, 20, 30, 40])
        XCTAssertEqual(statistics.attemptedCount, 5)
        XCTAssertEqual(statistics.successfulCount, 4)
        XCTAssertEqual(statistics.failurePercent, 20)
        XCTAssertEqual(statistics.p50Milliseconds, 20)
        XCTAssertEqual(statistics.p95Milliseconds, 40)
    }

    func testMonitorAutoRefreshDefaultsOnAndHonorsExplicitPause() {
        let suiteName = "MonitorPollingPolicyTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertTrue(MonitorRefreshPreference.isEnabled(userDefaults: defaults))
        defaults.set(false, forKey: MonitorRefreshPreference.storageKey)
        XCTAssertFalse(MonitorRefreshPreference.isEnabled(userDefaults: defaults))
    }
}
