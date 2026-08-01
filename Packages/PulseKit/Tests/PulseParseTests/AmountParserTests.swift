import Foundation
import Testing

@testable import PulseParse

@Suite("Digit group interpretation")
struct DigitGroupTests {

    private func value(_ token: String) -> Decimal? {
        AmountParser.decimalFromDigits(token)
    }

    @Test("Plain integers")
    func plain() {
        #expect(value("45") == 45)
        #expect(value("45000") == 45_000)
        #expect(value("0") == 0)
    }

    @Test("Grouped thousands, however they were separated")
    func grouped() {
        #expect(value("45,000") == 45_000)
        #expect(value("45 000") == 45_000)
        #expect(value("1 234 567") == 1_234_567)
        #expect(value("1,234,567") == 1_234_567)
    }

    @Test("Decimal fractions")
    func fractions() {
        #expect(value("12.35") == Decimal(string: "12.35"))
        #expect(value("12,35") == Decimal(string: "12.35"))
        #expect(value("0.5") == Decimal(string: "0.5"))
    }

    @Test("Digit count resolves the 45.000 ambiguity")
    func theAmbiguousCase() {
        // Three trailing digits means grouping — "45.000" is forty-five thousand, as a Russian or Uzbek
        // speaker writes it. One or two means a fraction. Nothing else can disambiguate inside a token.
        #expect(value("45.000") == 45_000)
        #expect(value("45.00") == 45)
        #expect(value("45.0") == 45)
    }

    @Test("Non-numeric tokens are rejected")
    func rejects() {
        #expect(value("ming") == nil)
        #expect(value("") == nil)
        #expect(value("abc") == nil)
        #expect(value("45abc") == nil)
    }
}

@Suite("AmountParser")
struct AmountParserTests {

    // MARK: Digits with magnitude words

    @Test("Digits scaled by a magnitude word")
    func digitsWithMagnitude() {
        #expect(principalAmount("45 ming")?.value == 45_000)
        #expect(principalAmount("50k")?.value == 50_000)
        #expect(principalAmount("45 тыс")?.value == 45_000)
        #expect(principalAmount("8 mln")?.value == 8_000_000)
        #expect(principalAmount("3 лям")?.value == 3_000_000)
    }

    @Test("An attached magnitude suffix is found even with no space")
    func attachedSuffix() {
        // Tokenization splits `50k` into `50` + `k`, so this is really a test that it stays joined.
        let match = principalAmount("add expense 50k lunch")
        #expect(match?.value == 50_000)
        #expect(match?.hadExplicitMagnitude == true)
    }

    @Test("A decimal scaled by a magnitude")
    func decimalWithMagnitude() {
        #expect(principalAmount("1.5 mln")?.value == 1_500_000)
        #expect(principalAmount("2.5 ming")?.value == 2_500)
    }

    // MARK: Spelled-out numbers

    @Test("Compound numerals combine additively then scale")
    func compoundNumerals() {
        // двадцать пять тысяч = (20 + 5) × 1000
        #expect(principalAmount("двадцать пять тысяч")?.value == 25_000)
        #expect(principalAmount("сто тысяч")?.value == 100_000)
        #expect(principalAmount("to'rt million")?.value == 4_000_000)
        #expect(principalAmount("ellik ming")?.value == 50_000)
    }

    @Test("Hundreds multiply rather than add")
    func hundredsMultiply() {
        // "besh yuz" is five hundred, not one hundred and five.
        #expect(principalAmount("besh yuz")?.value == 500)
        #expect(principalAmount("ikki yuz ming")?.value == 200_000)
        #expect(principalAmount("besh yuz ming")?.value == 500_000)
    }

    @Test("A bare hundred word stands on its own")
    func bareHundred() {
        #expect(principalAmount("yuz")?.value == 100)
        #expect(principalAmount("сто")?.value == 100)
    }

    @Test("Trailing remainder is added after the scaled group")
    func remainderAfterMagnitude() {
        // 45 ming 500 = 45 500
        #expect(principalAmount("45 ming 500")?.value == 45_500)
        #expect(principalAmount("пять тысяч пятьсот")?.value == 5_500)
    }

    @Test("A bare magnitude word means one of it")
    func bareMagnitude() {
        #expect(principalAmount("ming so'm")?.value == 1_000)
    }

    // MARK: Provenance flags

    @Test("Explicit magnitude is reported, so the caller can decide about implied thousands")
    func magnitudeFlag() {
        #expect(principalAmount("45 ming")?.hadExplicitMagnitude == true)
        // This is the whole point of the flag: `50` alone might be fifty or fifty thousand, and only a
        // layer that knows the language and currency can say which.
        #expect(principalAmount("obedga 50 ketdi")?.hadExplicitMagnitude == false)
        #expect(principalAmount("45 000")?.hadExplicitMagnitude == false)
    }

    @Test("Spelled-out numbers are flagged")
    func spelledOutFlag() {
        #expect(principalAmount("двадцать пять тысяч")?.wasSpelledOut == true)
        #expect(principalAmount("45 000")?.wasSpelledOut == false)
        // Digits plus a magnitude word count as partly spelled out.
        #expect(principalAmount("45 ming")?.wasSpelledOut == true)
    }

    // MARK: Multiple amounts

