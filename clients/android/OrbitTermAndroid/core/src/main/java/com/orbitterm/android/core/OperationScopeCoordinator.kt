package com.orbitterm.android.core

import com.orbitterm.android.domain.auth.AccountScope
import com.orbitterm.android.domain.auth.OperationGenerationProvider
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicLong
import javax.inject.Inject
import javax.inject.Singleton

/**
 * Guards asynchronous completions against account changes, session changes and
 * newer requests. It is intentionally UI-agnostic: ViewModels retain their
 * own presentation state and ask this coordinator before committing a result.
 */
@Singleton
class OperationScopeCoordinator @Inject constructor(
    private val accountScopes: OperationGenerationProvider,
) {
    private val sequence = AtomicLong(0)
    private val latestByKey = ConcurrentHashMap<String, Long>()

    fun begin(domain: String, subjectId: String): OperationScopeToken? {
        val scope = accountScopes.scope.value ?: return null
        val sequenceId = sequence.incrementAndGet()
        val key = "$domain:$subjectId"
        latestByKey[key] = sequenceId
        return OperationScopeToken(
            domain = domain,
            subjectId = subjectId,
            accountScope = scope,
            accountGeneration = accountScopes.generation.value,
            sequence = sequenceId,
        )
    }

    fun isCurrent(token: OperationScopeToken): Boolean =
        accountScopes.scope.value == token.accountScope &&
            accountScopes.generation.value == token.accountGeneration &&
            latestByKey["${token.domain}:${token.subjectId}"] == token.sequence

    fun invalidate(domain: String, subjectId: String) {
        latestByKey["$domain:$subjectId"] = sequence.incrementAndGet()
    }
}

data class OperationScopeToken(
    val domain: String,
    val subjectId: String,
    val accountScope: AccountScope,
    val accountGeneration: Long,
    val sequence: Long,
)
