package com.orbitterm.android.feature.terminal

/**
 * Resolves the session that cross-session tools should operate on.
 *
 * A saved selection always wins. The most recently opened live session is only a
 * first-run fallback, before a user has selected a workspace.
 */
fun selectActiveTerminalSession(
    sessions: List<ActiveTerminalSession>,
    selectedSessionId: String?,
): ActiveTerminalSession? =
    sessions.firstOrNull { it.id == selectedSessionId } ?: sessions.lastOrNull()