    @Test("Every amount is returned, not just one")
    func multipleAmounts() {
        // A quantity and a price in one breath — the caller needs both to choose sensibly.
        let all = amounts("2 kg go'sht 40 ming")
        #expect(all.count == 2)
        #expect(all[0].value == 2)
        #expect(all[1].value == 40_000)
    }

    @Test("The principal amount prefers the one carrying a magnitude word")
    func principalPrefersMagnitude() {
        // People attach the magnitude to the price, not to the quantity.
        let match = principalAmount("2 kg go'sht 40 ming")
        #expect(match?.value == 40_000)
        #expect(match?.hadExplicitMagnitude == true)
    }

    @Test("With no magnitude anywhere, the largest value wins")
    func principalFallsBackToLargest() {
        #expect(principalAmount("2 coffees 8 dollars")?.value == 8)
    }

    @Test("Adjacent digit groups stay separate numbers")
    func adjacentDigitsDoNotMerge() {
        let all = amounts("45 12")
        #expect(all.count == 2)
        #expect(all.map(\.value) == [45, 12])
    }

    // MARK: Ranges and no-ops

    @Test("The token range covers exactly the amount expression")
    func tokenRange() {
        let normalized = TextNormalizer().normalize("obed uchun 45 ming so'm")
        let match = SyntheticLexicon.amountParser.principalAmount(in: normalized.tokens)
        // tokens: [obed, uchun, 45, ming, so'm] — the amount is tokens 2..<4.
        #expect(match?.tokenRange == 2..<4)
    }

    @Test("Text with no number yields nothing")
    func noAmount() {
        #expect(principalAmount("obed uchun") == nil)
        #expect(principalAmount("") == nil)
        #expect(amounts("just some words").isEmpty)
    }

    // MARK: Cyrillic input

    @Test("Cyrillic numerals work through the normalizer's transliterated form")
    func cyrillicUzbek() {
        // "25 минг" transliterates to "25 ming", which the lexicon knows.
        let normalized = TextNormalizer().normalize("25 минг сўм")
        let latin = TextNormalizer.tokenize(normalized.transliterated)
        #expect(SyntheticLexicon.amountParser.principalAmount(in: latin)?.value == 25_000)
    }

    @Test("Russian magnitude words are matched in their own script")
    func russianCyrillic() {
        #expect(principalAmount("потратил 300 тыс")?.value == 300_000)
    }
}

@Suite("Real lexicon", .enabled(if: TestData.lexiconsAvailable))
struct RealLexiconTests {

    @Test("The gold lexicons load and merge")
    func loads() throws {
        let merged = try #require(TestData.real)
        #expect(merged.languages.count >= 3)
        #expect(merged.magnitudes.count > 10)
        #expect(merged.numbers.count > 20)
        #expect(merged.currencies.count > 20)
        #expect(merged.categoryKeywords.count > 100)
    }

    @Test("The most important vocabulary is present in every script we support")
    func coreVocabulary() throws {
        let merged = try #require(TestData.real)
        // Thousand, in the forms this app cannot function without.
        for surface in ["ming", "минг", "тыс", "k"] {
            #expect(merged.magnitudes[MergedLexicon.key(surface)] == 1000, "missing magnitude: \(surface)")
        }
        // So'm, however it is written.
        for surface in ["so'm", "сум", "сўм"] {
            #expect(merged.currencies[MergedLexicon.key(surface)] == .uzs, "missing currency: \(surface)")
        }
    }

    @Test("Merging the languages produces no conflicting definitions")
    func noConflicts() throws {
        let merged = try #require(TestData.real)
        // A surface meaning two different things across languages is a corpus bug: it makes the parser
        // silently language-dependent and poisons the fine-tune with contradictory labels.
        #expect(merged.conflicts.isEmpty, "lexicon conflicts:\n\(merged.conflicts.map(\.description).joined(separator: "\n"))")
    }

    @Test("Amounts parse across the whole gold corpus", .enabled(if: !TestData.corpus.isEmpty))
    func corpusAmounts() throws {
        let merged = try #require(TestData.real)
        let parser = AmountParser(lexicon: merged)
        let normalizer = TextNormalizer()

        var attempted = 0
        var matched = 0
        var failures: [String] = []

        for testCase in TestData.corpus {
            guard let expected = testCase.expected.amount else { continue }
            attempted += 1

            let normalized = normalizer.normalize(testCase.text)
            // Try each match form; Cyrillic input needs the transliterated one.
            let candidates = normalized.matchForms.flatMap { form -> [Decimal] in
                parser.amounts(in: TextNormalizer.tokenize(form)).map(\.value)
            }

            // The implied-thousands decision belongs to a later layer, so accept either reading here.
            if candidates.contains(expected) || candidates.contains(expected / 1000) {
                matched += 1
            } else if failures.count < 25 {
                failures.append("\(testCase.text) — expected \(expected), found \(candidates)")
            }
        }

        let rate = attempted == 0 ? 0 : Double(matched) / Double(attempted)
        // A floor, not a target: this is the raw amount-extraction layer with no context yet.
        #expect(
            rate > 0.85,
            """
            Amount extraction matched \(matched)/\(attempted) (\(Int(rate * 100))%).
            Sample failures:
            \(failures.joined(separator: "\n"))
            """
        )
    }
}
