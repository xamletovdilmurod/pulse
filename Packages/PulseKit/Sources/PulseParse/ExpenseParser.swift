import Foundation
import PulseCore

/// Turns a free-form utterance into a structured reading, with no model involved.
///
/// This is the fast path and the floor. It runs in microseconds, works offline, is fully deterministic,
/// and — importantly — makes the app genuinely useful before the fine-tuned model exists at all. The LLM
/// layer later handles what this cannot: unusual phrasings, multi-item utterances, and the long tail.
///
/// The design principle throughout is that **uncertainty is reported, not resolved**. Where the evidence
/// is thin the confidence drops and the UI asks; nothing is invented to make the output look complete.
public struct ExpenseParser: Sendable {

    public struct Configuration: Sendable {

        /// The ledger's currency, used when the user names none.
        public var baseCurrency: Currency

        /// Currencies whose everyday prices are habitually quoted in thousands with the magnitude left
        /// unsaid — "obedga 50" means fifty thousand so'm, not fifty so'm.
        ///
        /// This is a real and very common Uzbek speech pattern, but applying it is still an inference,
        /// so it costs confidence when used.
        public var impliedThousandsCurrencies: Set<String>

        /// Bare amounts below this are candidates for the implied-thousands reading. Above it, the
        /// number is taken literally — someone who says "45000" means exactly that.
        public var impliedThousandsCeiling: Decimal

        /// At or above this confidence, and with nothing missing, the parse is acted on directly.
        public var acceptThreshold: Double

        /// Below this, the utterance is treated as not a transaction at all.
        public var rejectThreshold: Double

        public init(
            baseCurrency: Currency = .uzs,
            impliedThousandsCurrencies: Set<String> = ["UZS"],
            impliedThousandsCeiling: Decimal = 1_000,
            acceptThreshold: Double = 0.75,
            rejectThreshold: Double = 0.35
        ) {
            self.baseCurrency = baseCurrency
            self.impliedThousandsCurrencies = impliedThousandsCurrencies
            self.impliedThousandsCeiling = impliedThousandsCeiling
            self.acceptThreshold = acceptThreshold
            self.rejectThreshold = rejectThreshold
        }
    }

    private let lexicon: MergedLexicon
    private let configuration: Configuration
    private let normalizer = TextNormalizer()
    private let amountParser: AmountParser

    private let categories: PhraseIndex<TransactionCategory>
    private let dates: PhraseIndex<RelativeDate>
    private let currencies: PhraseIndex<Currency>
    private let merchants: PhraseIndex<MergedLexicon.MerchantMatch>
    private let expenseMarkers: PhraseIndex<Bool>
    private let incomeMarkers: PhraseIndex<Bool>
    private let nonDates: PhraseIndex<Bool>
    private let nonMerchants: PhraseIndex<Bool>
    private let uncompleted: PhraseIndex<Bool>
    private let daysAgo: PhraseIndex<Bool>

    public init(lexicon: MergedLexicon, configuration: Configuration = Configuration()) {
        self.lexicon = lexicon
        self.configuration = configuration
        self.amountParser = AmountParser(lexicon: lexicon)
        self.categories = PhraseIndex(lexicon.categoryKeywords)
        self.dates = PhraseIndex(lexicon.dates)

        // Fold in the single-character currency symbols, which no lexicon lists as words. Where two
        // currencies share a glyph (¥ is both yen and yuan) the first registered wins; for this app's
        // users that ambiguity is vanishingly rare next to the value of recognising "$" at all.
        var currencyTable = lexicon.currencies
        for currency in Currency.known where currency.symbol.count == 1 {
            let key = MergedLexicon.key(currency.symbol)
            if currencyTable[key] == nil { currencyTable[key] = currency }
        }
        self.currencies = PhraseIndex(currencyTable)
        self.merchants = PhraseIndex(lexicon.merchants)
        self.expenseMarkers = PhraseIndex(lexicon.expenseMarkers)
        self.incomeMarkers = PhraseIndex(lexicon.incomeMarkers)
        self.nonDates = PhraseIndex(lexicon.nonDateExpressions)
        self.nonMerchants = PhraseIndex(lexicon.nonMerchants)
        self.uncompleted = PhraseIndex(lexicon.uncompletedMarkers)
        self.daysAgo = PhraseIndex(lexicon.daysAgoPhrases)
    }

