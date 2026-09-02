package com.orbitterm.android.feature.presentation

import androidx.compose.foundation.layout.size
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.ui.Modifier
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import com.orbitterm.android.ui.design.OrbitFeedbackBanner
import kotlinx.coroutines.delay

@Composable
fun OperationalRefreshAction(
    presentation: OperationalActionPresentation,
    onRefresh: () -> Unit,
    modifier: Modifier = Modifier,
) {
    TextButton(
        onClick = onRefresh,
        enabled = presentation.refreshEnabled,
        modifier = modifier.semantics {
            contentDescription = presentation.refreshContentDescription
        },
    ) {
        if (presentation.showsRefreshProgress) {
            CircularProgressIndicator(
                modifier = Modifier.size(20.dp),
                strokeWidth = 2.dp,
            )
        }
        Text(presentation.refreshLabel)
    }
}

@Composable
fun OperationalFailureFeedback(
    content: OperationalContentPresentation,
    action: OperationalActionPresentation,
    modifier: Modifier = Modifier,
) {
    if (content.phase != OperationalContentPhase.FAILED) return
    OrbitFeedbackBanner(
        message = listOfNotNull(content.detail, action.staleContentMessage).joinToString(" "),
        isError = true,
        modifier = modifier,
    )
}

@Composable
fun OperationalTransientSuccessFeedback(
    message: String,
    onDismiss: (String) -> Unit,
    modifier: Modifier = Modifier,
) {
    LaunchedEffect(message) {
        delay(OperationalFeedbackPolicy.lifetime(OperationalFeedbackKind.SUCCESS).autoDismissAfterMillis!!)
        onDismiss(message)
    }
    OrbitFeedbackBanner(
        message = message,
        isError = false,
        modifier = modifier,
    )
}
