package com.orbitterm.android.core

interface DocumentInteractionCoordinator {
    fun beginDocumentInteraction()
    /** Only for a picker that failed to launch; host resume handles normal returns. */
    fun cancelDocumentInteraction() {}
}
