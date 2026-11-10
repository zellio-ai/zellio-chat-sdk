package ai.zellio.chat.internal.core

import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineExceptionHandler

internal enum class LogLevel { NONE, ERROR, WARN, INFO, DEBUG }

internal fun interface LogSink {
    fun log(level: LogLevel, message: String)
}

/**
 * SDK logging. Chat text, tokens and headers must never be passed in. Callers log ids, codes and
 * exception class names only.
 */
internal object Log {
    @Volatile
    internal var level: LogLevel = LogLevel.WARN

    @Volatile
    internal var sink: LogSink = LogSink { _, _ -> }

    internal fun e(message: String, t: Throwable? = null) = emit(LogLevel.ERROR, message, t)
    internal fun w(message: String, t: Throwable? = null) = emit(LogLevel.WARN, message, t)
    internal fun i(message: String) = emit(LogLevel.INFO, message, null)
    internal fun d(message: String) = emit(LogLevel.DEBUG, message, null)

    private fun emit(at: LogLevel, message: String, t: Throwable?) {
        try {
            if (level == LogLevel.NONE || at.ordinal > level.ordinal) return
            sink.log(at, if (t == null) message else "$message (${t.javaClass.simpleName})")
        } catch (_: Throwable) {
            // logging must never throw
        }
    }
}

/** Contains every fault: nothing thrown inside the SDK may reach the host app. */
internal object Guard {
    @Volatile
    internal var onFault: (Throwable) -> Unit = {}

    internal val handler: CoroutineExceptionHandler = CoroutineExceptionHandler { _, t -> report("coroutine", t) }

    internal fun report(where: String, t: Throwable) {
        if (t is CancellationException) return
        Log.e("fault in $where", t)
        try {
            onFault(t)
        } catch (_: Throwable) {
        }
    }

    internal inline fun run(where: String, block: () -> Unit) {
        try {
            block()
        } catch (t: Throwable) {
            report(where, t)
        }
    }

    internal inline fun <T> call(where: String, fallback: T, block: () -> T): T =
        try {
            block()
        } catch (t: Throwable) {
            report(where, t)
            fallback
        }
}
