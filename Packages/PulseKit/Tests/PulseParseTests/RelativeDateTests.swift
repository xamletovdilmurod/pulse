import Foundation
import PulseCore
import Testing

@testable import PulseParse

@Suite("RelativeDate")
struct RelativeDateTests {

    /// Fixed UTC calendar so results never depend on where the test runs.
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    /// 2026-08-01, a Saturday. Chosen so weekday arithmetic has somewhere to wrap.
    private var now: Date {
        var components = DateComponents()
        components.year = 2026
        components.month = 8
        components.day = 1
        components.hour = 14
        components.minute = 30
        return calendar.date(from: components)!
    }

    private func daysBetween(_ resolved: Date) -> Int {
        calendar.dateComponents([.day], from: resolved, to: calendar.startOfDay(for: now)).day!
    }

    @Test("The anchor date really is a Saturday")
    func anchorSanity() {
        #expect(calendar.component(.weekday, from: now) == 7)
    }

    @Test("Resolution normalises to the start of the day")
    func startOfDay() {
        let resolved = RelativeDate.today.resolve(now: now, calendar: calendar)
        #expect(calendar.component(.hour, from: resolved) == 0)
        #expect(calendar.component(.minute, from: resolved) == 0)
        // A time of day would break day-grouping; the entry belongs to the day, not the instant.
        #expect(resolved == calendar.startOfDay(for: now))
    }

    @Test("Simple offsets")
    func simpleOffsets() {
        #expect(daysBetween(RelativeDate.today.resolve(now: now, calendar: calendar)) == 0)
        #expect(daysBetween(RelativeDate.yesterday.resolve(now: now, calendar: calendar)) == 1)
        #expect(daysBetween(RelativeDate.dayBeforeYesterday.resolve(now: now, calendar: calendar)) == 2)
        #expect(daysBetween(RelativeDate.daysAgo(5).resolve(now: now, calendar: calendar)) == 5)
    }

    @Test("A negative day count is treated as magnitude, never as the future")
    func negativeDaysAgo() {
        // "3 days ago" can only mean the past; a sign slip must not silently create a future entry.
        #expect(daysBetween(RelativeDate.daysAgo(-3).resolve(now: now, calendar: calendar)) == 3)
    }

    @Test("last_<weekday> is always strictly in the past")
    func lastWeekday() {
        // Anchor is Saturday. "Last Friday" is one day back.
        #expect(daysBetween(RelativeDate.lastWeekday(.friday).resolve(now: now, calendar: calendar)) == 1)
        #expect(daysBetween(RelativeDate.lastWeekday(.monday).resolve(now: now, calendar: calendar)) == 5)
        #expect(daysBetween(RelativeDate.lastWeekday(.sunday).resolve(now: now, calendar: calendar)) == 6)
        // "Last Saturday" said on a Saturday means a week ago, not today.
        #expect(daysBetween(RelativeDate.lastWeekday(.saturday).resolve(now: now, calendar: calendar)) == 7)
    }

    @Test("this_<weekday> may resolve to today")
    func thisWeekday() {
        #expect(daysBetween(RelativeDate.thisWeekday(.saturday).resolve(now: now, calendar: calendar)) == 0)
        #expect(daysBetween(RelativeDate.thisWeekday(.friday).resolve(now: now, calendar: calendar)) == 1)
        #expect(daysBetween(RelativeDate.thisWeekday(.monday).resolve(now: now, calendar: calendar)) == 5)
    }

    @Test("Absolute dates resolve exactly")
    func absolute() {
        let resolved = RelativeDate.absolute(year: 2026, month: 3, day: 14)
            .resolve(now: now, calendar: calendar)
        #expect(calendar.component(.year, from: resolved) == 2026)
        #expect(calendar.component(.month, from: resolved) == 3)
        #expect(calendar.component(.day, from: resolved) == 14)
    }

    @Test("Resolution is stable across the time of day it is asked")
    func stableAcrossTimeOfDay() {
        // Same calendar day, very different clock times — "yesterday" must not drift.
        let earlyMorning = calendar.date(bySettingHour: 0, minute: 5, second: 0, of: now)!
        let lateNight = calendar.date(bySettingHour: 23, minute: 55, second: 0, of: now)!
        let a = RelativeDate.yesterday.resolve(now: earlyMorning, calendar: calendar)
        let b = RelativeDate.yesterday.resolve(now: lateNight, calendar: calendar)
        #expect(a == b)
    }

    // MARK: Wire format

    @Test("Wire values round-trip through the exact corpus strings")
    func wireRoundTrip() {
        let cases: [(RelativeDate, String)] = [
            (.today, "today"),
            (.yesterday, "yesterday"),
            (.dayBeforeYesterday, "day_before_yesterday"),
            (.lastWeekday(.friday), "last_friday"),
            (.thisWeekday(.monday), "this_monday"),
            (.daysAgo(3), "3_days_ago"),
            (.absolute(year: 2026, month: 3, day: 14), "2026-03-14"),
        ]
        for (value, wire) in cases {
            #expect(value.wireValue == wire)
            #expect(RelativeDate(wireValue: wire) == value)
        }
    }

    @Test("Unrecognised wire values return nil rather than defaulting to today")
    func rejectsGarbage() {
        // Silently landing on today is exactly the error a user never notices.
        #expect(RelativeDate(wireValue: "sometime") == nil)
        #expect(RelativeDate(wireValue: "last_smarch") == nil)
        #expect(RelativeDate(wireValue: "") == nil)
        #expect(RelativeDate(wireValue: "2026-13-40") == nil)
        #expect(RelativeDate(wireValue: "-1_days_ago") == nil)
    }

