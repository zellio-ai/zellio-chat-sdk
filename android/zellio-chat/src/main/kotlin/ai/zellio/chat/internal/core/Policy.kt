package ai.zellio.chat.internal.core

/** Which language the chat uses. Independent of the device language once chosen. */
internal enum class LocaleOption { AUTO, AR, EN }

internal object LocaleChooser {
    /**
     * Order: the code override, then the snapshot policy (`single` wins; for `both`, `startIn: browser`
     * means the device language if it is ar or en, else `defaultLocale`). With no snapshot yet, the device
     * language if it is ar or en, else English.
     */
    internal fun choose(option: LocaleOption, policy: LanguagePolicy?, deviceLanguage: String?): ChatLocale {
        when (option) {
            LocaleOption.AR -> return ChatLocale.AR
            LocaleOption.EN -> return ChatLocale.EN
            LocaleOption.AUTO -> Unit
        }
        val device = ChatLocale.fromTag(deviceLanguage)
        if (policy == null) return device ?: ChatLocale.EN
        if (policy.mode == "single") return ChatLocale.fromTag(policy.locale) ?: device ?: ChatLocale.EN
        val fallback = ChatLocale.fromTag(policy.defaultLocale) ?: ChatLocale.EN
        return when (policy.startIn) {
            "ar" -> ChatLocale.AR
            "en" -> ChatLocale.EN
            else -> device ?: fallback
        }
    }
}

internal enum class Gate { OPEN, NEEDS_CONSENT, WAITING_FOR_CONFIG }

/** "No session, no history, no stream before Accept." */
internal object ConsentGate {
    /**
     * `accepted` is what the customer accepted on this install (null if never). A publish that changes only a color or
     * a label must not ask again: the card comes back only when the consent text or the privacy link changed.
     */
    internal fun state(snapshot: Snapshot?, accepted: ConsentTerms?): Gate = when {
        snapshot == null -> Gate.WAITING_FOR_CONFIG
        !snapshot.behavior.consentRequired -> Gate.OPEN
        accepted == snapshot.behavior.consentTerms -> Gate.OPEN
        else -> Gate.NEEDS_CONSENT
    }
}

internal object SemVer {
    /** Negative when a < b. Missing or bad parts count as 0. A pre-release suffix is ignored. */
    internal fun compare(a: String, b: String): Int {
        val pa = parts(a)
        val pb = parts(b)
        for (i in 0 until 3) {
            val c = pa[i].compareTo(pb[i])
            if (c != 0) return c
        }
        return 0
    }

    private fun parts(v: String): IntArray {
        val core = v.trim().removePrefix("v").substringBefore('-').substringBefore('+').split('.')
        return IntArray(3) { core.getOrNull(it)?.toIntOrNull() ?: 0 }
    }
}

/** Which home modules show: `locales`, `availability` and `customer` visibility. `paths` is ignored on mobile. */
internal object ModuleVisibility {
    internal fun visible(module: HomeModule, locale: ChatLocale, online: Boolean, identified: Boolean): Boolean {
        val v = module.visibility
        if (v.locales != null && v.locales.none { ChatLocale.fromTag(it) == locale }) return false
        when (v.availability) {
            "online" -> if (!online) return false
            "offline" -> if (online) return false
        }
        when (v.customer) {
            "verified" -> if (!identified) return false
            "anonymous" -> if (identified) return false
        }
        return true
    }
}
