import Foundation
import XCTest

@MainActor
final class AdministratorContactStoreTests: XCTestCase {
    @MainActor private final class Fixture {
        var source = "https://one.invalid"
        var wall: TimeInterval = 1_000_000
        var uptime: TimeInterval = 100
        var data: Data?
        var result: String? = "Support@EXAMPLE.COM"
        var fails = false
        var requests = 0
        func store() -> AdministratorContactStore {
            AdministratorContactStore(source: { self.source }, fetch: {
                self.requests += 1
                if self.fails { throw URLError(.notConnectedToInternet) }
                return self.result
            }, load: { self.data }, save: { self.data = $0 },
            wallNow: { self.wall }, uptime: { self.uptime })
        }
    }

    func testRefreshPersistsAndRestoresPublicContactOffline() async {
        let fixture = Fixture()
        let store = fixture.store()
        await store.refresh()
        XCTAssertEqual(store.email, "Support@example.com")
        await store.refresh()
        XCTAssertEqual(fixture.requests, 1)
        fixture.fails = true
        let restored = fixture.store()
        await restored.refresh()
        XCTAssertEqual(restored.email, "Support@example.com")
    }

    func testInvalidResponseDoesNotPoisonCacheAndOmissionResetsDefault() async {
        let fixture = Fixture()
        let store = fixture.store()
        await store.refresh()
        let original = fixture.data
        fixture.uptime += 301
        fixture.result = "a@example.com?bcc=b@example.com"
        await store.refresh()
        XCTAssertEqual(fixture.data, original)
        XCTAssertEqual(store.email, "Support@example.com")
        fixture.uptime += 301
        fixture.result = nil
        await store.refresh()
        XCTAssertEqual(store.email, AdministratorContactPolicy.defaultEmail)
    }

    func testExpiryUsesUptimeAndRejectsOtherSourceOrFutureDiskTimestamp() async {
        let fixture = Fixture()
        let store = fixture.store()
        await store.refresh()
        fixture.fails = true
        fixture.wall -= 500_000
        fixture.uptime += 301
        await store.refresh()
        XCTAssertEqual(store.email, "Support@example.com")
        let futureDatedRestore = fixture.store()
        await futureDatedRestore.refresh()
        XCTAssertEqual(futureDatedRestore.email, AdministratorContactPolicy.defaultEmail)
        fixture.uptime += 86_400
        await store.refresh()
        XCTAssertEqual(store.email, AdministratorContactPolicy.defaultEmail)
        fixture.source = "https://two.invalid"
        await store.refresh()
        XCTAssertEqual(store.email, AdministratorContactPolicy.defaultEmail)
    }

    func testOldSourceResponseCannotReplaceNewSourceContact() async throws {
        var source = "https://one.invalid"
        var pending: CheckedContinuation<String?, Never>?
        var data: Data?
        let store = AdministratorContactStore(source: { source }, fetch: {
            if source == "https://one.invalid" {
                return await withCheckedContinuation { pending = $0 }
            }
            return "new@example.com"
        }, load: { data }, save: { data = $0 })
        let first = Task { await store.refresh() }
        for _ in 0..<100 where pending == nil { await Task.yield() }
        let continuation = try XCTUnwrap(pending)
        source = "https://two.invalid"
        await store.refresh()
        continuation.resume(returning: "old@example.com")
        await first.value
        XCTAssertEqual(store.email, "new@example.com")
        XCTAssertTrue(String(data: try XCTUnwrap(data), encoding: .utf8)?.contains("new@example.com") == true)
    }

    func testCancellationDoesNotPublishOrDelayNextForegroundRefresh() async {
        var began = false
        var first = true
        var data: Data?
        let store = AdministratorContactStore(source: { "https://one.invalid" }, fetch: {
            if first {
                first = false
                began = true
                do { try await Task.sleep(for: .seconds(30)) }
                catch { throw URLError(.cancelled) }
            }
            return "new@example.com"
        }, load: { data }, save: { data = $0 })
        let request = Task { await store.refresh() }
        for _ in 0..<100 where !began { await Task.yield() }
        XCTAssertTrue(began)
        request.cancel()
        await request.value
        XCTAssertNil(data)
        await store.refresh()
        XCTAssertEqual(store.email, "new@example.com")
    }
}
