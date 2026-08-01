import Foundation
import Testing

@testable import PulseCore

@Suite("Transaction")
struct TransactionTests {

    private let base = Currency.uzs

    private func expense(
        _ major: Int64,
        _ currency: Currency = .uzs,
        rate: Decimal? = nil,
        category: TransactionCategory = .other,
        daysAgo: Int = 0
    ) -> Transaction {
        Transaction(
            kind: .expense,
            amount: Money(major: major, currency: currency),
            baseCurrency: base,
            rate: rate,
            category: category,
            date: Date(timeIntervalSince1970: 1_754_000_000 - Double(daysAgo) * 86_400),
            source: .manual
        )
    }

    private func income(_ major: Int64, category: TransactionCategory = .salary) -> Transaction {
        Transaction(
            kind: .income,
            amount: Money(major: major, currency: base),
            baseCurrency: base,
            category: category,
            date: Date(timeIntervalSince1970: 1_754_000_000),
            source: .manual
        )
    }

    @Test("Same-currency entry uses a rate of exactly 1 and does not alter the amount")
    func noConversionWhenCurrenciesMatch() {
        let t = expense(45_000)
        #expect(t.fxRate == 1)
        #expect(t.baseAmount == t.amount)
    }

    @Test("Foreign-currency entry converts and freezes the rate used")
    func conversionIsFrozen() {
        let t = expense(10, .usd, rate: Decimal(12_800))
        #expect(t.amount == Money(major: 10, currency: .usd))
        #expect(t.baseAmount == Money(major: 128_000, currency: .uzs))
        #expect(t.fxRate == Decimal(12_800))
        // The original amount is preserved untouched — the user spent 10 dollars, not 128 000 so'm.
        #expect(t.amount.currency == .usd)
    }

    @Test("A missing rate on a foreign amount does not silently scale the value")
    func missingRateIsIdentity() {
        // Defaulting to some invented rate would be far worse than defaulting to 1:1, which is at least
        // visibly wrong and correctable.
        let t = expense(10, .usd, rate: nil)
        #expect(t.fxRate == 1)
        #expect(t.baseAmount.decimalMajor == Decimal(10))
    }

    @Test("Sign comes from kind, not from the stored amount")
    func signedAmount() {
        #expect(expense(45_000).signedBaseAmount == Money(major: -45_000, currency: .uzs))
        #expect(income(8_000_000).signedBaseAmount == Money(major: 8_000_000, currency: .uzs))
        // Even if an amount somehow arrives negative, kind still decides the direction.
        var weird = expense(45_000)
        weird.baseAmount = Money(major: -45_000, currency: .uzs)
        #expect(weird.signedBaseAmount == Money(major: -45_000, currency: .uzs))
    }

    @Test("Net, spent, and earned aggregate correctly across both sides")
    func aggregates() {
        let ledger = [
            expense(45_000, category: .dining),
            expense(25_000, category: .transport),
            income(8_000_000),
            expense(10, .usd, rate: Decimal(12_800), category: .clothing),
        ]
        #expect(ledger.totalSpent(in: base) == Money(major: 198_000, currency: .uzs))
        #expect(ledger.totalEarned(in: base) == Money(major: 8_000_000, currency: .uzs))
        #expect(ledger.net(in: base) == Money(major: 7_802_000, currency: .uzs))
    }

    @Test("Empty ledger aggregates to zero rather than trapping")
    func emptyAggregates() {
        let empty: [Transaction] = []
        #expect(empty.net(in: base).isZero)
        #expect(empty.totalSpent(in: base).isZero)
        #expect(empty.spendByTransactionCategory(in: base).isEmpty)
    }

    @Test("TransactionCategory breakdown sums per category, ignores income, and sorts by size")
    func categoryBreakdown() {
        let ledger = [
            expense(45_000, category: .dining),
            expense(15_000, category: .dining),
            expense(90_000, category: .groceries),
            income(8_000_000),
        ]
        let breakdown = ledger.spendByTransactionCategory(in: base)
        #expect(breakdown.count == 2)
        #expect(breakdown[0].category == .groceries)
        #expect(breakdown[0].total == Money(major: 90_000, currency: .uzs))
        #expect(breakdown[1].category == .dining)
        #expect(breakdown[1].total == Money(major: 60_000, currency: .uzs))
        // TransactionCategory totals must reconcile with the overall total.
        #expect(breakdown.map(\.total).total(in: base) == ledger.totalSpent(in: base))
    }

