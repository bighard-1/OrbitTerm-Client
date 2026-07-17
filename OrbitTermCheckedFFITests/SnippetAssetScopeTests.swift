import XCTest

final class SnippetAssetScopeTests: XCTestCase {
    func testAllAssetsScopeAllowsEveryAsset() {
        XCTAssertTrue(SnippetAssetScope.allAssets.allows(assetID: UUID()))
        XCTAssertFalse(SnippetAssetScope.allAssets.isRestricted)
    }

    func testSelectedAssetsScopeOnlyAllowsSelectedAssets() {
        let allowed = UUID()
        let other = UUID()
        let scope = SnippetAssetScope.selectedAssets([allowed])

        XCTAssertTrue(scope.isRestricted)
        XCTAssertTrue(scope.allows(assetID: allowed))
        XCTAssertFalse(scope.allows(assetID: other))
    }

    func testEmptySelectionNormalizesToAllAssets() {
        let scope = SnippetAssetScope.selectedAssets([])

        XCTAssertEqual(scope, .allAssets)
        XCTAssertTrue(scope.allows(assetID: UUID()))
    }

    func testScopeRoundTripsWithoutChangingAllowedAssets() throws {
        let first = UUID()
        let second = UUID()
        let scope = SnippetAssetScope.selectedAssets([first, second])

        let decoded = try JSONDecoder().decode(
            SnippetAssetScope.self,
            from: JSONEncoder().encode(scope)
        )

        XCTAssertEqual(decoded, scope)
        XCTAssertTrue(decoded.allows(assetID: first))
        XCTAssertTrue(decoded.allows(assetID: second))
    }
}
