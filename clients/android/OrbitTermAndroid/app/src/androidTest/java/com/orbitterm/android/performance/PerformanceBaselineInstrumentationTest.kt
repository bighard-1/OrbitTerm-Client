package com.orbitterm.android.performance

import android.app.ActivityManager
import android.os.Debug
import android.os.Handler
import android.os.Looper
import android.view.FrameMetrics
import android.view.Window
import androidx.activity.ComponentActivity
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.ui.Modifier
import androidx.compose.ui.test.junit4.v2.createAndroidComposeRule
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.orbitterm.android.domain.performance.PerformanceAcceptanceBaseline
import com.orbitterm.android.domain.performance.RuntimeResourceBudget
import com.orbitterm.android.domain.performance.retainUtf8Tail
import java.util.Collections
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

/**
 * Repeatable device smoke baseline. It is intentionally generous for shared
 * emulators; regressions in bounded rendering, memory, or main-thread liveness
 * fail here before a release artifact is accepted.
 */
@RunWith(AndroidJUnit4::class)
class PerformanceBaselineInstrumentationTest {
    @get:Rule val compose = createAndroidComposeRule<ComponentActivity>()

    @Test(timeout = PerformanceAcceptanceBaseline.MAX_OPERATION_MILLIS)
    fun thousandAssetsAndRapidSessionSwitchesStayWithinDeviceBudget() {
        val selectedSession = mutableIntStateOf(0)
        val assets = List(PerformanceAcceptanceBaseline.LARGE_ASSET_COUNT) { index ->
            "asset-${index.toString().padStart(4, '0')}"
        }
        withDeviceBaseline(
            content = {
                LazyColumn(Modifier.fillMaxSize()) {
                    item { Text("会话 ${selectedSession.intValue}") }
                    items(assets, key = { it }) { asset -> Text(asset) }
                }
            },
            exercise = {
                repeat(PerformanceAcceptanceBaseline.RAPID_SESSION_SWITCH_COUNT) { index ->
                    compose.activity.runOnUiThread { selectedSession.intValue = index }
                    compose.waitForIdle()
                }
            },
        )
    }

    @Test(timeout = PerformanceAcceptanceBaseline.MAX_OPERATION_MILLIS)
    fun boundedLongDockerLogStaysWithinDeviceBudget() {
        val visibleRevision = mutableIntStateOf(0)
        val rawLog = buildString(PerformanceAcceptanceBaseline.LONG_DOCKER_LOG_SOURCE_BYTES) {
            while (length < PerformanceAcceptanceBaseline.LONG_DOCKER_LOG_SOURCE_BYTES) {
                append("container=api level=info request completed\n")
            }
        }
        val bounded = rawLog.retainUtf8Tail(RuntimeResourceBudget.DOCKER_LOG_MAX_UI_BYTES)
        assertTrue(bounded.wasTruncated)
        assertTrue(bounded.content.toByteArray().size <= RuntimeResourceBudget.DOCKER_LOG_MAX_UI_BYTES)

        withDeviceBaseline(
            content = {
                val scroll = rememberScrollState()
                Column(Modifier.fillMaxSize()) {
                    Text("日志视图 ${visibleRevision.intValue}")
                    Text(
                        text = bounded.content,
                        modifier = Modifier.verticalScroll(scroll),
                    )
                }
            },
            exercise = {
                repeat(PerformanceAcceptanceBaseline.MIN_FRAME_SAMPLES + 3) { revision ->
                    compose.activity.runOnUiThread { visibleRevision.intValue = revision }
                    compose.waitForIdle()
                }
            },
        )
    }

    private fun withDeviceBaseline(
        content: @Composable () -> Unit,
        exercise: () -> Unit,
    ) {
        val activity = compose.activity
        val showMeasuredContent = mutableStateOf(false)
        val frameDurations = Collections.synchronizedList(mutableListOf<Long>())
        val listener = Window.OnFrameMetricsAvailableListener { _, frameMetrics, _ ->
            frameMetrics.getMetric(FrameMetrics.TOTAL_DURATION)
                .takeIf { it > 0 }
                ?.let(frameDurations::add)
        }
        // Keep warmup and the measured page in one Composition; the test rule
        // intentionally forbids resetting Activity content between phases.
        compose.setContent {
            MaterialTheme {
                if (showMeasuredContent.value) content() else Text("性能基线预热")
            }
        }
        compose.waitForIdle()
        val beforePssKb = currentPssKb()
        activity.window.addOnFrameMetricsAvailableListener(listener, Handler(Looper.getMainLooper()))
        val startedAt = android.os.SystemClock.elapsedRealtime()
        try {
            activity.runOnUiThread { showMeasuredContent.value = true }
            compose.waitForIdle()
            exercise()
            compose.waitForIdle()
        } finally {
            activity.window.removeOnFrameMetricsAvailableListener(listener)
        }

        val elapsedMillis = android.os.SystemClock.elapsedRealtime() - startedAt
        val pssGrowthKb = (currentPssKb() - beforePssKb).coerceAtLeast(0)
        assertTrue("operation exceeded ${PerformanceAcceptanceBaseline.MAX_OPERATION_MILLIS}ms", elapsedMillis <= PerformanceAcceptanceBaseline.MAX_OPERATION_MILLIS)
        assertTrue("PSS grew ${pssGrowthKb}KB", pssGrowthKb <= PerformanceAcceptanceBaseline.MAX_PSS_GROWTH_KB)
        assertTrue("only ${frameDurations.size} frame samples collected", frameDurations.size >= PerformanceAcceptanceBaseline.MIN_FRAME_SAMPLES)
        val p95 = frameDurations.sorted()[(frameDurations.lastIndex * 95) / 100] / 1_000_000L
        assertTrue("p95 frame duration was ${p95}ms", p95 <= PerformanceAcceptanceBaseline.MAX_P95_FRAME_MILLIS)
        assertEquals(PerformanceAcceptanceBaseline.MAX_ANR_PROCESS_STATES, ownAnrStateCount())
    }

    private fun currentPssKb(): Int = Debug.MemoryInfo().also(Debug::getMemoryInfo).totalPss

    private fun ownAnrStateCount(): Int {
        val manager = compose.activity.getSystemService(ActivityManager::class.java)
        return manager.processesInErrorState.orEmpty().count { state ->
            state.processName == compose.activity.packageName &&
                state.condition == ActivityManager.ProcessErrorStateInfo.NOT_RESPONDING
        }
    }
}