    @Test("TransactionCategory kind matches the ledger side it belongs to")
    func categoryKinds() {
        #expect(TransactionCategory.groceries.kind == .expense)
        #expect(TransactionCategory.salary.kind == .income)
        #expect(TransactionCategory.refund.kind == .income)
        #expect(TransactionCategory.expenseCategories.allSatisfy { $0.kind == .expense })
        #expect(TransactionCategory.incomeCategories.allSatisfy { $0.kind == .income })
        #expect(TransactionCategory.expenseCategories.count + TransactionCategory.incomeCategories.count == TransactionCategory.allCases.count)
    }

    @Test("TransactionCategory raw values are the stable wire format shared with the model")
    func categoryRawValuesAreStable() {
        // These strings appear verbatim in the training corpus. Changing one is a migration.
        #expect(TransactionCategory.cafeCoffee.rawValue == "cafe_coffee")
        #expect(TransactionCategory.giftReceived.rawValue == "gift_received")
        #expect(TransactionCategory.otherIncome.rawValue == "other_income")
        #expect(TransactionCategory(rawValue: "groceries") == .groceries)
        #expect(TransactionCategory(rawValue: "not_a_category") == nil)
    }

    @Test("Fallback category respects the ledger side")
    func fallbacks() {
        #expect(TransactionCategory.fallback(for: .expense) == .other)
        #expect(TransactionCategory.fallback(for: .income) == .otherIncome)
    }

    @Test("Transaction survives a Codable round trip")
    func codable() throws {
        let original = expense(10, .usd, rate: Decimal(12_800), category: .clothing)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(Transaction.self, from: data)
        #expect(decoded == original)
        #expect(decoded.fxRate == Decimal(12_800))
    }

    @Test("Language-sourced entries are flagged and keep the original utterance")
    func languageSource() {
        let spoken = Transaction(
            kind: .expense,
            amount: Money(major: 45_000, currency: .uzs),
            baseCurrency: base,
            category: .dining,
            date: Date(timeIntervalSince1970: 1_754_000_000),
            source: .voice,
            rawInput: "obed uchun 45 ming so'm"
        )
        #expect(spoken.isFromLanguageInput)
        #expect(spoken.rawInput == "obed uchun 45 ming so'm")
        #expect(!expense(1).isFromLanguageInput)
    }
}

@Suite("MoneyFormatter")
struct MoneyFormatterTests {

    // Pinned locale so grouping separators are deterministic regardless of the test machine.
    private let formatter = MoneyFormatter(locale: Locale(identifier: "en_US"))

    @Test("So'm renders as a suffix with no decimals")
    func soum() {
        let text = formatter.string(from: Money(major: 45_000, currency: .uzs))
        #expect(text == "45,000\u{00A0}so'm")
        // Tiyin exist in storage but must never surface.
        #expect(!text.contains("."))
    }

    @Test("Dollar renders as a prefix with two decimals")
    func dollars() {
        #expect(formatter.string(from: Money(decimalMajor: Decimal(string: "12.35")!, currency: .usd)) == "$12.35")
        #expect(formatter.string(from: Money(major: 12, currency: .usd)) == "$12.00")
    }

    @Test("Plain style drops the symbol entirely")
    func plain() {
        #expect(formatter.string(from: Money(major: 45_000, currency: .uzs), style: .plain) == "45,000")
    }

    @Test("Compact style shortens large amounts for dense labels")
    func compact() {
        let text = formatter.string(from: Money(major: 45_000, currency: .uzs), style: .compact)
        #expect(text.contains("45K"))
        let millions = formatter.string(from: Money(major: 8_000_000, currency: .uzs), style: .compact)
        #expect(millions.contains("8M"))
    }

    @Test("Sign styles")
    func signs() {
        let spend = Money(major: -45_000, currency: .uzs)
        let earn = Money(major: 45_000, currency: .uzs)
        // A real minus sign, not a hyphen — it aligns with digits in a column.
        #expect(formatter.string(from: spend).hasPrefix("\u{2212}"))
        #expect(formatter.string(from: spend, sign: .never) == formatter.string(from: earn, sign: .never))
        #expect(formatter.string(from: earn, sign: .always).hasPrefix("+"))
        #expect(!formatter.string(from: earn).hasPrefix("+"))
    }

    @Test("Zero-decimal currencies never show a fraction")
    func zeroDecimalCurrency() {
        #expect(formatter.string(from: Money(major: 500, currency: .jpy)) == "¥500")
    }

    @Test("Locale drives the grouping separator")
    func localeAware() {
        let russian = MoneyFormatter(locale: Locale(identifier: "ru_RU"))
        let text = russian.string(from: Money(major: 45_000, currency: .uzs), style: .plain)
        // Russian groups with a space (non-breaking or narrow), never a comma.
        #expect(!text.contains(","))
        #expect(text.contains("45"))
        #expect(text.contains("000"))
    }
}
