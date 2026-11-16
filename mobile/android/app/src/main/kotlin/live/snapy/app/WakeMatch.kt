package live.snapy.app

/**
 * Did the offline recogniser hear the wake word? MIRROR of wakeMatches() in
 * lib/core_runtime/phone_services.dart (tested there).
 *
 * In grammar mode Vosk returns only the wake phrases' words, plus "[unk]" for everything else,
 * so "Hey Snapy, open YouTube" comes back as "hey snappy [unk] [unk]". The old check dropped any
 * result containing "[unk]" and missed exactly that. Rules:
 *  - "[unk]" tokens are ignored;
 *  - a whole phrase must be present as words ("hey" alone never wakes Snapy; neither does a
 *    custom name the model doesn't know, which Vosk silently drops from the grammar);
 *  - case and extra spaces don't matter.
 */
object WakeMatch {
    fun matches(heard: String?, phrases: List<String>): Boolean {
        val words = (heard ?: "").lowercase().split(Regex("\\s+")).filter { it.isNotEmpty() && it != "[unk]" }
        if (words.isEmpty()) return false
        val text = " " + words.joinToString(" ") + " "
        return phrases.any { p ->
            val w = p.lowercase().trim().split(Regex("\\s+")).filter { it.isNotEmpty() }
            w.isNotEmpty() && text.contains(" " + w.joinToString(" ") + " ")
        }
    }
}
