import Foundation
import Testing

@testable import PulseParse

@Suite("UzbekTransliterator")
struct UzbekTransliteratorTests {

    @Test("The Uzbek-specific letters map to their apostrophe-bearing Latin forms")
    func uzbekSpecificLetters() {
        // These four letters are what make Uzbek Cyrillic a different alphabet from Russian.
        #expect(UzbekTransliterator.cyrillicToLatin("ў") == "o'")
        #expect(UzbekTransliterator.cyrillicToLatin("ғ") == "g'")
        #expect(UzbekTransliterator.cyrillicToLatin("қ") == "q")
        #expect(UzbekTransliterator.cyrillicToLatin("ҳ") == "h")
    }

    @Test("The most important word in the app transliterates correctly")
    func soum() {
        #expect(UzbekTransliterator.cyrillicToLatin("сўм") == "so'm")
        #expect(UzbekTransliterator.cyrillicToLatin("сум") == "sum")
    }

    @Test("Everyday money vocabulary")
    func vocabulary() {
        #expect(UzbekTransliterator.cyrillicToLatin("минг") == "ming")
        #expect(UzbekTransliterator.cyrillicToLatin("кеча") == "kecha")
        #expect(UzbekTransliterator.cyrillicToLatin("бугун") == "bugun")
        #expect(UzbekTransliterator.cyrillicToLatin("нон") == "non")
        #expect(UzbekTransliterator.cyrillicToLatin("гўшт") == "go'sht")
        #expect(UzbekTransliterator.cyrillicToLatin("ижара") == "ijara")
        #expect(UzbekTransliterator.cyrillicToLatin("тўй") == "to'y")
    }

    @Test("Digraph letters expand")
    func digraphs() {
        #expect(UzbekTransliterator.cyrillicToLatin("ш") == "sh")
        #expect(UzbekTransliterator.cyrillicToLatin("ч") == "ch")
        #expect(UzbekTransliterator.cyrillicToLatin("ё") == "yo")
        #expect(UzbekTransliterator.cyrillicToLatin("ю") == "yu")
        #expect(UzbekTransliterator.cyrillicToLatin("я") == "ya")
    }

    @Test("Digits, spaces, and Latin text pass through untouched")
    func passthrough() {
        #expect(UzbekTransliterator.cyrillicToLatin("45 000") == "45 000")
        #expect(UzbekTransliterator.cyrillicToLatin("taksi 25") == "taksi 25")
        #expect(UzbekTransliterator.cyrillicToLatin("такси 25 минг") == "taksi 25 ming")
    }

    @Test("A leading capital is preserved rather than shouted")
    func capitalization() {
        #expect(UzbekTransliterator.cyrillicToLatin("Сўм") == "So'm")
        #expect(UzbekTransliterator.cyrillicToLatin("Шу") == "Shu")
    }

    @Test("Cyrillic detection")
    func detection() {
        #expect(UzbekTransliterator.containsCyrillic("минг"))
        #expect(UzbekTransliterator.containsCyrillic("taksi 25 минг"))
        #expect(!UzbekTransliterator.containsCyrillic("taksi 25 ming"))
        #expect(!UzbekTransliterator.containsCyrillic("45 000"))
    }
}

@Suite("Script detection")
struct ScriptDetectionTests {

    @Test("Pure scripts")
    func pureScripts() {
        #expect(TextNormalizer.detectScript("obed uchun 45 ming") == .latin)
        #expect(TextNormalizer.detectScript("45 000") == .unknown)
    }

    @Test("Uzbek-specific Cyrillic letters are decisive")
    func uzbekCyrillic() {
        #expect(TextNormalizer.detectScript("сўм") == .uzbekCyrillic)
        #expect(TextNormalizer.detectScript("гўшт олдим") == .uzbekCyrillic)
    }

    @Test("Russian-only letters are decisive the other way")
    func russianCyrillic() {
        #expect(TextNormalizer.detectScript("потратил тысячу") == .russianCyrillic)
        #expect(TextNormalizer.detectScript("борщ") == .russianCyrillic)
    }

    @Test("Letters shared by both alphabets are not treated as Russian markers")
    func sharedLettersAreNotRussianMarkers() {
        // Uzbek Cyrillic keeps ц, ъ, ь and э. Treating any of them as Russian-only would misroute
        // ordinary Uzbek words into the wrong transliteration path.
        #expect(TextNormalizer.detectScript("цех") != .russianCyrillic)
        #expect(TextNormalizer.detectScript("эълон") != .russianCyrillic)
    }

    @Test("Cyrillic with no distinguishing letters is honestly reported as ambiguous")
    func ambiguous() {
        // The two alphabets differ by exactly {ы, щ} and {ў, қ, ғ, ҳ}. A phrase containing none of them
        // — which is most short money phrases — cannot be classified, and saying so is the honest answer.
        #expect(TextNormalizer.detectScript("сум") == .ambiguousCyrillic)
        #expect(TextNormalizer.detectScript("нон") == .ambiguousCyrillic)
        #expect(TextNormalizer.detectScript("потратил 300 рублей") == .ambiguousCyrillic)
    }

