import Foundation
import PulseCore

/// The vocabulary of money-talk for one language, as authored in `ml/data/lexicon/<lang>.json`.
///
/// This is data, not code, on purpose: adding a slang word for "thousand" should never require a
/// recompile of the parser, and the same file feeds the LLM's training corpus so the two layers cannot
/// drift apart in what they recognise.
public struct Lexicon: Sendable, Codable {

    public let language: String
    public let scripts: [String]
    public let magnitudeWords: [MagnitudeWord]
    public let numberWords: [NumberWord]
    public let currencyWords: [CurrencyWord]
    public let expenseMarkers: [Marker]
    public let incomeMarkers: [Marker]
    public let categoryKeywords: [CategoryKeywords]
    public let dateExpressions: [DateExpression]
    public let merchants: [MerchantEntry]
    public let noiseWords: [String]

    /// Income categories are listed separately because the same word means different things on the two
    /// sides of the ledger — "premiya" is a bonus you receive, not a category of spending.
    public let incomeCategoryKeywords: [CategoryKeywords]

    /// Words that make an utterance a question rather than a record.
    public let queryMarkers: [LanguageMarker]

    /// Words marking an intention: something planned, not something done.
    public let intentMarkers: [LanguageMarker]

    /// Negation. Uzbek negates with a verb suffix, so some of these are suffix patterns rather than
    /// whole words — see ``MergedLexicon/negationSuffixes``.
    public let negationMarkers: [LanguageMarker]

    /// Hedges: "almost bought", "was going to". Nothing moved.
    public let hedgeWords: MarkerGroup?

    /// Moving your own money between your own accounts is not spending.
    public let transferMarkers: MarkerGroup?

    private enum CodingKeys: String, CodingKey {
        case language, scripts
        case magnitudeWords = "magnitude_words"
        case numberWords = "number_words"
        case currencyWords = "currency_words"
        case expenseMarkers = "expense_markers"
        case incomeMarkers = "income_markers"
        case categoryKeywords = "category_keywords"
        case incomeCategoryKeywords = "income_category_keywords"
        case dateExpressions = "date_expressions"
        case merchants
        case noiseWords = "noise_words"
        case queryMarkers = "query_markers"
        case intentMarkers = "intent_markers"
        case negationMarkers = "negation_markers"
        case hedgeWords = "hedge_words"
        case transferMarkers = "transfer_markers"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        language = try container.decode(String.self, forKey: .language)
        scripts = try container.decodeIfPresent([String].self, forKey: .scripts) ?? []
        magnitudeWords = try container.decodeIfPresent([MagnitudeWord].self, forKey: .magnitudeWords) ?? []
        numberWords = try container.decodeIfPresent([NumberWord].self, forKey: .numberWords) ?? []
        currencyWords = try container.decodeIfPresent([CurrencyWord].self, forKey: .currencyWords) ?? []
        expenseMarkers = try container.decodeIfPresent([Marker].self, forKey: .expenseMarkers) ?? []
        incomeMarkers = try container.decodeIfPresent([Marker].self, forKey: .incomeMarkers) ?? []
        categoryKeywords = try container.decodeIfPresent([CategoryKeywords].self, forKey: .categoryKeywords) ?? []
        dateExpressions = try container.decodeIfPresent([DateExpression].self, forKey: .dateExpressions) ?? []
        merchants = try container.decodeIfPresent([MerchantEntry].self, forKey: .merchants) ?? []
        noiseWords = try container.decodeIfPresent([String].self, forKey: .noiseWords) ?? []
        incomeCategoryKeywords =
            try container.decodeIfPresent([CategoryKeywords].self, forKey: .incomeCategoryKeywords) ?? []
        queryMarkers = try container.decodeIfPresent([LanguageMarker].self, forKey: .queryMarkers) ?? []
        intentMarkers = try container.decodeIfPresent([LanguageMarker].self, forKey: .intentMarkers) ?? []
        negationMarkers =
            try container.decodeIfPresent([LanguageMarker].self, forKey: .negationMarkers) ?? []
        hedgeWords = try container.decodeIfPresent(MarkerGroup.self, forKey: .hedgeWords)
        transferMarkers = try container.decodeIfPresent(MarkerGroup.self, forKey: .transferMarkers)
    }

