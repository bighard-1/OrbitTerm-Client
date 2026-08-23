package com.orbitterm.android.core

import android.util.Base64

object OrbitCoreBridge {
    private val nativeLoadResult = runCatching { System.loadLibrary("orbit_core") }
    val isNativeLibraryAvailable: Boolean get() = nativeLoadResult.isSuccess
    @Volatile private var terminalOutputCallbackInstalled = false
    @Volatile private var sftpProgressCallbackInstalled = false
    val isTerminalOutputCallbackInstalled: Boolean get() = terminalOutputCallbackInstalled

    external fun orbitEncryptConfig(masterPassword: String, plaintext: ByteArray, plaintextLen: Long): String
    external fun orbitDecryptConfig(masterPassword: String, encryptedBase64: String): String
    external fun orbitDeriveConfigRootKeyV2(masterPassword: String, accountScope: String): String
    external fun orbitEncryptConfigV2(rootKey: ByteArray, plaintext: ByteArray): String
    external fun orbitDecryptConfigV2(rootKey: ByteArray, encryptedBase64: String): String
    external fun orbitPortableValidate(portableJson: String): String
    external fun orbitPortableChangedFields(baseJson: String, newerJson: String): String
    external fun orbitPortableMerge(remoteJson: String, localJson: String, localChangedFieldsJson: String): String
    external fun orbitVectorClockBump(vectorClockJson: String, actor: String): String
    external fun orbitGenerateEd25519KeyPair(comment: String): String
    external fun orbitPublicKeyFromPrivate(privateKey: String, passphrase: String): String
    external fun orbitCheckedSshConnect(
        host: String,
        port: Int,
        username: String,
        password: String,
        privateKey: String,
        privateKeyPassphrase: String,
        allowPasswordFallback: Boolean,
        knownHostsPath: String,
        requestId: String,
    ): String
    external fun orbitCheckedSshConnectViaJump(
        host: String,
        port: Int,
        username: String,
        password: String,
        privateKey: String,
        privateKeyPassphrase: String,
        allowPasswordFallback: Boolean,
        jumpHost: String,
        jumpPort: Int,
        jumpUsername: String,
        jumpPassword: String,
        jumpPrivateKey: String,
        jumpPrivateKeyPassphrase: String,
        jumpAllowPasswordFallback: Boolean,
        knownHostsPath: String,
        requestId: String,
    ): String
    external fun orbitAcceptHostKeyAndPersist(challengeId: String, knownHostsPath: String): String
    external fun orbitRejectHostKeyChallenge(challengeId: String): String
    external fun orbitDisconnectCheckedSsh(baseSessionId: Long, requestId: String): String
    external fun orbitOpenCheckedTerminal(baseSessionId: Long, cols: Int, rows: Int, requestId: String): String
    external fun orbitWriteCheckedTerminal(terminalChannelId: Long, data: ByteArray, requestId: String): String
    external fun orbitResizeCheckedTerminal(terminalChannelId: Long, cols: Int, rows: Int, requestId: String): String
    external fun orbitCloseCheckedTerminal(terminalChannelId: Long, requestId: String): String
    external fun orbitOpenCheckedSftp(baseSessionId: Long, requestId: String): String
    external fun orbitListCheckedSftp(sftpSessionId: Long, remotePath: String, requestId: String): String
    external fun orbitCreateCheckedSftpDirectory(sftpSessionId: Long, remotePath: String, requestId: String): String
    external fun orbitCreateCheckedSftpFile(sftpSessionId: Long, remotePath: String, requestId: String): String
    external fun orbitRenameCheckedSftpEntry(
        sftpSessionId: Long,
        oldRemotePath: String,
        newRemotePath: String,
        expectedSize: Long,
        expectedPermissionsOctal: Int,
        expectedModifiedAtUnix: Long,
        expectedIsDirectory: Boolean,
        requestId: String,
    ): String
    external fun orbitRemoveCheckedSftpEntry(
        sftpSessionId: Long,
        remotePath: String,
        expectedSize: Long,
        expectedPermissionsOctal: Int,
        expectedModifiedAtUnix: Long,
        expectedIsDirectory: Boolean,
        requestId: String,
    ): String
    external fun orbitChmodCheckedSftpEntry(sftpSessionId: Long, remotePath: String, mode: Int, expectedSize: Long, expectedPermissionsOctal: Int, expectedModifiedAtUnix: Long, expectedIsDirectory: Boolean, requestId: String): String
    external fun orbitDownloadCheckedSftpFile(sftpSessionId: Long, remotePath: String, localPath: String, requestId: String): String
    external fun orbitUploadCheckedSftpFile(sftpSessionId: Long, localPath: String, remotePath: String, requestId: String): String
    external fun orbitCancelCheckedSftpTransfer(requestId: String): String
    external fun orbitReadCheckedSftpText(sftpSessionId: Long, remotePath: String, requestId: String): String
    external fun orbitWriteCheckedSftpText(sftpSessionId: Long, remotePath: String, content: ByteArray, expectedSize: Long, expectedPermissionsOctal: Int, expectedModifiedAtUnix: Long, expectedIsDirectory: Boolean, requestId: String): String
    external fun orbitListCheckedDocker(baseSessionId: Long, requestId: String): String
    external fun orbitStatsCheckedDocker(baseSessionId: Long, requestId: String): String
    external fun orbitMonitorSnapshot(baseSessionId: Long, requestId: String): String
    external fun orbitDockerAction(baseSessionId: Long, containerId: String, action: String, requestId: String): String
    external fun orbitDockerLogs(baseSessionId: Long, containerId: String, tail: Int, requestId: String): String
    external fun orbitExecChecked(baseSessionId: Long, command: String, timeoutSeconds: Int, maxStdoutBytes: Int, maxStderrBytes: Int, requestId: String): String
    external fun orbitStartCheckedLocalTunnel(baseSessionId: Long, bindHost: String, bindPort: Int, destinationHost: String, destinationPort: Int, requestId: String): String
    external fun orbitStopCheckedLocalTunnel(tunnelId: Long, requestId: String): String
    external fun orbitInstallTerminalOutputCallback(receiver: Any): Boolean
    external fun orbitInstallSftpProgressCallback(receiver: Any): Boolean

