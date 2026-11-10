package ai.zellio.chat.internal.platform

import ai.zellio.chat.R
import ai.zellio.chat.internal.core.ChatLocale
import ai.zellio.chat.internal.core.Contrast
import ai.zellio.chat.internal.core.Guard
import ai.zellio.chat.internal.core.Palette
import ai.zellio.chat.internal.engine.BannerInfo
import android.app.Activity
import android.content.Context
import android.graphics.Color
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.os.Handler
import android.os.Looper
import android.util.TypedValue
import android.view.Gravity
import android.view.MotionEvent
import android.view.View
import android.view.ViewGroup
import android.widget.FrameLayout
import android.widget.LinearLayout
import android.widget.TextView
import androidx.core.view.ViewCompat
import androidx.core.view.WindowInsetsCompat

/**
 * A small top banner for a new reply while chat is closed and the app is open. Plain views, so it works on top of
 * any host activity, with or without Compose. Swipe up dismisses, tap opens, it hides itself after 4 seconds.
 */
internal class InAppBanner(private val onOpen: (String?) -> Unit) {
    private val handler = Handler(Looper.getMainLooper())
    private var current: View? = null
    private var hide: Runnable? = null

    internal fun show(activity: Activity, info: BannerInfo, palette: Palette, locale: ChatLocale, brandName: String, reducedMotion: Boolean) {
        Guard.run("banner") {
            dismiss(animated = false)
            val host = activity.findViewById<ViewGroup>(android.R.id.content) ?: return
            val ctx = AndroidEnv.localizedContext(activity, locale)
            val dp = ctx.resources.displayMetrics.density
            fun px(v: Float) = (v * dp).toInt()
            val bg = Contrast.toArgb(if (palette.dark) palette.bgAlt else palette.bg)
            val line = Contrast.toArgb(palette.line)
            val ink = Contrast.toArgb(palette.ink)
            val ink2 = Contrast.toArgb(palette.ink2)

            val body = if (info.preview.isNullOrBlank()) ctx.getString(R.string.zc_thread_new_message) else info.preview
            val title = listOf(info.name, brandName).filter { it.isNotBlank() }.distinct().joinToString(" · ")

            val card = LinearLayout(ctx).apply {
                orientation = LinearLayout.HORIZONTAL
                gravity = Gravity.CENTER_VERTICAL
                layoutDirection = if (locale.rtl) View.LAYOUT_DIRECTION_RTL else View.LAYOUT_DIRECTION_LTR
                setPadding(px(14f), px(12f), px(14f), px(12f))
                background = GradientDrawable().apply {
                    setColor(bg)
                    cornerRadius = 18 * dp
                    setStroke(px(1f), line)
                }
                elevation = 12 * dp
                isClickable = true
                contentDescription = "$title, $body"
                accessibilityLiveRegion = View.ACCESSIBILITY_LIVE_REGION_POLITE
            }
            val avatar = TextView(ctx).apply {
                gravity = Gravity.CENTER
                text = (info.name.trim().firstOrNull() ?: '?').uppercase()
                setTextSize(TypedValue.COMPLEX_UNIT_SP, 16f)
                typeface = Typeface.DEFAULT_BOLD
                setTextColor(if (palette.dark) Color.parseColor("#E7E9F6") else Color.parseColor("#3B2A86"))
                background = GradientDrawable().apply {
                    shape = GradientDrawable.OVAL
                    setColor(if (palette.dark) Color.parseColor("#2B3556") else Color.parseColor("#D9D3F5"))
                }
                importantForAccessibility = View.IMPORTANT_FOR_ACCESSIBILITY_NO
            }
            card.addView(avatar, LinearLayout.LayoutParams(px(40f), px(40f)))
            val texts = LinearLayout(ctx).apply {
                orientation = LinearLayout.VERTICAL
                setPadding(px(12f), 0, px(12f), 0)
            }
            texts.addView(TextView(ctx).apply {
                text = title
                maxLines = 1
                ellipsize = android.text.TextUtils.TruncateAt.END
                setTextSize(TypedValue.COMPLEX_UNIT_SP, 14.5f)
                typeface = Typeface.create(Typeface.DEFAULT, 600, false)
                setTextColor(ink)
                importantForAccessibility = View.IMPORTANT_FOR_ACCESSIBILITY_NO
            })
            texts.addView(TextView(ctx).apply {
                text = body
                maxLines = 1
                ellipsize = android.text.TextUtils.TruncateAt.END
                setTextSize(TypedValue.COMPLEX_UNIT_SP, 14f)
                setTextColor(ink2)
                importantForAccessibility = View.IMPORTANT_FOR_ACCESSIBILITY_NO
            })
            card.addView(texts, LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f))

            val insets = ViewCompat.getRootWindowInsets(host)?.getInsets(WindowInsetsCompat.Type.systemBars() or WindowInsetsCompat.Type.displayCutout())
            val params = FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT).apply {
                gravity = Gravity.TOP
                setMargins(px(12f), (insets?.top ?: 0) + px(8f), px(12f), 0)
            }
            host.addView(card, params)
            current = card

            var downY = 0f
            var moved = false
            card.setOnTouchListener { v, e ->
                when (e.action) {
                    MotionEvent.ACTION_DOWN -> { downY = e.rawY; moved = false; true }
                    MotionEvent.ACTION_MOVE -> {
                        val dy = e.rawY - downY
                        if (dy < 0) { v.translationY = dy; moved = true }
                        true
                    }
                    MotionEvent.ACTION_UP -> {
                        if (moved && v.translationY < -24 * dp) dismiss(animated = true)
                        else {
                            v.animate().translationY(0f).setDuration(120).start()
                            if (!moved) {
                                dismiss(animated = false)
                                onOpen(info.conversationId)
                            }
                        }
                        true
                    }
                    else -> true
                }
            }
            card.alpha = 0f
            card.post {
                if (reducedMotion) {
                    card.animate().alpha(1f).setDuration(120).start()
                } else {
                    card.translationY = -card.height.toFloat()
                    card.animate().alpha(1f).translationY(0f).setDuration(200).start()
                }
            }
            card.announceForAccessibility("$title, $body")
            val r = Runnable { dismiss(animated = true) }
            hide = r
            handler.postDelayed(r, 4_000)
        }
    }

    internal fun dismiss(animated: Boolean) {
        Guard.run("banner dismiss") {
            val view = current ?: return
            current = null
            hide?.let { handler.removeCallbacks(it) }
            hide = null
            val remove = { (view.parent as? ViewGroup)?.removeView(view); Unit }
            if (animated) view.animate().alpha(0f).translationY(-view.height.toFloat()).setDuration(160).withEndAction { remove() }.start() else remove()
        }
    }
}
