package com.orbitterm.android.data.local

import androidx.room.Room
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.orbitterm.android.domain.assets.LOCAL_ASSET_PARTITION
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class ServerAssetScopeVisibilityTest {
    @Test
    fun localAssetWinsUuidCollisionInListAndLookup() = runBlocking {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val database = Room.inMemoryDatabaseBuilder(context, OrbitTermDatabase::class.java).build()
        try {
            val dao = database.serverAssetDao()
            val account = "account-a"
            dao.upsert(asset(account, "Cloud route", "ACCOUNT_SYNCED"))
            dao.upsert(asset(LOCAL_ASSET_PARTITION, "Device route", "LOCAL_ONLY"))

            assertEquals(
                "Device route",
                dao.observeVisible(account, LOCAL_ASSET_PARTITION).first().single().name,
            )
            assertEquals(
                "Device route",
                dao.findVisibleById(account, LOCAL_ASSET_PARTITION, "same-id")?.name,
            )
            assertEquals(
                "Device route",
                dao.observeAll(LOCAL_ASSET_PARTITION).first().single().name,
            )
        } finally {
            database.close()
        }
    }

    private fun asset(partition: String, name: String, storageScope: String) = ServerAssetEntity(
        accountScope = partition,
        id = "same-id",
        credentialID = "same-credential",
        name = name,
        groupName = "",
        tagsJson = "[]",
        host = "127.0.0.1",
        port = 22,
        username = "test",
        authMethod = "password",
        transport = "ssh",
        networkDeviceProfile = "auto",
        allowPasswordFallback = false,
        storageScope = storageScope,
        jumpHostJson = null,
        createdAtUnix = 1,
    )
}