    // MARK: Entry types

    public struct MagnitudeWord: Sendable, Codable {
        public let surface: String
        /// What to multiply by: 1 000 for "ming", 1 000 000 for "million".
        ///
        /// Fractional values are legitimate and common — `yarim` and `ярим` (Uzbek "half"), `полтора`
        /// (Russian "one and a half"), `and half`. These are coefficients rather than scales, and the
        /// parser tells them apart by size; see ``AmountParser``.
        public let multiplier: Double
        public let notes: String?
    }

    public struct NumberWord: Sendable, Codable {
        public let surface: String
        /// Also fractional for words like `пол` (half) and `полтора`.
        public let value: Double
    }

    public struct CurrencyWord: Sendable, Codable {
        public let surface: String
        /// ISO code, or **null** when the word genuinely names more than one currency and no default is
        /// safe: bare `som`/`сом` is both the apostrophe-less Uzbek so'm and the Kyrgyz som. Such a word
        /// still counts as the speaker having named a currency — it just does not say which.
        public let iso: String?
        public let notes: String?
    }

    public struct Marker: Sendable, Codable {
        public let surface: String
        public let notes: String?
    }

    /// A marker tagged with the language it belongs to.
    public struct LanguageMarker: Sendable, Codable {
        public let surface: String
        public let lang: String?
        public let meaning: String?
        public let notes: String?
    }

    /// A documented group of markers: `{ "notes": "...", "entries": [...] }`.
    public struct MarkerGroup: Sendable, Codable {
        public let notes: String?
        public let entries: [LanguageMarker]

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            notes = try container.decodeIfPresent(String.self, forKey: .notes)
            entries = try container.decodeIfPresent([LanguageMarker].self, forKey: .entries) ?? []
        }

        private enum CodingKeys: String, CodingKey { case notes, entries }
    }

    public struct CategoryKeywords: Sendable, Codable {
        public let category: String
        public let keywords: [String]
    }

    public struct DateExpression: Sendable, Codable {
        public let surface: String
        /// A ``RelativeDate`` wire value such as `yesterday` or `last_friday`.
        ///
        /// **Null is meaningful.** It marks a phrase that looks date-like but must not become a date:
        /// `tomorrow` and `next week` are the future (an intention, not a transaction), `ertalab`
        /// ("in the morning") is a time of day, `har oy` ("every month") is a recurrence. These
        /// negative entries are what stop the parser from confidently dating an entry wrong.
        public let meaning: String?
    }

    public struct MerchantEntry: Sendable, Codable {
        public let surface: String
        /// **Null is meaningful.** Click, Payme, Uzcard and Humo are payment rails and card schemes,
        /// not places you buy anything. Recording them as non-merchants keeps "click orqali to'ladim"
        /// ("paid via Click") from inventing a shop called Click.
        public let canonical: String?
        public let category: String?
    }
}

// MARK: - Merged lookup

/// Every language's vocabulary flattened into one set of lookup tables.
///
/// Merging rather than selecting is deliberate. Deciding the language of "сум" or "obed 45" before
/// looking anything up would mean committing to a guess at the least informed moment; matching against
/// everything at once and scoring afterwards is both simpler and more accurate. Tashkent speech mixes
/// languages inside single phrases anyway, so there is often no one right answer to select.
public struct MergedLexicon: Sendable {

    public private(set) var magnitudes: [String: Decimal] = [:]
    public private(set) var numbers: [String: Decimal] = [:]
    public private(set) var currencies: [String: Currency] = [:]
    public private(set) var expenseMarkers: Set<String> = []
    public private(set) var incomeMarkers: Set<String> = []
    /// Keyword to category. First writer wins, with collisions recorded in ``conflicts``.
    public private(set) var categoryKeywords: [String: TransactionCategory] = [:]
    public private(set) var dates: [String: RelativeDate] = [:]
    /// Phrases that look like dates but explicitly are not one — futures, times of day, recurrences.
    public private(set) var nonDateExpressions: Set<String> = []
    public private(set) var merchants: [String: MerchantMatch] = [:]
    /// Payment rails and card schemes: recognised, but never treated as a merchant.
    public private(set) var nonMerchants: Set<String> = []

