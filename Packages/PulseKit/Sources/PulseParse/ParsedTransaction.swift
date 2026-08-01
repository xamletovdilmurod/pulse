import Foundation
import PulseCore

/// The structured reading of an utterance, before it becomes a real ``Transaction``.
///
/// Every field except `kind` is optional, because a real utterance is often incomplete — "obed 45"
/// names no currency and no date, and pretending otherwise is how a parser ends up confidently wrong.
/// The app fills gaps from defaults (base currency, today) and asks the user only about the rest.
///
/// This type is the shared contract between the deterministic parser and the fine-tuned model: both
/// produce it, and the model's JSON output decodes straight into it. The `CodingKeys` below are that
/// wire format and must stay in step with the training corpus.
public struct ParsedTransaction: Hashable, Sendable, Codable {

    public var kind: TransactionKind

    /// Amount in **major** units (45 000 for "45 ming so'm"), or `nil` when none was stated.
    public var amount: Decimal?

    /// Only set when the user actually named a currency. `nil` means "use the ledger default" — never
    /// a guess.
    public var currency: Currency?

    public var category: TransactionCategory?

    public var merchant: String?

    public var note: String?

    public var date: RelativeDate?

    /// How sure we are, 0...1. Drives whether the app saves silently, pre-fills a confirmation, or asks.
    public var confidence: Double

    public init(
        kind: TransactionKind = .expense,
        amount: Decimal? = nil,
        currency: Currency? = nil,
        category: TransactionCategory? = nil,
        merchant: String? = nil,
        note: String? = nil,
        date: RelativeDate? = nil,
        confidence: Double = 0
    ) {
        self.kind = kind
        self.amount = amount
        self.currency = currency
        self.category = category
        self.merchant = merchant
        self.note = note
        self.date = date
        self.confidence = confidence.clamped(to: 0...1)
    }

    /// Fields the app cannot proceed without and that no default can supply.
    ///
    /// Currency and date are deliberately absent: both have safe, explainable defaults. An amount has
    /// none — inventing one would be inventing a transaction.
    public var missingRequiredFields: [Field] {
        var missing: [Field] = []
        if amount == nil { missing.append(.amount) }
        if category == nil { missing.append(.category) }
        return missing
    }

    public var isComplete: Bool { missingRequiredFields.isEmpty }

    public enum Field: String, Hashable, Sendable, CaseIterable {
        case amount
        case category
        case currency
        case date
    }

    // MARK: Wire format

    private enum CodingKeys: String, CodingKey {
        case kind, amount, currency, category, merchant, note, date, confidence
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        kind = try container.decodeIfPresent(TransactionKind.self, forKey: .kind) ?? .expense
        amount = try container.decodeIfPresent(Decimal.self, forKey: .amount)

        // An unknown currency code decodes to nil rather than throwing: one unrecognised token should
        // degrade to "currency unstated", not discard an otherwise good parse.
        if let code = try container.decodeIfPresent(String.self, forKey: .currency) {
            currency = Currency.known(code: code)
        } else {
            currency = nil
        }

        if let raw = try container.decodeIfPresent(String.self, forKey: .category) {
            category = TransactionCategory(rawValue: raw)
        } else {
            category = nil
        }

        merchant = try container.decodeIfPresent(String.self, forKey: .merchant)
        note = try container.decodeIfPresent(String.self, forKey: .note)
        date = try container.decodeIfPresent(RelativeDate.self, forKey: .date)
        confidence = (try container.decodeIfPresent(Double.self, forKey: .confidence) ?? 0).clamped(to: 0...1)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(kind, forKey: .kind)
        try container.encode(amount, forKey: .amount)
        try container.encode(currency?.code, forKey: .currency)
        try container.encode(category?.rawValue, forKey: .category)
        try container.encode(merchant, forKey: .merchant)
        try container.encode(note, forKey: .note)
        try container.encode(date, forKey: .date)
        try container.encode(confidence, forKey: .confidence)
    }
}

// MARK: - Outcome

/// What the language layer concluded about an utterance.
public enum ParseOutcome: Hashable, Sendable {

    /// Confident enough to act on directly.
    case transaction(ParsedTransaction)

    /// Understood as a transaction, but something essential is missing or uncertain. The partial parse
    /// is carried along so the UI can pre-fill everything it did get.
    case needsConfirmation(ParsedTransaction, missing: [ParsedTransaction.Field])

    /// Understood, and it is *not* a transaction — a question ("сколько я потратил на еду"), a
    /// greeting, or noise. Silently logging these would quietly corrupt the ledger, so they get their
    /// own case rather than a low-confidence transaction.
    case notATransaction(reason: NonTransactionReason)

    /// Nothing usable at all.
    case empty

    public enum NonTransactionReason: String, Hashable, Sendable, Codable {
        case question
        case command
        case greeting
        case unintelligible
    }

    /// The parse carried by this outcome, if any.
    public var parsed: ParsedTransaction? {
        switch self {
        case .transaction(let parsed): parsed
        case .needsConfirmation(let parsed, _): parsed
        case .notATransaction, .empty: nil
        }
    }
}

// MARK: - Promotion to a real transaction

extension ParsedTransaction {

    /// Turn a parse into a ledger entry, supplying the defaults the user left unsaid.
    ///
    /// Returns `nil` when a required field is still missing — this is the last gate before data lands in
    /// the ledger, and it refuses rather than inventing.
    public func makeTransaction(
        baseCurrency: Currency,
        rate: Decimal? = nil,
        now: Date,
        calendar: Calendar = .autoupdatingCurrent,
        source: EntrySource,
        rawInput: String?
    ) -> Transaction? {
        guard let amount, let category else { return nil }

        let resolvedCurrency = currency ?? baseCurrency
        let money = Money(decimalMajor: amount, currency: resolvedCurrency)
        let when = (date ?? .today).resolve(now: now, calendar: calendar)

        return Transaction(
            kind: kind,
            amount: money,
            baseCurrency: baseCurrency,
            rate: rate,
            category: category,
            merchant: merchant,
            note: note,
            date: when,
            createdAt: now,
            source: source,
            rawInput: rawInput
        )
    }
}

// MARK: -

extension Comparable {
    fileprivate func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