    @Test("Code-switched input is reported as mixed, not forced into one language")
    func mixed() {
        #expect(TextNormalizer.detectScript("taksiga 25 тыщ") == .mixed)
        #expect(TextNormalizer.detectScript("kommunalka to'ladim 300 тыс") == .mixed)
    }
}

@Suite("TextNormalizer")
struct TextNormalizerTests {

    private let normalizer = TextNormalizer()

    @Test("Every apostrophe variant collapses to one")
    func apostrophes() {
        // iOS smart punctuation, the orthographic Uzbek modifier letter, and a plain typed quote must
        // all end up identical, or `so'm` fails to match depending on how it was entered.
        let variants = ["so'm", "so\u{2019}m", "so\u{02BB}m", "so\u{02BC}m", "so\u{0060}m"]
        let results = Set(variants.map { normalizer.normalize($0).normalized })
        #expect(results == ["so'm"])
    }

    @Test("Dictation's missing apostrophes are covered by a separate match form")
    func apostropheless() {
        // Speech-to-text reliably drops these, so `som` must still reach the `so'm` lexicon entry.
        let result = normalizer.normalize("so'm")
        #expect(result.apostropheless == "som")
        #expect(result.matchForms.contains("som"))
        #expect(result.matchForms.contains("so'm"))
    }

    @Test("Cyrillic input gains a Latin match form")
    func transliteratedForm() {
        let result = normalizer.normalize("25 минг сўм")
        #expect(result.normalized == "25 минг сўм")
        #expect(result.transliterated == "25 ming so'm")
        #expect(result.matchForms.contains("25 ming so'm"))
    }

    @Test("Transliteration only ever adds a form; the Cyrillic original survives for Russian matching")
    func transliterationIsAdditive() {
        // "потратил 300 рублей" has none of {ы, щ}, so script detection cannot tell it from Uzbek and
        // the Uzbek transliterator runs over it. That is fine, and this is the invariant that makes it
        // fine: the untouched Cyrillic form stays in matchForms, so the Russian lexicon still matches.
        // Nothing is lost — a candidate is gained.
        let result = normalizer.normalize("потратил 300 рублей")
        #expect(result.normalized == "потратил 300 рублей")
        #expect(result.matchForms.contains("потратил 300 рублей"))
        #expect(result.matchForms.count > 1)
    }

    @Test("Text with decisive Russian letters skips transliteration entirely")
    func decisivelyRussianSkipsTransliteration() {
        let result = normalizer.normalize("потратил тысячу")
        #expect(result.script == .russianCyrillic)
        #expect(result.transliterated == result.normalized)
    }

    @Test("Case and whitespace are normalised")
    func caseAndWhitespace() {
        let result = normalizer.normalize("  OBED   uchun\t45   MING  ")
        #expect(result.normalized == "obed uchun 45 ming")
    }

    @Test("The original text is always preserved verbatim")
    func originalPreserved() {
        // The UI shows the user what it heard; altering that would be its own kind of lie.
        let input = "  OBED   uchun 45 MING  "
        #expect(normalizer.normalize(input).original == input)
    }

    @Test("Match forms are deduplicated")
    func matchFormsDeduplicated() {
        // Plain Latin with no apostrophes yields one form, not three copies of it.
        #expect(normalizer.normalize("taksi 25 ming").matchForms == ["taksi 25 ming"])
    }

    // MARK: Tokenization

    @Test("Words and numbers separate")
    func tokenizeBasics() {
        #expect(TextNormalizer.tokenize("obed uchun 45 ming") == ["obed", "uchun", "45", "ming"])
    }

    @Test("Apostrophes stay inside words because they are letters in Uzbek")
    func tokenizeApostrophes() {
        #expect(TextNormalizer.tokenize("45 ming so'm") == ["45", "ming", "so'm"])
        #expect(TextNormalizer.tokenize("to'ladim") == ["to'ladim"])
    }

    @Test("Grouped and decimal numbers survive as single tokens")
    func tokenizeNumbers() {
        #expect(TextNormalizer.tokenize("45,000") == ["45,000"])
        #expect(TextNormalizer.tokenize("45 000 so'm") == ["45 000", "so'm"])
        #expect(TextNormalizer.tokenize("12.35 dollar") == ["12.35", "dollar"])
        #expect(TextNormalizer.tokenize("1 234 567") == ["1 234 567"])
    }

    @Test("A trailing separator is not swallowed into the number")
    func tokenizeTrailingSeparator() {
        // "45." at the end of a sentence is the number 45, not a malformed decimal.
        #expect(TextNormalizer.tokenize("spent 45.") == ["spent", "45"])
        #expect(TextNormalizer.tokenize("45, dollar") == ["45", "dollar"])
    }

    @Test("Punctuation is dropped, and empty input yields no tokens")
    func tokenizePunctuation() {
        #expect(TextNormalizer.tokenize("obed, uchun! 45?") == ["obed", "uchun", "45"])
        #expect(TextNormalizer.tokenize("") == [])
        #expect(TextNormalizer.tokenize("   ") == [])
    }

    @Test("Numbers run together with words still split")
    func tokenizeRunTogether() {
        // Dictation produces this constantly.
        #expect(TextNormalizer.tokenize("45ming") == ["45", "ming"])
        #expect(TextNormalizer.tokenize("taksi25") == ["taksi", "25"])
    }
}