    /// Phrases marking something that has not happened — a future plan or a recurring rate.
    public private(set) var uncompletedMarkers: Set<String> = []

    /// The fixed part of "N days ago" templates: `kun oldin`, `кун олдин`, `дней назад`.
    public private(set) var daysAgoPhrases: Set<String> = []

    /// Interrogatives. A question about spending must never become spending.
    public private(set) var queryMarkers: Set<String> = []

    /// Currency words that name more than one currency. Recognised as "a currency was stated", but
    /// resolving to none.
    public private(set) var ambiguousCurrencyWords: Set<String> = []

    /// Whole-word negations, hedges ("almost bought"), and self-transfers — all cases where the words
    /// describe money that did not actually move.
    public private(set) var nothingMovedMarkers: Set<String> = []

    /// Uzbek negates with a verb suffix rather than a word, so these are matched as token endings:
    /// `sarflamadim`, `olmadim`, `to'lamadim`.
    public private(set) var negationSuffixes: Set<String> = []
    public private(set) var noiseWords: Set<String> = []

    /// The languages that contributed, in merge order.
    public private(set) var languages: [String] = []

    /// Which single languages each surface came from.
    ///
    /// Used to tell what language an utterance is actually in, which decides genuinely
    /// language-specific behaviour — above all whether an unspoken "thousand" should be inferred, since
    /// "obedga 50" means fifty thousand so'm but "spent 15 on coffee" means fifteen.
    ///
    /// The code-switched lexicon contributes no provenance: every entry in it is ambiguous by
    /// construction, so counting it as evidence for any one language would defeat the purpose.
    public private(set) var surfaceLanguages: [String: Set<String>] = [:]

    /// Languages we track provenance for. `uz-ru-en-mixed` is deliberately absent.
    private static let provenanceLanguages: Set<String> = ["uz", "ru", "en"]

    /// Disagreements found while merging — the same surface mapping to two different meanings.
    ///
    /// Surfaced rather than silently resolved: a genuine conflict is usually a corpus bug, and a parser
    /// that quietly picks one is a parser whose mistakes are invisible. Tests assert this stays empty.
    public private(set) var conflicts: [Conflict] = []

    public struct MerchantMatch: Sendable, Hashable {
        public let canonical: String
        public let category: TransactionCategory?
    }

    public struct Conflict: Sendable, Hashable, CustomStringConvertible {
        public let surface: String
        public let table: String
        public let existing: String
        public let incoming: String

        public var description: String {
            "\(table)[\"\(surface)\"]: \(existing) vs \(incoming)"
        }
    }

    public init(lexicons: [Lexicon]) {
        for lexicon in lexicons {
            merge(lexicon)
        }
    }

