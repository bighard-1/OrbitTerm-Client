package com.orbitterm.android.feature.terminal

import com.orbitterm.android.data.settings.TerminalKeyRecoveryPackage
import com.orbitterm.android.domain.session.*
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import java.io.InputStream
import java.io.OutputStream
import java.io.ByteArrayOutputStream

/** One ephemeral editor session, never a persisted job or a credential owner. */
class TerminalKeyRecoveryController(private val repository: TerminalKeyUsageRepository, private val scope: CoroutineScope) {
    data class State(val busy: Boolean = false, val message: String? = null,
        val export: TerminalCustomKeyExport? = null, val preview: TerminalCustomKeyImportReview? = null,
        val rescueReview: TerminalKeyRescueReview? = null)
    val token = repository.recoveryAccessToken()
    private val mutable = MutableStateFlow(State())
    val state = mutable.asStateFlow()
    private var job: Job? = null
    @Volatile private var closed = false
    private fun requireAccess() { check(!closed && token != null && repository.recoveryAccessValid(token)) }

    fun export(password: String, rescue: Boolean = false, ready: () -> Unit) = run {
        val result = if (rescue) repository.exportRescue(password) else repository.exportRecovery(password)
        requireAccess()
        check(result.accessToken == token)
        mutable.value = mutable.value.copy(export = result)
        ready()
    }
    fun writeExport(open: (() -> OutputStream?)?) {
        val result = mutable.value.export ?: return
        mutable.value = mutable.value.copy(export = null)
        if (open == null) return
        run {
            withContext(Dispatchers.IO) {
                requireAccess()
                checkNotNull(open()).use { stream ->
                    requireAccess()
                    stream.write(result.bytes)
                    stream.flush()
                }
            }
            requireAccess()
            mutable.value = mutable.value.copy(message = "加密文件已导出。请将口令与文件分开保管。")
        }
    }
    fun preview(password: String, open: () -> InputStream?) = run {
        mutable.value = mutable.value.copy(preview = null)
        val bytes = withContext(Dispatchers.IO) { checkNotNull(open()).use(::readLimited) }
        requireAccess()
        val review = repository.previewRecovery(bytes, password)
        requireAccess()
        check(review.accessToken == token)
        mutable.value = mutable.value.copy(preview = review)
    }
    fun inspectRescue(password: String, open: () -> InputStream?) = run {
        mutable.value = mutable.value.copy(rescueReview = null)
        val bytes = withContext(Dispatchers.IO) {
            checkNotNull(open()).use { readLimited(it, TerminalKeyRecoveryPackage.MAX_RESCUE_BYTES) }
        }
        requireAccess()
        val review = repository.inspectRescue(bytes, password)
        requireAccess()
        check(review.accessToken == token)
        mutable.value = mutable.value.copy(rescueReview = review)
    }
    fun clearRescueReview() { mutable.value = mutable.value.copy(rescueReview = null) }
    fun cancelPreview() { mutable.value = mutable.value.copy(preview = null) }
    fun pickerFailed() { mutable.value = mutable.value.copy(export = null, message = "无法打开系统文件选择器，原有配置未更改。") }
    fun commit() {
        val preview = mutable.value.preview ?: return
        run {
            repository.importRecovery(preview)
            requireAccess()
            mutable.value = mutable.value.copy(preview = null, message = "合并完成。冲突按键请返回管理页逐项处理。")
        }
    }
    fun close() { closed = true; job?.cancel(); mutable.value = State() }
    private fun run(operation: suspend () -> Unit) {
        if (mutable.value.busy || closed) return
        mutable.value = mutable.value.copy(busy = true, message = null)
        job = scope.launch {
            try { requireAccess(); operation() }
            catch (cancelled: CancellationException) { throw cancelled }
            catch (_: Exception) {
                if (!closed) mutable.value = mutable.value.copy(message =
                    "处理失败：口令错误、文件无效、存储不可用或配置已变化。原有配置未更改。若导出留下不完整文件，请勿将其用作备份。")
            } finally { if (!closed) mutable.value = mutable.value.copy(busy = false) }
        }
    }
    companion object {
        fun launchPicker(coordinator: com.orbitterm.android.core.DocumentInteractionCoordinator, launch: () -> Unit): Boolean {
            return try {
                coordinator.beginDocumentInteraction()
                launch()
                true
            } catch (_: Exception) {
                coordinator.cancelDocumentInteraction()
                false
            }
        }
        fun readLimited(stream: InputStream, maximum: Int = TerminalKeyRecoveryPackage.MAX_BYTES): ByteArray {
            require(maximum in 1..TerminalKeyRecoveryPackage.MAX_RESCUE_BYTES)
            val output = ByteArrayOutputStream()
            val buffer = ByteArray(8192)
            while (true) {
                val n = stream.read(buffer, 0, minOf(buffer.size, maximum + 1 - output.size()))
                if (n < 0) break
                check(n > 0) { "恢复文件无法读取。" }
                output.write(buffer, 0, n)
                check(output.size() <= maximum) { "恢复文件大小超限。" }
            }
            return output.toByteArray()
        }
    }
}