    // MARK: - Entry points

    /// Parse and classify into an actionable outcome.
    public func parse(_ text: String) -> ParseOutcome {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return .empty }

        let reading = analyze(text)

        if reading.parsed.confidence < configuration.rejectThreshold {
            return .notATransaction(reason: reading.rejectionReason)
        }
        let missing = reading.parsed.missingRequiredFields
        if missing.isEmpty && reading.parsed.confidence >= configuration.acceptThreshold {
            return .transaction(reading.parsed)
        }
        return .needsConfirmation(reading.parsed, missing: missing)
    }

    /// The full reading, including the evidence behind it. Always returns something.
    ///
    /// Exposed separately from ``parse(_:)`` because the UI wants to explain itself — highlighting which
    /// words produced the amount and the category is what makes a mis-parse correctable instead of
    /// mysterious.
    public func analyze(_ text: String) -> Reading {
        let normalized = normalizer.normalize(text)
        let tokens = bestTokens(for: normalized)

        let stems = UzbekMorphology.stems(of:)
        let amountMatch = amountParser.principalAmount(in: tokens)
        let anchor = amountMatch?.tokenRange

        // Where an utterance names several things — "spent 90k at havas and 20k on taxi" — the words
        // nearest the amount are the ones describing it. Taking the first or last match instead would
        // attach the wrong category to the wrong price about half the time.
        let currencyHit = Self.nearest(currencies.matches(tokens, stems: stems), to: anchor)
        let dateHit = dateHit(in: tokens)
        let merchantHit = Self.nearest(merchants.matches(tokens, stems: stems), to: anchor)
        let categoryHit = Self.nearest(categories.matches(tokens, stems: stems), to: anchor)

        let sawIncomeMarker = incomeMarkers.containsMatch(tokens, stems: UzbekMorphology.stems(of:))
        let sawExpenseMarker = expenseMarkers.containsMatch(tokens, stems: UzbekMorphology.stems(of:))

        // Category can come from an explicit keyword or from a known merchant. When both are present
        // — "spent 90k at havas and 20k on taxi" has a merchant and a category word — the one nearer
        // the amount describes it.
        let categoryFromMerchant = merchantHit.flatMap { hit in
            hit.value.category.map { (value: $0, range: hit.range) }
        }
        let bestCategoryHit = Self.nearest(
            [categoryHit, categoryFromMerchant].compactMap(\.self), to: anchor
        )

        let recognizedCategory = bestCategoryHit?.value
        let kind = resolveKind(
            category: recognizedCategory,
            sawIncomeMarker: sawIncomeMarker,
            sawExpenseMarker: sawExpenseMarker
        )

        // With an amount but no recognisable category, "Other" is the honest answer — it is a real
        // bucket, not a guess, and it lets the entry be saved and recategorised in one tap rather than
        // blocking on a question the user cannot usefully answer either.
        let category = recognizedCategory ?? (amountMatch != nil ? TransactionCategory.fallback(for: kind) : nil)

        let currency = currencyHit?.value
        let resolvedCurrency = currency ?? configuration.baseCurrency

        var amount = amountMatch?.value
        var appliedImpliedThousands = false
        if let raw = amount, let match = amountMatch, !match.hadExplicitMagnitude {
            if shouldApplyImpliedThousands(
                to: raw,
                currency: resolvedCurrency,
                explicit: currency != nil,
                languages: lexicon.languageProfile(for: tokens)
            ) {
                amount = raw * 1_000
                appliedImpliedThousands = true
            }
        }

        let evidence = Evidence(
            amount: amountMatch,
            currency: currencyHit.map { (value: $0.value, range: $0.range) },
            category: bestCategoryHit.map { (value: $0.value, range: $0.range) },
            merchant: merchantHit.map { (value: $0.value, range: $0.range) },
            date: dateHit,
            sawIncomeMarker: sawIncomeMarker,
            sawExpenseMarker: sawExpenseMarker,
            appliedImpliedThousands: appliedImpliedThousands,
            futureIntent: mentionsFuture(tokens),
            isQuestion: looksLikeQuestion(normalized),
            amountCount: amountParser.amounts(in: tokens).count
        )

        let parsed = ParsedTransaction(
            kind: kind,
            amount: amount,
            currency: currency,
            category: category,
            merchant: merchantHit?.value.canonical,
            note: nil,
            date: dateHit?.value,
            confidence: confidence(for: evidence, hasCategory: recognizedCategory != nil)
        )

        return Reading(parsed: parsed, evidence: evidence, tokens: tokens, normalized: normalized)
    }

    // MARK: - Reading

    /// A parse plus the evidence that produced it.
    public struct Reading: Sendable {
        public let parsed: ParsedTransaction
        public let evidence: Evidence
        public let tokens: [String]
        public let normalized: TextNormalizer.Normalized

        var rejectionReason: ParseOutcome.NonTransactionReason {
            if evidence.isQuestion { return .question }
            if evidence.futureIntent { return .command }
            if parsed.amount == nil && parsed.category == nil { return .unintelligible }
            return .command
        }
    }

    /// What the parser actually found, and where.
    public struct Evidence: Sendable {
        public let amount: AmountParser.Match?
        public let currency: (value: Currency, range: Range<Int>)?
        public let category: (value: TransactionCategory, range: Range<Int>)?
        public let merchant: (value: MergedLexicon.MerchantMatch, range: Range<Int>)?
        public let date: (value: RelativeDate, range: Range<Int>)?
        public let sawIncomeMarker: Bool
        public let sawExpenseMarker: Bool
        public let appliedImpliedThousands: Bool
        public let futureIntent: Bool
        public let isQuestion: Bool
        /// How many distinct amounts the utterance contained. Several means the deterministic layer
        /// cannot know which one — or whether it is really several transactions.
        public let amountCount: Int
    }

    // MARK: - Token selection

    /// Pick the token stream that the lexicon recognises best.
    ///
    /// Cyrillic Uzbek needs its transliterated form to match Latin lexicon entries, while Russian needs
    /// its original Cyrillic. Rather than deciding the language up front — which is exactly the guess
    /// this parser avoids — every candidate form is scored by how many lexicon entries it hits, and the
    /// winner is used.
    private func bestTokens(for normalized: TextNormalizer.Normalized) -> [String] {
        var best: [String] = []
        var bestScore = -1

        for form in normalized.matchForms {
            let tokens = TextNormalizer.tokenize(form)
            let score = recognitionScore(tokens)
            if score > bestScore {
                bestScore = score
                best = tokens
            }
        }
        return best
    }

    private func recognitionScore(_ tokens: [String]) -> Int {
        var score = 0
        let stems = UzbekMorphology.stems(of:)
        score += categories.matches(tokens, stems: stems).count * 2
        score += currencies.matches(tokens, stems: stems).count * 2
        score += dates.matches(tokens, stems: stems).count
        score += merchants.matches(tokens, stems: stems).count * 2
        score += amountParser.amounts(in: tokens).count
        for token in tokens where lexicon.magnitudes[token] != nil || lexicon.numbers[token] != nil {
            score += 1
        }
        return score
    }

    // MARK: - Field resolution

    /// A date, unless the phrase was explicitly recorded as a non-date.
    private func dateHit(in tokens: [String]) -> (value: RelativeDate, range: Range<Int>)? {
        let stems = UzbekMorphology.stems(of:)

        // Templated "<N> days ago" phrases, which no literal lookup can match.
        if !daysAgo.isEmpty {
            for index in tokens.indices.dropFirst() {
                guard let count = AmountParser.decimalFromDigits(tokens[index - 1]) else { continue }
                guard let hit = daysAgo.match(tokens, at: index, stems: stems) else { continue }
                let days = (count as NSDecimalNumber).intValue
                if days > 0, days < 3650 {
                    return (.daysAgo(days), (index - 1)..<(index + hit.length))
                }
            }
        }
        // Non-date phrases are checked first and consume their tokens: `har oy` ("every month") must not
        // fall through and match a bare `oy`.
        let blocked = Set(nonDates.matches(tokens, stems: stems).flatMap { Array($0.range) })
        for hit in dates.matches(tokens, stems: stems) {
            if hit.range.contains(where: { blocked.contains($0) }) { continue }
            return (hit.value, hit.range)
        }
        return nil
    }

    private func resolveKind(
        category: TransactionCategory?,
        sawIncomeMarker: Bool,
        sawExpenseMarker: Bool
    ) -> TransactionKind {
        // An explicit verb beats everything: "zarplata keldi" is income however it is categorised.
        if sawIncomeMarker && !sawExpenseMarker { return .income }
        if sawExpenseMarker && !sawIncomeMarker { return .expense }
        if let category { return category.kind }
        // Spending is overwhelmingly the common case, and this app exists to track it.
        return .expense
    }

    private func shouldApplyImpliedThousands(
        to amount: Decimal,
        currency: Currency,
        explicit: Bool,
        languages: [String: Int]
    ) -> Bool {
        guard configuration.impliedThousandsCurrencies.contains(currency.code) else { return false }
        guard amount > 0, amount < configuration.impliedThousandsCeiling else { return false }

        // A stated currency means the speaker was being precise; take them literally.
        guard !explicit else { return false }

        // A decimal is already precise. Nobody means fifty thousand five hundred by "50.5".
        guard Self.isInteger(amount) else { return false }

        // The convention is Uzbek and Russian, not English. "obedga 50" is fifty thousand so'm;
        // "spent 15 on coffee" is fifteen. Only skip when the evidence is English and *only* English.
        let english = languages["en"] ?? 0
        let local = (languages["uz"] ?? 0) + (languages["ru"] ?? 0)
        guard !(english > 0 && local == 0) else { return false }

        return true
    }

    private static func isInteger(_ value: Decimal) -> Bool {
        var input = value
        var rounded = Decimal()
        NSDecimalRound(&rounded, &input, 0, .down)
        return rounded == value
    }

    /// The match closest to `anchor`, or the first if there is no anchor.
    private static func nearest<Value>(
        _ matches: [(value: Value, range: Range<Int>)],
        to anchor: Range<Int>?
    ) -> (value: Value, range: Range<Int>)? {
        guard let anchor else { return matches.first }
        return matches.min { lhs, rhs in
            distance(from: lhs.range, to: anchor) < distance(from: rhs.range, to: anchor)
        }
    }

    private static func distance(from range: Range<Int>, to anchor: Range<Int>) -> Int {
        if range.upperBound <= anchor.lowerBound { return anchor.lowerBound - range.upperBound }
        if anchor.upperBound <= range.lowerBound { return range.lowerBound - anchor.upperBound }
        return 0
    }

    // MARK: - Intent detection

    /// Phrases marking something other than a completed, one-off transaction.
    ///
    /// Two things get caught here, and both would otherwise pollute the ledger:
    ///
    /// *Intentions.* "ertaga 200 ming to'lashim kerak" — I must pay 200 000 tomorrow — is a plan.
    /// "will spend 50 dollars on gift" has not happened yet.
    ///
    /// *Habitual statements.* "i earn 12 million a month" describes a rate, not an event; recording it
    /// would add income that never arrived on a day it never arrived.
    private func mentionsFuture(_ tokens: [String]) -> Bool {
        if uncompleted.containsMatch(tokens, stems: UzbekMorphology.stems(of:)) { return true }
        if !Set(tokens).isDisjoint(with: Self.futureOrHabitualWords) { return true }
        return Self.recurrencePhrases.containsMatch(tokens)
    }

    /// Modal and habitual markers. A closed class in each language, so held in code beside the
    /// question words rather than in the lexicon.
    private static let futureOrHabitualWords: Set<String> = [
        // English
        "will", "gonna", "shall", "must", "plan", "planning", "monthly", "weekly",
        "usually", "always", "every", "tomorrow", "next",
        // Russian
        "буду", "собираюсь", "надо", "нужно", "должен", "планирую", "обычно",
        "каждый", "каждую", "ежемесячно", "завтра",
        // Uzbek
        "kerak", "керак", "moqchiman", "moqchi", "odatda", "doim", "har", "ertaga", "эртага",
    ]

    /// Multi-word rate expressions: "12 million **a month**".
    private static let recurrencePhrases = PhraseIndex<Bool>(
        Set([
            "a month", "per month", "a week", "per week", "a day", "per day", "a year", "per year",
            "в месяц", "в неделю", "в день", "в год",
            "oyiga", "haftasiga", "kuniga", "yiliga",
        ])
    )

    /// Questions about spending must never become spending.
    private func looksLikeQuestion(_ normalized: TextNormalizer.Normalized) -> Bool {
        if normalized.original.contains("?") { return true }
        let tokens = Set(normalized.tokens + TextNormalizer.tokenize(normalized.transliterated))
        return !tokens.isDisjoint(with: Self.questionWords)
    }

    /// Interrogatives across the three languages.
    ///
    /// Held in code rather than the lexicon because they are a closed class and identical for every
    /// user; the lexicon is for vocabulary that grows.
    private static let questionWords: Set<String> = [
        // Uzbek
        "qancha", "qanchaga", "qanday", "nima", "nimaga", "necha", "nechta", "qayerda", "qachon",
        "qancha?", "qanchalik",
        // Russian
        "сколько", "скольким", "какой", "какая", "что", "где", "когда", "почему", "зачем",
        // English
        "how", "what", "where", "when", "why", "which",
    ]

    // MARK: - Confidence

    /// Score the reading from the evidence behind it.
    ///
    /// The weights are a starting point tuned against the gold corpus, not a theory. What matters is the
    /// ordering they produce: an utterance with an amount, a category and a spending verb should clear
    /// the accept threshold, while "korzinkada ishlayman" ("I work at Korzinka") — a merchant, no money,
    /// no verb of spending — should land far below the reject threshold.
    private func confidence(for evidence: Evidence, hasCategory: Bool) -> Double {
        // A question is not a transaction no matter what else is in it.
        if evidence.isQuestion { return 0.05 }

        var score = 0.1

        if let amount = evidence.amount {
            score += amount.hadExplicitMagnitude ? 0.4 : 0.3
            if evidence.appliedImpliedThousands {
                // The value was inferred rather than heard.
                score -= 0.1
            }
            if amount.wasBareMagnitude {
                // "spent k on coffee" — the quantity was lost. Better to ask than to record 1 000.
                score -= 0.45
            }
            if evidence.amountCount >= 3 {
                // "spent 20k 30k 40k today on different things" is several transactions, or none.
                score -= 0.3
            }
        } else {
            // No amount at all: still possibly a real entry the user must complete, but never certain.
            score -= 0.15
        }

        if hasCategory { score += 0.22 }
        if evidence.currency != nil { score += 0.12 }
        if evidence.date != nil { score += 0.08 }
        if evidence.merchant != nil { score += 0.08 }
        if evidence.sawIncomeMarker || evidence.sawExpenseMarker { score += 0.12 }

        // A stated intention is not a record of spending.
        if evidence.futureIntent { score -= 0.55 }

        return min(max(score, 0), 1)
    }
}
