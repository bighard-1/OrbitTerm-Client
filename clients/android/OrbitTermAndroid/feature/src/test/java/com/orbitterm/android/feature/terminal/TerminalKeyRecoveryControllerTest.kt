package com.orbitterm.android.feature.terminal

import com.orbitterm.android.data.settings.TerminalKeyRecoveryPackage
import com.orbitterm.android.domain.session.*
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.flowOf
import org.junit.Assert.*
import org.junit.Test
import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream

class TerminalKeyRecoveryControllerTest {
    private class Repository : TerminalKeyUsageRepository {
        var token: String? = "session-a"
        var exports = 0; var previews = 0; var imports = 0; var rescues = 0; var inspections = 0
        var responseToken = "session-a"
        var wait: CompletableDeferred<Unit>? = null
        override val usageCounts = flowOf(emptyMap<String, Int>())
        override val customKeys = flowOf(emptyList<TerminalCustomKey>())
        override fun recoveryAccessToken() = token
        override fun recoveryAccessValid(token: String) = this.token == token
        override suspend fun exportRecovery(password: String): TerminalCustomKeyExport {
            exports++; wait?.await()
            return TerminalCustomKeyExport(responseToken, byteArrayOf(1, 2, 3))
        }
        override suspend fun exportRescue(password: String): TerminalCustomKeyExport {
            rescues++; wait?.await()
            return TerminalCustomKeyExport(responseToken, byteArrayOf(4, 5, 6))
        }
        override suspend fun inspectRescue(bytes: ByteArray, password: String): TerminalKeyRescueReview {
            inspections++
            return TerminalKeyRescueReview(responseToken, TerminalKeyRescuePlatform.Android, true,
                TerminalKeyRescueStorageMatch.Exact,
                listOf(TerminalKeyRescueSourceReview(3, bytes.size, TerminalKeyRescueSourceStatus.InvalidStructure)))
        }
        override suspend fun previewRecovery(bytes: ByteArray, password: String): TerminalCustomKeyImportReview {
            previews++
            val empty = TerminalCustomKeyEnvelope.v1(emptyList())
            return TerminalCustomKeyImportReview("session-a", "hash", TerminalCustomKeyImportPlan.make(empty, empty))
        }
        override suspend fun importRecovery(review: TerminalCustomKeyImportReview) { imports++ }
        override suspend fun recordUse(keyLabel: String) {}
        override suspend fun saveCustomKey(key: TerminalCustomKey) {}
        override suspend fun deleteCustomKey(id: String) {}
    }
    @Test fun repositoryResultFromAnotherLeaseIsNeverPublished() = runBlocking {
        val repo = Repository(); repo.responseToken = "other-lease"
        val controller = TerminalKeyRecoveryController(repo, this)
        controller.inspectRescue("password") { ByteArrayInputStream(byteArrayOf(1)) }
        withTimeout(2_000) { while (controller.state.value.busy) delay(1) }
        assertNull(controller.state.value.rescueReview)
        assertNotNull(controller.state.value.message)
        controller.export("password", rescue = true) { error("must not open picker") }
        withTimeout(2_000) { while (controller.state.value.busy) delay(1) }
        assertNull(controller.state.value.export)
        controller.close()
    }
    @Test fun rescueInspectionIsBoundedReadOnlyAndClearedByLock() = runBlocking {
        val repo = Repository(); val controller = TerminalKeyRecoveryController(repo, this)
        controller.inspectRescue("password") { ByteArrayInputStream(byteArrayOf(1, 2)) }
        withTimeout(2_000) { while (controller.state.value.busy) delay(1) }
        assertEquals(1, repo.inspections); assertEquals(0, repo.imports)
        assertEquals(TerminalKeyRescueStorageMatch.Exact, controller.state.value.rescueReview!!.storageMatch)
        controller.clearRescueReview(); assertNull(controller.state.value.rescueReview)
        repo.token = null
        controller.inspectRescue("password") { error("must not open after lock") }
        yield()
        assertEquals(1, repo.inspections); assertNull(controller.state.value.rescueReview)
        assertThrows(IllegalArgumentException::class.java) {
            TerminalKeyRecoveryController.readLimited(ByteArrayInputStream(ByteArray(4)), 0)
        }
        controller.close()
    }
    @Test fun rescueRoutesOnlyToReadOnlyExportAndLateLockDropsItsResult() = runBlocking {
        val repo = Repository(); val controller = TerminalKeyRecoveryController(repo, this)
        controller.export("password", rescue = true) {}; yield()
        assertEquals(1, repo.rescues); assertEquals(0, repo.exports); assertEquals(0, repo.imports)
        assertArrayEquals(byteArrayOf(4, 5, 6), controller.state.value.export!!.bytes)
        controller.writeExport(null)
        repo.wait = CompletableDeferred()
        var ready = false
        controller.export("password", rescue = true) { ready = true }; yield()
        repo.token = null; repo.wait!!.complete(Unit); yield()
        assertFalse(ready); assertNull(controller.state.value.export)
        controller.close()
    }
    @Test fun cancelOrLatePickerCannotWriteAfterLockOrDismiss() = runBlocking {
        val repo = Repository()
        val controller = TerminalKeyRecoveryController(repo, this)
        controller.export("password") {}
        yield()
        controller.writeExport(null)
        assertNull(controller.state.value.export)
        controller.export("password") {}; yield()
        repo.token = null
        var opened = false
        controller.writeExport { opened = true; ByteArrayOutputStream() }
        yield()
        assertFalse(opened)
        controller.close()
        controller.export("password") { error("late callback") }
        yield()
        assertEquals(2, repo.exports)
    }
    @Test fun staleDecryptDoesNotOfferPreviewAndDuplicateExportIsBlocked() = runBlocking {
        val repo = Repository(); repo.wait = CompletableDeferred()
        val controller = TerminalKeyRecoveryController(repo, this)
        var ready = false
        controller.export("password") { ready = true }
        controller.export("password") { ready = true }
        yield()
        assertEquals(1, repo.exports)
        repo.token = "session-b"
        repo.wait!!.complete(Unit); yield()
        assertFalse(ready); assertNull(controller.state.value.export)
        controller.close()
    }
    @Test fun previewIsReadOnlyAndClosedSessionCannotCommit() = runBlocking {
        val repo = Repository(); val controller = TerminalKeyRecoveryController(repo, this)
        controller.preview("password") { ByteArrayInputStream(byteArrayOf(1)) }
        withTimeout(2_000) { while (controller.state.value.busy) { delay(1) } }
        assertEquals(1, repo.previews); assertEquals(0, repo.imports)
        controller.cancelPreview(); controller.commit(); yield()
        assertEquals(0, repo.imports)
        controller.preview("password") { ByteArrayInputStream(byteArrayOf(1)) }
        withTimeout(2_000) { while (controller.state.value.busy) { delay(1) } }
        controller.close(); controller.commit(); yield()
        assertEquals(0, repo.imports)
    }
    @Test fun fileInputIsBoundedAndShortStreamsAreReadCompletely() {
        val valid = ByteArray(9000) { (it % 127).toByte() }
        assertArrayEquals(valid, TerminalKeyRecoveryController.readLimited(ByteArrayInputStream(valid)))
        assertThrows(IllegalStateException::class.java) {
            TerminalKeyRecoveryController.readLimited(ByteArrayInputStream(ByteArray(TerminalKeyRecoveryPackage.MAX_BYTES + 1)))
        }
    }

    @Test fun pickerUsesBoundedDocumentGraceAndRevokesItIfLaunchFails() {
        val events = mutableListOf<String>()
        val coordinator = object : com.orbitterm.android.core.DocumentInteractionCoordinator {
            override fun beginDocumentInteraction() { events += "begin" }
            override fun cancelDocumentInteraction() { events += "cancel" }
        }
        assertTrue(TerminalKeyRecoveryController.launchPicker(coordinator) { events += "launch" })
        assertEquals(listOf("begin", "launch"), events)
        events.clear()
        assertFalse(TerminalKeyRecoveryController.launchPicker(coordinator) { throw IllegalStateException("no provider") })
        assertEquals(listOf("begin", "cancel"), events)
    }
}
