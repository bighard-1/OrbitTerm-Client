package com.orbitterm.android.sync

import com.orbitterm.android.data.sync.PortableServerConfig
import com.orbitterm.android.domain.assets.ServerAsset
import com.orbitterm.android.domain.assets.JumpHostConfiguration
import org.junit.Assert.assertEquals
import org.junit.Test

class AssetSyncConflictPolicyTest {
    @Test
    fun `non-overlapping metadata changes merge automatically`() {
        assertEquals(
            AssetMergeDecision.AutoMerge(setOf(AssetSyncField.Group)),
            AssetSyncConflictPolicy.decide(
                local = setOf(AssetSyncField.Group),
                remote = setOf(AssetSyncField.Name),
            ),
        )
    }

    @Test
    fun `same field changes require a user choice`() {
        assertEquals(
            AssetMergeDecision.RequiresUserChoice(setOf(AssetSyncField.Host)),
            AssetSyncConflictPolicy.decide(
                local = setOf(AssetSyncField.Host),
                remote = setOf(AssetSyncField.Host),
            ),
        )
    }

    @Test
    fun `credential changes are conservative when cloud data also changed`() {
        assertEquals(
            AssetMergeDecision.RequiresUserChoice(setOf(AssetSyncField.PasswordMaterial)),
            AssetSyncConflictPolicy.decide(
                local = setOf(AssetSyncField.PasswordMaterial),
                remote = setOf(AssetSyncField.Name),
            ),
        )
    }

    @Test
    fun `authentication semantics require confirmation during concurrent changes`() {
        assertEquals(
            AssetMergeDecision.RequiresUserChoice(setOf(AssetSyncField.AuthMethod)),
            AssetSyncConflictPolicy.decide(
                local = setOf(AssetSyncField.Group),
                remote = setOf(AssetSyncField.AuthMethod),
            ),
        )
    }

    @Test
    fun `automatic merge retains local edits and applies unrelated remote edits`() {
        val local = sampleAsset(group = "生产")
        val remote = PortableServerConfig(
            id = local.id, name = "核心网关", group = "默认", host = "10.0.0.8", port = 22,
            username = "ops", authMethod = "password", savedAtUnix = 2,
        )

        val merged = AssetSyncConflictPolicy.mergeRemoteConfiguration(
            local, remote, setOf(AssetSyncField.Group),
        )

        assertEquals("生产", merged.group)
        assertEquals("核心网关", merged.name)
        assertEquals("10.0.0.8", merged.host)
    }

    @Test
    fun `jump route comparison ignores device scoped credential identifiers`() {
        val first = sampleAsset().copy(
            jumpHost = JumpHostConfiguration("account-a:hop", "bastion.example.net", 22, "ops", "key", false),
        )
        val second = first.copy(
            jumpHost = first.jumpHost!!.copy(credentialID = "account-b:hop"),
        )

        assertEquals(emptySet<AssetSyncField>(), AssetSyncConflictPolicy.changedFields(
            AssetSyncConflictPolicy.shadow(first),
            AssetSyncConflictPolicy.shadow(second),
        ))
    }

    @Test
    fun `tag changes are synchronized as ordinary metadata`() {
        val before = sampleAsset().copy(tags = listOf("生产"))
        val after = before.copy(tags = listOf("生产", "核心"))

        assertEquals(
            setOf(AssetSyncField.Tags),
            AssetSyncConflictPolicy.changedFields(
                AssetSyncConflictPolicy.shadow(before),
                AssetSyncConflictPolicy.shadow(after),
            ),
        )
    }

    private fun sampleAsset(group: String = "默认") = ServerAsset(
        id = "00000000-0000-0000-0000-000000000001", credentialID = "credential", name = "网关",
        group = group, host = "10.0.0.1", port = 22, username = "root", authMethod = "password",
        transport = "ssh", networkDeviceProfile = "auto", allowPasswordFallback = true, createdAtUnix = 1,
    )
}
