import Foundation
import Testing

@testable import PulseCore

@Suite("Money arithmetic")
struct MoneyTests {

    @Test("Major-unit construction scales by the currency exponent")
    func majorConstruction() {
        #expect(Money(major: 45_000, currency: .uzs).minorUnits == 4_500_000)
        #expect(Money(major: 12, currency: .usd).minorUnits == 1_200)
        // JPY has no minor unit, so major and minor coincide.
        #expect(Money(major: 500, currency: .jpy).minorUnits == 500)
    }

    @Test("Decimal construction is exact for values Double would mangle")
    func decimalConstructionIsExact() {
        // 0.1 + 0.2 != 0.3 in binary floating point. Through Decimal it is exact.
        let tenCents = Money(decimalMajor: Decimal(string: "0.10")!, currency: .usd)
        let twentyCents = Money(decimalMajor: Decimal(string: "0.20")!, currency: .usd)
        #expect((tenCents + twentyCents).minorUnits == 30)

        #expect(Money(decimalMajor: Decimal(string: "12.35")!, currency: .usd).minorUnits == 1_235)
        #expect(Money(decimalMajor: Decimal(string: "0.005")!, currency: .usd).minorUnits == 1)  // half-up
        #expect(Money(decimalMajor: Decimal(string: "0.004")!, currency: .usd).minorUnits == 0)
    }

    @Test("decimalMajor round-trips construction")
    func decimalRoundTrip() {
        let original = Decimal(string: "1234.56")!
        let money = Money(decimalMajor: original, currency: .usd)
        #expect(money.decimalMajor == original)
    }

    @Test("Addition and subtraction stay exact")
    func addSubtract() {
        let a = Money(major: 45_000, currency: .uzs)
        let b = Money(major: 12_500, currency: .uzs)
        #expect((a + b) == Money(major: 57_500, currency: .uzs))
        #expect((a - b) == Money(major: 32_500, currency: .uzs))
        #expect((b - a) == Money(major: -32_500, currency: .uzs))
        #expect(-a == Money(major: -45_000, currency: .uzs))
    }

    @Test("Accumulating many small amounts does not drift")
    func noDrift() {
        // The classic float failure: 1000 × 0.01 should be exactly 10.00.
        var total = Money.zero(.usd)
        for _ in 0..<1_000 {
            total += Money(minorUnits: 1, currency: .usd)
        }
        #expect(total.minorUnits == 1_000)
        #expect(total.decimalMajor == Decimal(10))
    }

    @Test("Integer scaling multiplies the minor units")
    func integerScaling() {
        let coffee = Money(decimalMajor: Decimal(string: "3.75")!, currency: .usd)
        #expect((coffee * 3).minorUnits == 1_125)
        #expect((coffee * 0).isZero)
    }

    @Test("Decimal scaling rounds half-up to the minor unit")
    func decimalScaling() {
        let bill = Money(decimalMajor: Decimal(string: "100.00")!, currency: .usd)
        #expect(bill.scaled(by: Decimal(string: "0.15")!).minorUnits == 1_500)
        // 33.333... cents rounds to 33.
        #expect(Money(minorUnits: 100, currency: .usd).scaled(by: Decimal(1) / Decimal(3)).minorUnits == 33)
    }

    @Test("Splitting distributes the remainder and always sums back exactly")
    func splitIsLossless() {
        let hundred = Money(minorUnits: 100, currency: .usd)
        let thirds = hundred.split(into: 3)
        #expect(thirds.map(\.minorUnits) == [34, 33, 33])
        #expect(thirds.total(in: .usd) == hundred)

        let seven = Money(minorUnits: 7, currency: .usd)
        #expect(seven.split(into: 2).map(\.minorUnits) == [4, 3])
        #expect(seven.split(into: 7).map(\.minorUnits) == [1, 1, 1, 1, 1, 1, 1])
        #expect(seven.split(into: 1) == [seven])
    }

    @Test("Splitting a negative amount keeps the sign and stays lossless")
    func splitNegative() {
        let refund = Money(minorUnits: -100, currency: .usd)
        let parts = refund.split(into: 3)
        #expect(parts.map(\.minorUnits) == [-34, -33, -33])
        #expect(parts.total(in: .usd) == refund)
    }

    @Test("Conversion applies the supplied rate and re-scales to the target exponent")
    func conversion() {
        let tenDollars = Money(major: 10, currency: .usd)
        let inSoum = tenDollars.converted(to: .uzs, rate: Decimal(12_800))
        #expect(inSoum.currency == .uzs)
        #expect(inSoum.decimalMajor == Decimal(128_000))

        // Converting to the same currency is identity, regardless of the rate passed.
        #expect(tenDollars.converted(to: .usd, rate: Decimal(999)) == tenDollars)
    }

    @Test("Conversion across differing exponents is exact")
    func conversionAcrossExponents() {
        // JPY has 0 minor units, USD has 2.
        let thousandYen = Money(major: 1_000, currency: .jpy)
        let inUsd = thousandYen.converted(to: .usd, rate: Decimal(string: "0.0067")!)
        #expect(inUsd.decimalMajor == Decimal(string: "6.7")!)
        #expect(inUsd.minorUnits == 670)
    }

    @Test("Comparison and sign helpers")
    func comparison() {
        let small = Money(major: 100, currency: .uzs)
        let big = Money(major: 200, currency: .uzs)
        #expect(small < big)
        #expect(big > small)
        #expect(small.isPositive)
        #expect((-small).isNegative)
        #expect(Money.zero(.uzs).isZero)
        #expect((-small).magnitude == small)
    }

    @Test("Summing an empty sequence yields zero in the requested currency")
    func emptySum() {
        let none: [Money] = []
        #expect(none.total(in: .uzs) == Money.zero(.uzs))
    }

    @Test("Money survives a Codable round trip")
    func codableRoundTrip() throws {
        let original = Money(major: 45_000, currency: .uzs)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(Money.self, from: data)
        #expect(decoded == original)
    }

    @Test("Overflow saturates instead of trapping")
    func overflowSaturates() {
        // Absurd input from a fat-fingered entry must not crash the app mid-typing.
        let huge = Money(major: Int64.max / 2, currency: .uzs)
        #expect(huge.minorUnits == Int64.max)
        let hugeNegative = Money(major: Int64.min / 2, currency: .uzs)
        #expect(hugeNegative.minorUnits == Int64.min)
    }
}

@Suite("Currency")
struct CurrencyTests {

    @Test("So'm stores tiyin but displays whole so'm")
    func soumDisplayVsStorage() {
        #expect(Currency.uzs.minorUnitExponent == 2)
        #expect(Currency.uzs.displayFractionDigits == 0)
        #expect(Currency.uzs.minorUnitsPerMajor == 100)
    }

    @Test("Zero-exponent currencies have one minor unit per major")
    func zeroExponent() {
        #expect(Currency.jpy.minorUnitsPerMajor == 1)
        #expect(Currency.jpy.displayFractionDigits == 0)
    }

    @Test("Lookup is case-insensitive and returns nil for unknown codes")
    func lookup() {
        #expect(Currency.known(code: "uzs") == .uzs)
        #expect(Currency.known(code: "UsD") == .usd)
        // Guessing an unknown currency's exponent would silently corrupt amounts by 100×.
        #expect(Currency.known(code: "XYZ") == nil)
    }

    @Test("Known currency codes are unique")
    func codesAreUnique() {
        let codes = Currency.known.map(\.code)
        #expect(Set(codes).count == codes.count)
    }
}
