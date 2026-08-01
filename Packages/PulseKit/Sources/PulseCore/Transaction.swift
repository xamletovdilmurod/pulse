import Foundation

/// How a transaction got into the ledger. Worth recording: it tells us which entry paths people actually
/// use, and it lets the app show "you said …" next to anything the language layer produced.
public enum EntrySource: String, Hashable, Sendable, Codable, CaseIterable {
    /// Typed into the structured form.
    case manual
    /// Typed as free text and parsed.
    case text
    /// Spoken and parsed.
    case voice
    /// Created by repeating an earlier transaction.
    case recurring
}

/// A single movement of money.
///
/// The amount is stored twice on purpose. `amount` is what the user actually spent, in the currency they
/// actually spent it in. `baseAmount` is that value converted to their base currency **at the rate that
/// was true when they spent it**, frozen forever. Recomputing history from today's rate would mean last
/// year's lunch silently changes price every morning, which makes trends meaningless and trust
/// impossible. Storing both costs a few bytes and removes a whole class of confusing bugs.
public struct Transaction: Identifiable, Hashable, Sendable, Codable {

    public let id: UUID

    public var kind: TransactionKind

    /// What was spent, in the currency it was spent in.
    public var amount: Money

    /// `amount` converted to the ledger's base currency, frozen at entry time.
    public var baseAmount: Money

    /// Price of one major unit of `amount.currency` in major units of `baseAmount.currency`, as applied.
    /// Exactly 1 when no conversion happened.
    public var fxRate: Decimal

    public var category: TransactionCategory

    /// Named counterparty, if the user mentioned one ("Korzinka", "Yandex Taxi").
    public var merchant: String?

    /// Free-text detail the user supplied.
    public var note: String?

    /// When the money moved — not when the row was created. These differ whenever someone logs
    /// yesterday's lunch this morning, which is most of the time.
    public var date: Date

    public var createdAt: Date

    public var source: EntrySource

    /// The exact text the user typed or spoke, when there was one.
    ///
    /// Kept so the UI can show what was heard, so a mis-parse can be corrected in context, and so the
    /// user can later contribute real utterances back to the training set if they choose to.
    public var rawInput: String?

    public init(
        id: UUID = UUID(),
        kind: TransactionKind,
        amount: Money,
        baseAmount: Money,
        fxRate: Decimal,
        category: TransactionCategory,
        merchant: String? = nil,
        note: String? = nil,
        date: Date,
        createdAt: Date,
        source: EntrySource,
        rawInput: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.amount = amount
        self.baseAmount = baseAmount
        self.fxRate = fxRate
        self.category = category
        self.merchant = merchant
        self.note = note
        self.date = date
        self.createdAt = createdAt
        self.source = source
        self.rawInput = rawInput
    }

    /// Build a transaction, converting into the base currency and recording the rate used.
    ///
    /// `rate` is the price of one major unit of `amount.currency` in `baseCurrency`. Pass `nil` when the
    /// amount is already in the base currency.
    public init(
        id: UUID = UUID(),
        kind: TransactionKind,
        amount: Money,
        baseCurrency: Currency,
        rate: Decimal? = nil,
        category: TransactionCategory,
        merchant: String? = nil,
        note: String? = nil,
        date: Date,
        createdAt: Date = Date(),
        source: EntrySource,
        rawInput: String? = nil
    ) {
        let effectiveRate: Decimal = amount.currency == baseCurrency ? 1 : (rate ?? 1)
        self.init(
            id: id,
            kind: kind,
            amount: amount,
            baseAmount: amount.converted(to: baseCurrency, rate: effectiveRate),
            fxRate: effectiveRate,
            category: category,
            merchant: merchant,
            note: note,
            date: date,
            createdAt: createdAt,
            source: source,
            rawInput: rawInput
        )
    }

    /// Signed value in the base currency: negative for expenses, positive for income.
    ///
    /// Amounts are always stored as positive magnitudes; the sign lives in `kind`. Anything that needs
    /// to sum across both sides of the ledger should use this rather than re-deriving the sign.
    public var signedBaseAmount: Money {
        kind == .expense ? -baseAmount.magnitude : baseAmount.magnitude
    }

    /// Whether the transaction was created by the language layer rather than typed into the form.
    public var isFromLanguageInput: Bool {
        source == .text || source == .voice
    }
}

// MARK: - Aggregation

extension Sequence where Element == Transaction {

    /// Net movement in the base currency: income minus expenses.
    public func net(in baseCurrency: Currency) -> Money {
        reduce(Money.zero(baseCurrency)) { $0 + $1.signedBaseAmount }
    }

    /// Total spent (expenses only), as a positive amount.
    public func totalSpent(in baseCurrency: Currency) -> Money {
        lazy.filter { $0.kind == .expense }
            .reduce(Money.zero(baseCurrency)) { $0 + $1.baseAmount.magnitude }
    }

    /// Total earned (income only), as a positive amount.
    public func totalEarned(in baseCurrency: Currency) -> Money {
        lazy.filter { $0.kind == .income }
            .reduce(Money.zero(baseCurrency)) { $0 + $1.baseAmount.magnitude }
    }

    /// Expense totals per category, positive amounts, largest first.
    public func spendByTransactionCategory(in baseCurrency: Currency) -> [(category: TransactionCategory, total: Money)] {
        var totals: [TransactionCategory: Money] = [:]
        for transaction in self where transaction.kind == .expense {
            let running = totals[transaction.category] ?? Money.zero(baseCurrency)
            totals[transaction.category] = running + transaction.baseAmount.magnitude
        }
        return totals
            .map { (category: $0.key, total: $0.value) }
            .sorted {
                $0.total == $1.total
                    ? $0.category.rawValue < $1.category.rawValue
                    : $0.total > $1.total
            }
    }
}
