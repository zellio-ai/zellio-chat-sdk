package ai.zellio.chat.internal.core

import kotlin.math.roundToLong

/** Steps in seconds, then the last step repeats. Jitter is +-[jitter] of the step. */
internal class Backoff(
    private val stepsSeconds: LongArray = SSE_STEPS,
    private val jitter: Double = 0.2,
    private val random: () -> Double = { Math.random() },
) {
    private var attempt = 0

    internal val attempts: Int get() = attempt

    internal fun nextDelayMs(): Long {
        val base = stepsSeconds[minOf(attempt, stepsSeconds.size - 1)] * 1000.0
        attempt++
        val factor = 1.0 + (random() * 2.0 - 1.0) * jitter
        return (base * factor).roundToLong().coerceAtLeast(0)
    }

    internal fun reset() {
        attempt = 0
    }

    internal companion object {
        /** Contract: 1, 2, 4, 8, 16, then 30 seconds. */
        internal val SSE_STEPS = longArrayOf(1, 2, 4, 8, 16, 30)

        /** Offline queue retries. */
        internal val OUTBOX_STEPS = longArrayOf(2, 5, 10, 30, 60)
    }
}
