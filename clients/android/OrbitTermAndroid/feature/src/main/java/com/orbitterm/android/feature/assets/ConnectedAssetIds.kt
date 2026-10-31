package com.orbitterm.android.feature.assets

import com.orbitterm.android.feature.terminal.TerminalSessionConnectionState

/** A retained terminal tab is not evidence that its underlying SSH connection is still live. */
internal fun connectedAssetIds(
    sessions: Iterable<Pair<String, TerminalSessionConnectionState>>,
): Set<String> = sessions.mapNotNullTo(linkedSetOf()) { (assetId, state) ->
    assetId.takeIf { state == TerminalSessionConnectionState.Connected }
}
