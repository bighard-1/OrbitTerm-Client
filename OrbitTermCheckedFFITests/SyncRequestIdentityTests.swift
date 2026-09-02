import XCTest

final class SyncRequestIdentityTests: XCTestCase {
    func testIdenticalUploadReplayKeepsOpaqueIdentity() {
        let payload = UploadConfigRequest(
            id: 17,
            encrypted_blob_base64: "opaque-ciphertext",
            vector_clock: "{\"ios\":2}",
            asset_id: "00000000-0000-0000-0000-000000000001"
        )

        let first = SyncRequestIdentity.upload(payload)
        let replay = SyncRequestIdentity.upload(payload)
        let changed = SyncRequestIdentity.upload(UploadConfigRequest(
            id: 17,
            encrypted_blob_base64: "opaque-ciphertext",
            vector_clock: "{\"ios\":3}",
            asset_id: "00000000-0000-0000-0000-000000000001"
        ))

        XCTAssertEqual(first, replay)
        XCTAssertEqual(first.count, 64)
        XCTAssertNotEqual(first, changed)
    }

    func testMutationReplayFollowsOperationIDAcrossResponseLoss() {
        let operationID = UUID()
        let first = AssetMutationRequest(
            deviceID: UUID(),
            operationID: operationID,
            vectorClock: "{\"ios\":2}"
        )
        let replay = AssetMutationRequest(
            deviceID: UUID(),
            operationID: operationID,
            vectorClock: "{ \"ios\" : 2 }"
        )
        let next = AssetMutationRequest(
            deviceID: UUID(),
            operationID: UUID(),
            vectorClock: "{\"ios\":2}"
        )

        XCTAssertEqual(SyncRequestIdentity.mutation(first), SyncRequestIdentity.mutation(replay))
        XCTAssertNotEqual(SyncRequestIdentity.mutation(first), SyncRequestIdentity.mutation(next))
    }
}