    private mutating func merge(_ lexicon: Lexicon) {
        languages.append(lexicon.language)
        let provenance: String? =
            Self.provenanceLanguages.contains(lexicon.language) ? lexicon.language : nil

        // Record which language every surface in this file came from, before the tables dedupe them.
        if let provenance {
            let surfaces =
                lexicon.magnitudeWords.map(\.surface) + lexicon.numberWords.map(\.surface)
                + lexicon.currencyWords.map(\.surface) + lexicon.expenseMarkers.map(\.surface)
                + lexicon.incomeMarkers.map(\.surface) + lexicon.dateExpressions.map(\.surface)
                + lexicon.merchants.map(\.surface) + lexicon.categoryKeywords.flatMap(\.keywords)
                + lexicon.noiseWords
            for surface in surfaces {
                surfaceLanguages[Self.key(surface), default: []].insert(provenance)
            }
        }

        for entry in lexicon.magnitudeWords {
            Self.insert(
                key: entry.surface, value: Self.decimal(entry.multiplier),
                into: &magnitudes, conflicts: &conflicts, table: "magnitudes"
            )
        }
        for entry in lexicon.numberWords {
            Self.insert(
                key: entry.surface, value: Self.decimal(entry.value),
                into: &numbers, conflicts: &conflicts, table: "numbers"
            )
        }
        for entry in lexicon.currencyWords {
            // A word that names a currency ambiguously still tells us the speaker was being explicit,
            // which is enough to stop the implied-thousands rule from firing on their number.
            guard let iso = entry.iso else {
                ambiguousCurrencyWords.insert(Self.key(entry.surface))
                continue
            }
            // A currency Pulse cannot represent is dropped rather than faked — see Currency.known(code:).
            guard let currency = Currency.known(code: iso) else { continue }
            Self.insert(
                key: entry.surface, value: currency,
                into: &currencies, conflicts: &conflicts, table: "currencies"
            )
        }
        for entry in lexicon.expenseMarkers {
            expenseMarkers.insert(Self.key(entry.surface))
        }
        for entry in lexicon.incomeMarkers {
            incomeMarkers.insert(Self.key(entry.surface))
        }
        // Income category words are kept in their own section because the same surface can mean
        // different things per side of the ledger.
        for group in lexicon.categoryKeywords + lexicon.incomeCategoryKeywords {
            guard let category = TransactionCategory(rawValue: group.category) else { continue }
            for keyword in group.keywords {
                Self.insert(
                    key: keyword, value: category,
                    into: &categoryKeywords, conflicts: &conflicts, table: "categoryKeywords"
                )
            }
        }
        for entry in lexicon.dateExpressions {
            let key = Self.key(entry.surface)

            // "<N> kun oldin" is a template, not a phrase. Register the fixed part so the parser can
            // pair it with whatever number precedes it.
            if let tail = Self.daysAgoTail(of: key) {
                daysAgoPhrases.insert(tail)
                continue
            }

            // A null meaning is a deliberate negative entry, not missing data.
            guard let meaning = entry.meaning else {
                nonDateExpressions.insert(key)
                continue
            }

            // The lexicons disagree on how to say "this is not a date": some use null, the Uzbek one
            // uses explicit sentinels. Both are honoured, and FUTURE/RECURRING additionally mark the
            // utterance as something that has not actually happened.
            switch meaning.uppercased() {
            case "FUTURE", "RECURRING":
                nonDateExpressions.insert(key)
                uncompletedMarkers.insert(key)
                continue
            case "UNSUPPORTED", "AMBIGUOUS", "VAGUE":
                // A real past event, just too vaguely dated to place. No date, but no penalty either.
                nonDateExpressions.insert(key)
                continue
            default:
                break
            }

            guard let date = Self.relativeDate(fromLexiconMeaning: meaning) else {
                // Unrecognised: refuse to guess, but still stop it being read as a date.
                nonDateExpressions.insert(key)
                continue
            }
            Self.insert(
                key: entry.surface, value: date,
                into: &dates, conflicts: &conflicts, table: "dates"
            )
        }
        for entry in lexicon.merchants {
            guard let canonical = entry.canonical else {
                nonMerchants.insert(Self.key(entry.surface))
                continue
            }
            let match = MerchantMatch(
                canonical: canonical,
                category: entry.category.flatMap(TransactionCategory.init(rawValue:))
            )
            Self.insert(
                key: entry.surface, value: match,
                into: &merchants, conflicts: &conflicts, table: "merchants"
            )
        }
        for word in lexicon.noiseWords {
            noiseWords.insert(Self.key(word))
        }

        for marker in lexicon.queryMarkers {
            queryMarkers.insert(Self.key(marker.surface))
        }
        for marker in lexicon.intentMarkers {
            uncompletedMarkers.insert(Self.key(marker.surface))
        }
        for marker in lexicon.negationMarkers {
            // Entries like "-madim / -medim" list several suffix variants in one surface.
            for variant in marker.surface.split(separator: "/") {
                let trimmed = variant.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("-") {
                    let suffix = Self.key(String(trimmed.dropFirst()))
                    if suffix.count >= 2 { negationSuffixes.insert(suffix) }
                } else if !trimmed.isEmpty {
                    nothingMovedMarkers.insert(Self.key(trimmed))
                }
            }
        }
        for group in [lexicon.hedgeWords, lexicon.transferMarkers] {
            for entry in group?.entries ?? [] {
                nothingMovedMarkers.insert(Self.key(entry.surface))
            }
        }
    }

