package ai.zellio.chat.internal.core

/** Theme overrides from the code (`options.theme`). A null field falls back to the snapshot. */
internal data class ThemeOverrides(
    val mode: String? = null,
    val primaryColor: String? = null,
    val customerMessageColor: String? = null,
    val surfaceColor: String? = null,
)

/** All colors of one chat screen, as `#RRGGBB`. Built from the snapshot appearance, never from device colors. */
internal data class Palette(
    val dark: Boolean,
    val bg: String,
    val bgAlt: String,
    val ink: String,
    val ink2: String,
    val line: String,
    val agentBubble: String,
    val ok: String,
    val bad: String,
    val primary: String,
    val onPrimary: String,
    val customer: String,
    val onCustomer: String,
    val link: String,
    val headerFrom: String,
    val headerTo: String,
    val onHeader: String,
    val sendIdle: String,
    val warnBg: String,
    val warnInk: String,
) {
    /** On phone Home the status bar sits on the header. Everywhere else it sits on the background. */
    internal fun darkStatusIcons(onHomeHeader: Boolean): Boolean =
        if (onHomeHeader) Contrast.luminance(onHeader) < 0.5 else !dark

    internal companion object {
        private const val DARK_BG = "#0F1525"
        private const val LIGHT_INK = "#111426"
        private const val DARK_INK = "#F4F6FC"

        internal fun resolveDark(appearanceTheme: String, overrides: ThemeOverrides, systemDark: Boolean): Boolean =
            when (overrides.mode ?: appearanceTheme) {
                "dark" -> true
                "light" -> false
                else -> systemDark
            }

        internal fun build(appearance: Appearance, overrides: ThemeOverrides, systemDark: Boolean): Palette {
            val dark = resolveDark(appearance.theme, overrides, systemDark)
            val primary = Contrast.normalize(overrides.primaryColor ?: appearance.primaryColor)
            val customer = Contrast.normalize(overrides.customerMessageColor ?: appearance.customerMessageColor)
            val surface = Contrast.normalize(overrides.surfaceColor ?: appearance.surfaceColor)

            val bg: String
            val ink: String
            val ink2: String
            val line: String
            val agent: String
            val alt: String
            val ok: String
            val bad: String
            if (dark) {
                bg = DARK_BG
                ink = DARK_INK
                ink2 = "#AEB6CC"
                line = "#222B42"
                agent = "#1E2740"
                alt = "#161D30"
                ok = "#34D399"
                bad = "#F87171"
            } else {
                bg = surface
                // A dark surfaceColor in light mode: pick the ink by contrast.
                val darkSurface = Contrast.ratio(LIGHT_INK, surface) < Contrast.ratio(DARK_INK, surface)
                ink = if (darkSurface) DARK_INK else LIGHT_INK
                ink2 = if (darkSurface) "#AEB6CC" else "#50556B"
                alt = Contrast.mix(bg, ink, 0.04)
                line = if (darkSurface) Contrast.mix(bg, ink, 0.14) else "#E7E7EF"
                agent = if (darkSurface) Contrast.mix(bg, ink, 0.10) else "#F1F1F6"
                ok = "#16A34A"
                bad = "#D92D32"
            }
            val onPrimary = Contrast.readable(primary).foreground
            val onCustomer = Contrast.readable(customer).foreground
            // Link color: primary if it has at least 4.5:1 on bg, else ink.
            val link = if (Contrast.ratio(primary, bg) >= 4.5) primary else ink
            val headerStyle = appearance.headerStyle
            val from: String
            val to: String
            val onHeader: String
            when (headerStyle) {
                "solid" -> {
                    from = primary; to = primary; onHeader = onPrimary
                }
                "light" -> {
                    from = bg; to = bg; onHeader = ink
                }
                else -> {
                    from = primary
                    to = Contrast.mix(primary, Contrast.BLACK, 0.18)
                    onHeader = Contrast.readable(primary).foreground.let { first ->
                        // The gradient gets darker, so check the darker end as well.
                        if (first == Contrast.BLACK && Contrast.ratio(to, Contrast.BLACK) < 4.5) Contrast.WHITE else first
                    }
                }
            }
            return Palette(
                dark = dark,
                bg = bg, bgAlt = alt, ink = ink, ink2 = ink2, line = line, agentBubble = agent, ok = ok, bad = bad,
                primary = primary, onPrimary = onPrimary, customer = customer, onCustomer = onCustomer,
                link = link, headerFrom = from, headerTo = to, onHeader = onHeader,
                sendIdle = if (dark) "#2B3556" else "#E3E3EB",
                warnBg = if (dark) "#2E1A0E" else "#FFF3E8",
                warnInk = if (dark) "#FDBA74" else "#9A3D00",
            )
        }
    }
}

/** Geometry that depends on `corners` and `density`. */
internal data class Shapes(val bubbleRadius: Int, val tailRadius: Int, val groupedGap: Int, val newSenderGap: Int) {
    internal companion object {
        internal fun of(appearance: Appearance): Shapes {
            val square = appearance.corners == "square"
            val compact = appearance.density == "compact"
            return Shapes(
                bubbleRadius = if (square) 8 else 20,
                tailRadius = if (square) 4 else 6,
                groupedGap = 2,
                newSenderGap = if (compact) 8 else 12,
            )
        }
    }
}
