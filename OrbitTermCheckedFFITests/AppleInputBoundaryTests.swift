import XCTest

@MainActor
final class AppleInputBoundaryTests: XCTestCase {
    func testSSHDeepLinkProducesSafeAddServerPrefill() {
        let manager = DeepLinkManager.shared
        manager.consumePendingIntent()

        manager.handle(url: URL(string: "ssh://ops@example.com:2222")!)

        guard let intent = manager.pendingIntent else {
            return XCTFail("Expected SSH deep link intent")
        }
        XCTAssertEqual(intent.host, "example.com")
        XCTAssertEqual(intent.port, 2222)
        XCTAssertEqual(intent.username, "ops")
        XCTAssertEqual(intent.prefill.name, "example.com:2222")
        XCTAssertEqual(intent.prefill.group, "")
        manager.consumePendingIntent()
    }

    func testOrbitTermDeepLinkUsesOnlyConnectRouteAndValidPort() {
        let manager = DeepLinkManager.shared
        manager.consumePendingIntent()

        manager.handle(url: URL(string: "orbitterm://connect?host=db.example&port=2200&user=deploy&name=Production")!)
        guard let intent = manager.pendingIntent else {
            return XCTFail("Expected OrbitTerm connect intent")
        }
        XCTAssertEqual(intent.host, "db.example")
        XCTAssertEqual(intent.port, 2200)
        XCTAssertEqual(intent.username, "deploy")
        XCTAssertEqual(intent.suggestedName, "Production")

        manager.consumePendingIntent()
        manager.handle(url: URL(string: "orbitterm://delete?host=db.example")!)
        XCTAssertNil(manager.pendingIntent)

        manager.handle(url: URL(string: "orbitterm://connect?host=db.example&port=0")!)
        XCTAssertNil(manager.pendingIntent)

        manager.handle(url: URL(string: "orbitterm://connect?host=db.example&port=+22")!)
        XCTAssertNil(manager.pendingIntent)
    }

    func testDeepLinksNeverReplacePendingIntentWithMalformedInput() {
        let manager = DeepLinkManager.shared
        manager.consumePendingIntent()
        manager.handle(url: URL(string: "ssh://safe.example")!)
        let original = manager.pendingIntent

        manager.handle(url: URL(string: "ssh://:22")!)
        XCTAssertEqual(manager.pendingIntent?.host, original?.host)
        XCTAssertEqual(manager.pendingIntent?.port, original?.port)
        manager.consumePendingIntent()
    }

    func testDeepLinksRejectControlCharactersAndWhitespaceInConnectionFields() {
        let manager = DeepLinkManager.shared
        manager.consumePendingIntent()

        manager.handle(url: URL(string: "orbitterm://connect?host=db%0A.example")!)
        XCTAssertNil(manager.pendingIntent)

        manager.handle(url: URL(string: "orbitterm://connect?host=db.example&username=ops%20team")!)
        XCTAssertNil(manager.pendingIntent)
    }

    func testDeepLinksRejectEmbeddedCredentialsAndOversizedFields() {
        let manager = DeepLinkManager.shared
        manager.consumePendingIntent()

        manager.handle(url: URL(string: "ssh://ops:secret@example.com")!)
        XCTAssertNil(manager.pendingIntent)

        manager.handle(url: URL(string: "orbitterm://connect?host=db.example&password=secret")!)
        XCTAssertNil(manager.pendingIntent)

        let oversizedName = String(repeating: "n", count: 81)
        manager.handle(url: URL(string: "orbitterm://connect?host=db.example&name=\(oversizedName)")!)
        XCTAssertNil(manager.pendingIntent)
    }

    func testLockedOrReplacedReviewDoesNotConsumePendingDeepLink() {
        let pending = UUID()
        XCTAssertFalse(
            DeepLinkReviewPolicy.shouldConsumePendingIntent(
                isAuthenticated: true,
                isUnlocked: false,
                pendingIntentID: pending,
                activeReviewID: pending
            )
        )
        XCTAssertFalse(
            DeepLinkReviewPolicy.shouldConsumePendingIntent(
                isAuthenticated: true,
                isUnlocked: true,
                pendingIntentID: UUID(),
                activeReviewID: pending
            )
        )
        XCTAssertTrue(
            DeepLinkReviewPolicy.shouldConsumePendingIntent(
                isAuthenticated: true,
                isUnlocked: true,
                pendingIntentID: pending,
                activeReviewID: pending
            )
        )
    }

    func testShellPathResolverNormalizesRelativeHomeAndParentPaths() {
        XCTAssertEqual(
            ShellPathResolver.resolve(command: "cd ../logs/./today", currentPath: "/srv/app/cache", username: "deploy"),
            "/srv/app/logs/today"
        )
        XCTAssertEqual(
            ShellPathResolver.resolve(command: "cd ~/work", currentPath: "/tmp", username: "deploy"),
            "/home/deploy/work"
        )
        XCTAssertEqual(
            ShellPathResolver.resolve(command: "cd /var/log && pwd", currentPath: "/tmp", username: "deploy"),
            "/var/log"
        )
    }

    func testShellPathResolverRejectsAmbiguousOrEmptyDirectoryChanges() {
        XCTAssertNil(ShellPathResolver.resolve(command: "cd", currentPath: "/", username: "root"))
        XCTAssertNil(ShellPathResolver.resolve(command: "cd -", currentPath: "/", username: "root"))
        XCTAssertNil(ShellPathResolver.resolve(command: "ls -la", currentPath: "/", username: "root"))
    }

    func testSnippetVariablesAreDeduplicatedAndResolvedExactly() {
        let command = "echo {{name}} {{name}} {{environment}} {{invalid-name}}"
        XCTAssertEqual(SnippetVariableResolver.extractVariables(from: command), ["environment", "name"])
        XCTAssertEqual(
            SnippetVariableResolver.resolve("echo {{name}} {{name_suffix}}", values: ["name": "orbit"]),
            "echo orbit {{name_suffix}}"
        )
    }
}
