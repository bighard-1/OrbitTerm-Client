package com.orbitterm.android.app

import com.orbitterm.android.core.OperationScopeCoordinator
import com.orbitterm.android.domain.sync.PrivacySafeSyncMetrics
import com.orbitterm.android.domain.sync.SyncDiagnosticEvent
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test

class OperationScopeCoordinatorTest {
    @Test
    fun `a newer request supersedes an older request for the same subject`() {
        val accounts = AccountScopeController()
        val coordinator = OperationScopeCoordinator(accounts)
        accounts.activate("alice@example.com")

        val first = requireNotNull(coordinator.begin("docker_logs", "session-1"))
        val second = requireNotNull(coordinator.begin("docker_logs", "session-1"))

        assertFalse(coordinator.isCurrent(first))
        assertTrue(coordinator.isCurrent(second))
    }

    @Test
    fun `account deactivation and replacement invalidate in-flight operations`() {
        val accounts = AccountScopeController()
        val coordinator = OperationScopeCoordinator(accounts)
        accounts.activate("alice@example.com")
        val operation = coordinator.begin("sftp_transfer", "session-1")
        assertNotNull(operation)

        accounts.deactivate()
        assertFalse(coordinator.isCurrent(requireNotNull(operation)))

        accounts.activate("bob@example.com")
        assertFalse(coordinator.isCurrent(requireNotNull(operation)))
    }

    @Test
    fun `security lock invalidates work without discarding the signed-in scope`() {
        val accounts = AccountScopeController()
        val coordinator = OperationScopeCoordinator(accounts)
        accounts.activate("alice@example.com")
        val operation = requireNotNull(coordinator.begin("ssh_connect", "asset-1"))

        accounts.invalidateOperations()

        assertFalse(coordinator.isCurrent(operation))
        assertTrue(accounts.scope.value != null)
    }

    @Test
    fun `late connection completion cannot apply after its session is closed`() {
        val accounts = AccountScopeController()
        val coordinator = OperationScopeCoordinator(accounts)
        accounts.activate("alice@example.com")
        val connection = requireNotNull(coordinator.begin("ssh_connect", "asset-1"))

        coordinator.invalidate("ssh_connect", "asset-1")

        assertFalse(coordinator.isCurrent(connection))
    }

    @Test
    fun `late completion cannot apply after logout and same account login`() {
        val accounts = AccountScopeController()
        val coordinator = OperationScopeCoordinator(accounts)
        accounts.activate("alice@example.com")
        val transfer = requireNotNull(coordinator.begin("sftp_transfer", "session-1"))

        accounts.deactivate()
        accounts.activate("alice@example.com")

        assertFalse(coordinator.isCurrent(transfer))
    }

    @Test
    fun `a session invalidation does not suppress a different active session`() {
        val accounts = AccountScopeController()
        val coordinator = OperationScopeCoordinator(accounts)
        accounts.activate("alice@example.com")
        val firstSession = requireNotNull(coordinator.begin("monitor_snapshot", "session-1"))
        val secondSession = requireNotNull(coordinator.begin("monitor_snapshot", "session-2"))

        coordinator.invalidate("monitor_snapshot", "session-1")

        assertFalse(coordinator.isCurrent(firstSession))
        assertTrue(coordinator.isCurrent(secondSession))
    }

    @Test
    fun `work cannot start when no account scope is active`() {
        val coordinator = OperationScopeCoordinator(AccountScopeController())

        assertTrue(coordinator.begin("sync", "account") == null)
    }

    @Test
    fun `sync diagnostics do not cross account or logout boundaries`() {
        val accounts = AccountScopeController()
        accounts.activate("alice@example.com")
        PrivacySafeSyncMetrics.record(SyncDiagnosticEvent.DeliveryDeferred)
        assertEquals(1, PrivacySafeSyncMetrics.snapshot()[SyncDiagnosticEvent.DeliveryDeferred])

        accounts.activate("bob@example.com")
        assertTrue(PrivacySafeSyncMetrics.snapshot().isEmpty())
        PrivacySafeSyncMetrics.record(SyncDiagnosticEvent.ConflictDeferred)

        accounts.deactivate()
        assertTrue(PrivacySafeSyncMetrics.snapshot().isEmpty())
    }
}