    @Test("Wire parsing tolerates casing and surrounding whitespace")
    func lenientWhitespace() {
        #expect(RelativeDate(wireValue: "  Yesterday ") == .yesterday)
        #expect(RelativeDate(wireValue: "LAST_FRIDAY") == .lastWeekday(.friday))
    }

    @Test("Codable uses the wire format directly")
    func codable() throws {
        let encoded = try JSONEncoder().encode(RelativeDate.lastWeekday(.friday))
        #expect(String(decoding: encoded, as: UTF8.self) == "\"last_friday\"")
        #expect(try JSONDecoder().decode(RelativeDate.self, from: encoded) == .lastWeekday(.friday))
    }
}

@Suite("ParsedTransaction")
struct ParsedTransactionTests {

    @Test("Missing fields are only those no default can supply")
    func missingFields() {
        let bare = ParsedTransaction()
        #expect(bare.missingRequiredFields == [.amount, .category])
        #expect(!bare.isComplete)

        // Currency and date have safe defaults, so their absence is not blocking.
        let noCurrencyOrDate = ParsedTransaction(amount: 45_000, category: .dining, confidence: 0.9)
        #expect(noCurrencyOrDate.missingRequiredFields.isEmpty)
        #expect(noCurrencyOrDate.isComplete)
    }

    @Test("Confidence is clamped into 0...1")
    func confidenceClamped() {
        #expect(ParsedTransaction(confidence: 5).confidence == 1)
        #expect(ParsedTransaction(confidence: -2).confidence == 0)
    }

    @Test("Decodes the model's JSON wire format")
    func decodesModelOutput() throws {
        let json = """
            {"kind":"expense","amount":45000,"currency":"UZS","category":"dining",
             "merchant":"Evos","note":"obed","date":"yesterday","confidence":0.92}
            """
        let parsed = try JSONDecoder().decode(ParsedTransaction.self, from: Data(json.utf8))
        #expect(parsed.kind == .expense)
        #expect(parsed.amount == Decimal(45_000))
        #expect(parsed.currency == .uzs)
        #expect(parsed.category == .dining)
        #expect(parsed.merchant == "Evos")
        #expect(parsed.date == .yesterday)
        #expect(parsed.confidence == 0.92)
    }

    @Test("Nulls decode as absent, not as defaults")
    func decodesNulls() throws {
        let json = """
            {"kind":"expense","amount":50,"currency":null,"category":"transport",
             "merchant":null,"note":null,"date":null,"confidence":0.7}
            """
        let parsed = try JSONDecoder().decode(ParsedTransaction.self, from: Data(json.utf8))
        #expect(parsed.currency == nil)
        #expect(parsed.date == nil)
        #expect(parsed.merchant == nil)
    }

    @Test("An unknown currency or category degrades to nil instead of failing the whole parse")
    func toleratesUnknownEnums() throws {
        // A model that hallucinates one token should cost us that field, not the entire utterance.
        let json = """
            {"kind":"expense","amount":45000,"currency":"XYZ","category":"teleportation","confidence":0.5}
            """
        let parsed = try JSONDecoder().decode(ParsedTransaction.self, from: Data(json.utf8))
        #expect(parsed.amount == Decimal(45_000))
        #expect(parsed.currency == nil)
        #expect(parsed.category == nil)
        #expect(parsed.missingRequiredFields == [.category])
    }

    @Test("Encoding produces the same shape the corpus uses")
    func encodesWireFormat() throws {
        let parsed = ParsedTransaction(
            kind: .income, amount: 8_000_000, currency: .uzs, category: .salary,
            date: .today, confidence: 0.95
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let text = String(decoding: try encoder.encode(parsed), as: UTF8.self)
        #expect(text.contains("\"category\":\"salary\""))
        #expect(text.contains("\"currency\":\"UZS\""))
        #expect(text.contains("\"kind\":\"income\""))
        #expect(text.contains("\"date\":\"today\""))
    }

    @Test("Promotion to a ledger entry fills defaults and resolves the date")
    func promotion() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let now = Date(timeIntervalSince1970: 1_785_000_000)

        let parsed = ParsedTransaction(
            kind: .expense, amount: 45_000, currency: nil, category: .dining,
            date: .yesterday, confidence: 0.9
        )
        let transaction = parsed.makeTransaction(
            baseCurrency: .uzs, now: now, calendar: calendar, source: .voice,
            rawInput: "kecha obed uchun 45 ming"
        )

        #expect(transaction?.amount == Money(major: 45_000, currency: .uzs))
        #expect(transaction?.source == .voice)
        #expect(transaction?.rawInput == "kecha obed uchun 45 ming")
        #expect(transaction?.date == calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: now)))
    }

    @Test("Promotion refuses rather than inventing a missing amount")
    func promotionRefusesIncomplete() {
        let parsed = ParsedTransaction(kind: .expense, category: .dining, confidence: 0.4)
        let transaction = parsed.makeTransaction(
            baseCurrency: .uzs, now: Date(), source: .text, rawInput: "obed"
        )
        #expect(transaction == nil)
    }

    @Test("Outcome carries the partial parse so the UI can pre-fill it")
    func outcomeCarriesParse() {
        let partial = ParsedTransaction(amount: 45_000, confidence: 0.5)
        let outcome = ParseOutcome.needsConfirmation(partial, missing: [.category])
        #expect(outcome.parsed?.amount == Decimal(45_000))
        #expect(ParseOutcome.notATransaction(reason: .question).parsed == nil)
        #expect(ParseOutcome.empty.parsed == nil)
    }
}