    /// Static so it can take two disjoint stored properties as `inout` without an exclusivity conflict
    /// on `self`.
    private static func insert<Value: Equatable>(
        key surface: String,
        value: Value,
        into table: inout [String: Value],
        conflicts: inout [Conflict],
        table name: String
    ) {
        let key = Self.key(surface)
        guard !key.isEmpty else { return }
        if let existing = table[key] {
            if existing != value {
                conflicts.append(
                    Conflict(
                        surface: key, table: name,
                        existing: String(describing: existing), incoming: String(describing: value)
                    )
                )
            }
            return  // First writer wins; the conflict is reported rather than silently applied.
        }
        table[key] = value
    }

    /// The fixed part of an `<N> …` template surface, or `nil` if it is not one.
    private static func daysAgoTail(of key: String) -> String? {
        for placeholder in ["<n> ", "<n>"] where key.hasPrefix(placeholder) {
            let tail = String(key.dropFirst(placeholder.count)).trimmingCharacters(in: .whitespaces)
            return tail.isEmpty ? nil : tail
        }
        return nil
    }

    /// Parse a lexicon-authored date meaning, allowing one leniency the model's wire format does not.
    ///
    /// Lexicon authors wrote bare weekday names (`friday` for "в пятницу"). In an expense log a bare
    /// weekday always refers to the past — you record what you already spent — so it resolves to the
    /// most recent one. The strict wire format stays strict, because there the model must be explicit.
    private static func relativeDate(fromLexiconMeaning meaning: String) -> RelativeDate? {
        if let parsed = RelativeDate(wireValue: meaning) { return parsed }
        if let weekday = RelativeDate.Weekday.named(meaning.trimmingCharacters(in: .whitespaces)) {
            return .lastWeekday(weekday)
        }
        return nil
    }

    /// Count how much evidence each language has in a token stream.
    ///
    /// Only surfaces belonging to exactly one language count. A word the languages share — and there
    /// are many, since Uzbek has borrowed heavily from Russian — is not evidence of anything.
    public func languageProfile(for tokens: [String]) -> [String: Int] {
        var counts: [String: Int] = [:]
        for token in tokens {
            guard let owners = surfaceLanguages[token], owners.count == 1, let owner = owners.first
            else { continue }
            counts[owner, default: 0] += 1
        }
        return counts
    }

    /// Convert a JSON number to `Decimal` via its text form, so 0.5 and 1.5 stay exact rather than
    /// picking up binary floating-point noise on the way in.
    private static func decimal(_ value: Double) -> Decimal {
        Decimal(string: String(value)) ?? Decimal(value)
    }

    /// Normalise a surface the same way input is normalised, so the two always meet.
    static func key(_ surface: String) -> String {
        TextNormalizer.collapseAbbreviationPeriods(
            TextNormalizer.collapseWhitespace(
                TextNormalizer.unifyApostrophes(surface).lowercased()
            )
        )
    }
}

// MARK: - Loading

extension Lexicon {

    /// Decode a lexicon from JSON data.
    public static func load(from data: Data) throws -> Lexicon {
        try JSONDecoder().decode(Lexicon.self, from: data)
    }

    /// Load every `<lang>.json` in a directory and merge them.
    public static func merged(fromDirectory directory: URL) throws -> MergedLexicon {
        let files = try FileManager.default
            .contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
            // `merged.json` is a generated convenience copy; loading it alongside the per-language
            // files would report every entry as a conflict with itself.
            .filter { $0.lastPathComponent != "merged.json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }

        let lexicons = try files.map { try load(from: Data(contentsOf: $0)) }
        return MergedLexicon(lexicons: lexicons)
    }
}
