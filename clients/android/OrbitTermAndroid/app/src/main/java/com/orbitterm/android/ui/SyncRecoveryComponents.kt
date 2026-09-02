package com.orbitterm.android.ui

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import com.orbitterm.android.app.SyncStatus
import com.orbitterm.android.feature.presentation.OperationalFeedbackKind
import com.orbitterm.android.feature.presentation.OperationalFeedbackPolicy
import com.orbitterm.android.ui.design.OrbitFeedbackBanner
import kotlinx.coroutines.delay

@Composable
internal fun SyncStatusFeedback(
    status: SyncStatus,
    onRetry: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val presentation = status.presentation()
    var hiddenSuccess by remember { mutableStateOf<SyncStatus?>(null) }

    LaunchedEffect(status, presentation.phase) {
        hiddenSuccess = null
        if (presentation.phase == SyncPresentationPhase.SUCCESS) {
            delay(OperationalFeedbackPolicy.lifetime(OperationalFeedbackKind.SUCCESS).autoDismissAfterMillis!!)
            hiddenSuccess = status
        }
    }

    Column(modifier = modifier, verticalArrangement = Arrangement.spacedBy(4.dp)) {
        when (presentation.phase) {
            SyncPresentationPhase.IDLE -> Unit
            SyncPresentationPhase.BUSY -> Row(
                verticalAlignment = Alignment.CenterVertically,
                modifier = Modifier.semantics {
                    contentDescription = "同步中：${presentation.detail}"
                },
            ) {
                CircularProgressIndicator(modifier = Modifier.size(18.dp), strokeWidth = 2.dp)
                Spacer(Modifier.width(8.dp))
                Text("${presentation.headline}：${presentation.detail}")
            }
            SyncPresentationPhase.WAITING -> OrbitFeedbackBanner(
                message = "${presentation.headline}：${presentation.detail}",
                isError = false,
            )
            SyncPresentationPhase.SUCCESS -> if (hiddenSuccess != status) {
                OrbitFeedbackBanner(
                    message = "${presentation.headline}：${presentation.detail}",
                    isError = false,
                )
            }
            SyncPresentationPhase.FAILURE -> {
                OrbitFeedbackBanner(
                    message = "${presentation.headline}：${presentation.detail}",
                    isError = true,
                )
                TextButton(
                    onClick = onRetry,
                    modifier = Modifier.align(Alignment.End),
                ) { Text("重试同步") }
            }
        }
    }
}

@Composable
internal fun RecentlyDeletedFeedback(
    presentation: RecentlyDeletedPresentation,
    successMessage: String?,
    onDismissSuccess: () -> Unit,
    modifier: Modifier = Modifier,
) {
    Column(modifier = modifier, verticalArrangement = Arrangement.spacedBy(6.dp)) {
        if (presentation.phase == RecentlyDeletedPresentationPhase.FAILED) {
            OrbitFeedbackBanner(
                message = listOfNotNull(presentation.detail, presentation.staleContentMessage).joinToString(" "),
                isError = true,
            )
        }
        successMessage?.let { message ->
            var visible by remember(message) { mutableStateOf(true) }
            LaunchedEffect(message) {
                delay(OperationalFeedbackPolicy.lifetime(OperationalFeedbackKind.SUCCESS).autoDismissAfterMillis!!)
                visible = false
                onDismissSuccess()
            }
            if (visible) OrbitFeedbackBanner(message = message, isError = false)
        }
    }
}
