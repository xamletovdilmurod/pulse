import Foundation

/// Writing system a piece of text appears to use.
///
/// This is a *hint*, never a decision. Short money utterances are genuinely ambiguous — "сум" is written
/// with letters shared by Russian and Uzbek Cyrillic, and plenty of Tashkent input mixes scripts inside a
/// single phrase. Anything that branches hard on a detected script will be wrong often enough to matter,
/// so the parser matches against every language's vocabulary and lets scoring decide.
public enum Script: String, Hashable, Sendable {
    case latin
    /// Cyrillic containing letters unique to the Uzbek alphabet (ў, қ, ғ, ҳ).
    case uzbekCyrillic
    /// Cyrillic containing letters Uzbek does not use (щ, ы, э, ё in Russian positions).
    case russianCyrillic
    /// Cyrillic that could be either.
    case ambiguousCyrillic
    case mixed
    case unknown
}

/// Cleans raw user input into a form the lexicon can match against.
///
/// Input arrives from a keyboard *and* from dictation, and both are messy in their own ways: dictation
/// drops the apostrophes that Uzbek Latin depends on (`so'm` → `som`, `o'n` → `on`), keyboards produce
/// half a dozen different apostrophe characters, and nobody punctuates when muttering at a phone.
///
/// The normalizer never throws away the original text — it produces *additional* forms to match against.
/// Matching then tries all of them, so a phrase written in Cyrillic still hits a lexicon entry recorded
/// in Latin without anyone having to guess the language up front.
public struct TextNormalizer: Sendable {

    public init() {}

    /// The set of forms a matcher should try for one input.
    public struct Normalized: Hashable, Sendable {
        /// Exactly what the user typed or said.
        public let original: String
        /// Lowercased, apostrophe-unified, whitespace-collapsed.
        public let normalized: String
        /// `normalized` with Uzbek Cyrillic mapped into Latin, when that applies. Otherwise equal to
        /// `normalized`.
        public let transliterated: String
        /// `normalized` with apostrophes removed, matching what dictation tends to produce.
        public let apostropheless: String
        public let script: Script
        public let tokens: [String]

        /// Every distinct string worth attempting a lexicon lookup against, cheapest first.
        public var matchForms: [String] {
            var forms = [normalized]
            for candidate in [transliterated, apostropheless] where !forms.contains(candidate) {
                forms.append(candidate)
            }
            return forms
        }
    }

    public func normalize(_ input: String) -> Normalized {
        let script = Self.detectScript(input)

        let folded = Self.unifyApostrophes(input)
            .precomposedStringWithCanonicalMapping
            .lowercased()
        let collapsed = Self.collapseAbbreviationPeriods(Self.collapseWhitespace(folded))

        let transliterated: String =
            switch script {
            case .uzbekCyrillic, .ambiguousCyrillic, .mixed:
                UzbekTransliterator.cyrillicToLatin(collapsed)
            case .latin, .russianCyrillic, .unknown:
                collapsed
            }

        return Normalized(
            original: input,
            normalized: collapsed,
            transliterated: transliterated,
            apostropheless: Self.stripApostrophes(collapsed),
            script: script,
            tokens: Self.tokenize(collapsed)
        )
    }

    // MARK: - Apostrophes

    /// Every character users and keyboards produce where Uzbek Latin wants an apostrophe.
    ///
    /// Uzbek Latin distinguishes `o'`/`g'` from bare `o`/`g`, so these are letters, not punctuation, and
    /// collapsing them to one canonical form is load-bearing.
    private static let apostropheVariants: Set<Character> = [
        "\u{2018}",  // ‘ left single quote
        "\u{2019}",  // ’ right single quote — what iOS smart punctuation inserts
        "\u{02BB}",  // ʻ modifier turned comma — the orthographically correct Uzbek one
        "\u{02BC}",  // ʼ modifier apostrophe
        "\u{02B9}",  // ʹ modifier prime
        "\u{00B4}",  // ´ acute accent
        "\u{0060}",  // ` grave accent
        "\u{2032}",  // ′ prime
    ]

    static func unifyApostrophes(_ text: String) -> String {
        String(text.map { apostropheVariants.contains($0) ? "'" : $0 })
    }

    static func stripApostrophes(_ text: String) -> String {
        text.replacingOccurrences(of: "'", with: "")
    }

    // MARK: - Whitespace and tokens

    /// Symbols that name a currency on their own.
    static let currencySymbols: Set<Character> = ["$", "€", "£", "₽", "₸", "₺", "¥", "₩", "₹", "﷼"]

