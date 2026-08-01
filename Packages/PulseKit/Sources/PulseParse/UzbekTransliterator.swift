import Foundation

/// Maps Uzbek Cyrillic into Uzbek Latin.
///
/// Uzbek is officially written in Latin script, but Cyrillic is still in daily use — older users type it,
/// older keyboards default to it, and plenty of signage and habit keeps it alive. Rather than duplicate
/// every lexicon entry in both scripts, we transliterate Cyrillic input into Latin and match once.
///
/// The four letters that make Uzbek Cyrillic its own alphabet — ў, қ, ғ, ҳ — carry the distinctions that
/// matter most here: `ў → o'` and `ғ → g'` produce exactly the apostrophe-bearing Latin letters that
/// Uzbek orthography depends on, and `сўм → so'm` is the single most important word in this app.
public enum UzbekTransliterator {

    /// Single Cyrillic letters to their Latin equivalents. Every source is one character, so a plain
    /// character-by-character walk is sufficient — no longest-match needed.
    private static let map: [Character: String] = [
        "а": "a", "б": "b", "в": "v", "г": "g", "д": "d",
        "е": "e", "ё": "yo", "ж": "j", "з": "z", "и": "i",
        "й": "y", "к": "k", "л": "l", "м": "m", "н": "n",
        "о": "o", "п": "p", "р": "r", "с": "s", "т": "t",
        "у": "u", "ф": "f", "х": "x", "ц": "ts", "ч": "ch",
        "ш": "sh", "щ": "shch", "ъ": "'", "ы": "i", "ь": "",
        "э": "e", "ю": "yu", "я": "ya",

        // The Uzbek-specific letters.
        "ў": "o'", "қ": "q", "ғ": "g'", "ҳ": "h",
    ]

    /// Transliterate any Cyrillic in `text`; leave everything else untouched.
    ///
    /// Input is expected to be lowercased already (the normalizer does this first), but uppercase is
    /// handled anyway so the function is safe to call on raw text.
    public static func cyrillicToLatin(_ text: String) -> String {
        var result = ""
        result.reserveCapacity(text.count)

        for character in text {
            if let replacement = map[character] {
                result += replacement
            } else if let lowered = character.lowercased().first, let replacement = map[lowered] {
                // Preserve the leading capital: `Сўм` → `So'm`, not `SO'M`.
                result += replacement.capitalizedFirstLetter()
            } else {
                result.append(character)
            }
        }
        return result
    }

    /// Whether the text contains anything this transliterator would change.
    public static func containsCyrillic(_ text: String) -> Bool {
        text.contains { map[$0] != nil || map[Character($0.lowercased())] != nil }
    }
}

extension String {
    fileprivate func capitalizedFirstLetter() -> String {
        guard let first else { return self }
        return first.uppercased() + dropFirst()
    }
}