    fun installTerminalOutputCallback(receiver: Any): Boolean {
        terminalOutputCallbackInstalled =
            isNativeLibraryAvailable && orbitInstallTerminalOutputCallback(receiver)
        return terminalOutputCallbackInstalled
    }

    fun installSftpProgressCallback(receiver: Any): Boolean {
        sftpProgressCallbackInstalled =
            isNativeLibraryAvailable && orbitInstallSftpProgressCallback(receiver)
        return sftpProgressCallbackInstalled
    }

    fun encryptConfig(masterPassword: String, plaintext: String): String {
        val result = orbitEncryptConfig(masterPassword, plaintext.toByteArray(Charsets.UTF_8), plaintext.toByteArray(Charsets.UTF_8).size.toLong())
        return result.unwrapOrbitResult()
    }

    fun decryptConfig(masterPassword: String, encryptedBase64: String): String {
        val raw = orbitDecryptConfig(masterPassword, encryptedBase64).unwrapOrbitResult()
        val bytes = Base64.decode(raw, Base64.DEFAULT)
        return bytes.toString(Charsets.UTF_8)
    }

    fun deriveConfigRootKeyV2(masterPassword: String, accountScope: String): ByteArray {
        val raw = orbitDeriveConfigRootKeyV2(masterPassword, accountScope).unwrapOrbitResult()
        return Base64.decode(raw, Base64.DEFAULT)
    }

    fun encryptConfigV2(rootKey: ByteArray, plaintext: String): String {
        val raw = orbitEncryptConfigV2(rootKey, plaintext.toByteArray(Charsets.UTF_8)).unwrapOrbitResult()
        return raw
    }

    fun decryptConfigV2(rootKey: ByteArray, encryptedBase64: String): String {
        val raw = orbitDecryptConfigV2(rootKey, encryptedBase64).unwrapOrbitResult()
        return Base64.decode(raw, Base64.DEFAULT).toString(Charsets.UTF_8)
    }

    fun unwrapResult(value: String): String = value.unwrapOrbitResult()

    fun generateEd25519KeyPair(comment: String): String =
        orbitGenerateEd25519KeyPair(comment).unwrapOrbitResult()

    fun publicKeyFromPrivate(privateKey: String, passphrase: String): String =
        orbitPublicKeyFromPrivate(privateKey, passphrase).unwrapOrbitResult()

    private fun String.unwrapOrbitResult(): String = when {
        startsWith("OK:") -> drop(3)
        startsWith("ERR:") -> throw IllegalStateException(drop(4))
        else -> throw IllegalStateException("Unexpected orbit-core response")
    }
}