    static func collapseWhitespace(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// Remove periods that sit between letters, so dotted abbreviations survive tokenization.
    ///
    /// `у.е.` — *условные единицы*, the post-Soviet way of saying "dollars" — is the case that forces
    /// this: without it the periods split the word into `у` and `е`, the currency is never recognised,
    /// and a dollar amount silently gets the so'm implied-thousands treatment. Digits are untouched, so
    /// `12.35` keeps its decimal point.
    static func collapseAbbreviationPeriods(_ text: String) -> String {
        var result = ""
        result.reserveCapacity(text.count)
        let characters = Array(text)

        for index in characters.indices {
            let character = characters[index]
            if character == "." {
                let previous = index > 0 ? characters[index - 1] : nil
                let next = index + 1 < characters.count ? characters[index + 1] : nil
                // Drop the period when it is bounded by letters on at least one side and never by
                // digits — "у.е." and "у.е" both collapse, "12.35" does not.
                let previousIsLetter = previous?.isLetter ?? false
                let nextIsLetter = next?.isLetter ?? false
                let touchesDigit = (previous?.isNumber ?? false) || (next?.isNumber ?? false)
                if !touchesDigit && (previousIsLetter || nextIsLetter) {
                    continue
                }
            }
            result.append(character)
        }
        return result
    }

    /// Split into words and numbers.
    ///
    /// Digit groups keep their internal separators (`45,000`, `45 000`, `12.35`) so the amount parser can
    /// decide what they mean — it is the only layer with enough context to know whether a comma is a
    /// decimal point or a thousands separator.
    static func tokenize(_ text: String) -> [String] {
        var tokens: [String] = []
        var current = ""

        func flush() {
            if !current.isEmpty {
                tokens.append(current)
                current = ""
            }
        }

        let characters = Array(text)
        var index = 0
        while index < characters.count {
            let character = characters[index]

            if character.isNumber {
                var number = String(character)
                var lookahead = index + 1
                while lookahead < characters.count {
                    let next = characters[lookahead]
                    if next.isNumber {
                        number.append(next)
                        lookahead += 1
                    } else if next == "," || next == "." {
                        // Could be a decimal point or a thousands separator — keep it and let
                        // AmountParser decide, but only when digits actually follow.
                        guard lookahead + 1 < characters.count, characters[lookahead + 1].isNumber
                        else { break }
                        number.append(next)
                        lookahead += 1
                    } else if next == " " || next == "\u{00A0}" {
                        // A space joins digits only as thousands grouping, which means exactly three
                        // digits must follow. "45 000" is one number; "45 12" is two.
                        var digits = 0
                        var probe = lookahead + 1
                        while probe < characters.count, characters[probe].isNumber {
                            digits += 1
                            probe += 1
                        }
                        guard digits == 3 else { break }
                        number.append(next)
                        lookahead += 1
                    } else {
                        break
                    }
                }
                flush()
                tokens.append(number)
                index = lookahead
                continue
            }

            // Currency symbols are words, not punctuation — "$12.50" states a currency as surely as
            // "12.50 dollars" does, and dropping the glyph loses that.
            if Self.currencySymbols.contains(character) {
                flush()
                tokens.append(String(character))
                index += 1
                continue
            }

            if character.isLetter || character == "'" {
                current.append(character)
            } else {
                flush()
            }
            index += 1
        }
        flush()
        return tokens
    }

    // MARK: - Script detection

    /// Letters that exist in Uzbek Cyrillic but not Russian.
    private static let uzbekOnlyCyrillic: Set<Character> = ["ў", "қ", "ғ", "ҳ", "Ў", "Қ", "Ғ", "Ҳ"]

    /// Letters that exist in Russian but not in the Uzbek Cyrillic alphabet.
    ///
    /// Only two qualify. Uzbek Cyrillic keeps ц, ъ, ь and э, so those say nothing about the language —
    /// the alphabets differ by exactly ы and щ in one direction and ў/қ/ғ/ҳ in the other. Most short
    /// money phrases contain none of the six and are therefore genuinely undecidable from script alone,
    /// which is why detection is only ever a hint.
    private static let russianOnlyCyrillic: Set<Character> = ["щ", "ы", "Щ", "Ы"]

    public static func detectScript(_ text: String) -> Script {
        var hasLatin = false
        var hasCyrillic = false
        var hasUzbekMarker = false
        var hasRussianMarker = false

        for character in text where character.isLetter {
            if uzbekOnlyCyrillic.contains(character) {
                hasUzbekMarker = true
                hasCyrillic = true
            } else if russianOnlyCyrillic.contains(character) {
                hasRussianMarker = true
                hasCyrillic = true
            } else if character.isCyrillic {
                hasCyrillic = true
            } else if character.isASCIILetter {
                hasLatin = true
            }
        }

        switch (hasLatin, hasCyrillic) {
        case (false, false):
            return .unknown
        case (true, false):
            return .latin
        case (true, true):
            return .mixed
        case (false, true):
            // Uzbek-specific letters are decisive; Russian-only letters are decisive in the other
            // direction. Text with neither — like "сум" — genuinely could be either.
            if hasUzbekMarker { return .uzbekCyrillic }
            if hasRussianMarker { return .russianCyrillic }
            return .ambiguousCyrillic
        }
    }
}

// MARK: -

extension Character {
    fileprivate var isCyrillic: Bool {
        unicodeScalars.allSatisfy { (0x0400...0x04FF).contains($0.value) }
    }

    fileprivate var isASCIILetter: Bool {
        isLetter && isASCII
    }
}
