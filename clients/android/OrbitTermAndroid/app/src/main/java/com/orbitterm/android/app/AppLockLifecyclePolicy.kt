package com.orbitterm.android.app

enum class BackgroundLockDisposition {
    IGNORE_CONFIGURATION_CHANGE,
    DEFER_FOR_DOCUMENT_INTERACTION,
    LOCK_NOW,
}

/** Platform-neutral policy used by the Activity host and JVM regression tests. */
internal fun backgroundLockDisposition(
    isChangingConfigurations: Boolean,
    isDocumentInteractionPending: Boolean,
): BackgroundLockDisposition = when {
    isChangingConfigurations -> BackgroundLockDisposition.IGNORE_CONFIGURATION_CHANGE
    isDocumentInteractionPending -> BackgroundLockDisposition.DEFER_FOR_DOCUMENT_INTERACTION
    else -> BackgroundLockDisposition.LOCK_NOW
}

/** Lock before a short app switch can return without ever reaching ON_STOP. */
internal fun shouldLockOnPause(
    isChangingConfigurations: Boolean,
    isDocumentInteractionPending: Boolean,
    isBiometricPromptActive: Boolean,
): Boolean = !isBiometricPromptActive &&
    backgroundLockDisposition(
        isChangingConfigurations = isChangingConfigurations,
        isDocumentInteractionPending = isDocumentInteractionPending,
    ) == BackgroundLockDisposition.LOCK_NOW

internal fun documentInteractionRequiresLockOnResume(
    startedAtMillis: Long?,
    resumedAtMillis: Long,
    graceMillis: Long,
): Boolean = startedAtMillis?.let { resumedAtMillis - it >= graceMillis } ?: false
