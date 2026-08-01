import Foundation

/// An exact monetary amount in a single currency.
///
/// Stored as a signed integer count of *minor units* (tiyin, cents, kopeks). Binary floating point can
/// not represent 0.10 exactly, and a finance app that accumulates rounding drift is worse than no finance
/// app at all — so `Double` never touches an amount anywhere in Pulse.
///
/// `Money` is deliberately hard to misuse across currencies: `+` and `-` require an exact currency match
/// and trap otherwise. Converting is always explicit, via ``converted(to:rate:)``, because a silent
/// implicit conversion is exactly the kind of bug that quietly reports someone's spending as 12× reality.
public struct Money: Hashable, Sendable, Codable {

    /// Signed count of minor units. Negative is meaningful (refunds, corrections, net balances).
    public let minorUnits: Int64

    public let currency: Currency

    public init(minorUnits: Int64, currency: Currency) {
        self.minorUnits = minorUnits
        self.currency = currency
    }

    /// Zero in the given currency.
    public static func zero(_ currency: Currency) -> Money {
        Money(minorUnits: 0, currency: currency)
    }

    // MARK: - Construction from major units

    /// Build from a whole number of major units — `Money(major: 45_000, currency: .uzs)` is 45 000 so'm.
    public init(major: Int64, currency: Currency) {
        self.init(
            minorUnits: major.multipliedReportingOverflowOrClamped(by: currency.minorUnitsPerMajor),
            currency: currency
        )
    }

    /// Build from a `Decimal` amount of major units, rounding half-up to the currency's minor unit.
    ///
    /// `Decimal` is used rather than `Double` because it is base-10: the string "12.35" round-trips
    /// exactly, which is what we get from both text parsing and speech transcription.
    public init(decimalMajor: Decimal, currency: Currency) {
        var scaled = decimalMajor * Decimal(currency.minorUnitsPerMajor)
        var rounded = Decimal()
        NSDecimalRound(&rounded, &scaled, 0, .plain)
        self.init(minorUnits: NSDecimalNumber(decimal: rounded).int64Value, currency: currency)
    }

    /// The amount expressed in major units as an exact base-10 `Decimal`.
    public var decimalMajor: Decimal {
        Decimal(minorUnits) / Decimal(currency.minorUnitsPerMajor)
    }

    // MARK: - Sign

    public var isZero: Bool { minorUnits == 0 }
    public var isNegative: Bool { minorUnits < 0 }
    public var isPositive: Bool { minorUnits > 0 }

    public var magnitude: Money {
        Money(minorUnits: minorUnits.magnitudeClamped, currency: currency)
    }

    // MARK: - Arithmetic

    public static func + (lhs: Money, rhs: Money) -> Money {
        lhs.requireSameCurrency(as: rhs, operation: "+")
        return Money(minorUnits: lhs.minorUnits + rhs.minorUnits, currency: lhs.currency)
    }

    public static func - (lhs: Money, rhs: Money) -> Money {
        lhs.requireSameCurrency(as: rhs, operation: "-")
        return Money(minorUnits: lhs.minorUnits - rhs.minorUnits, currency: lhs.currency)
    }

    public static prefix func - (value: Money) -> Money {
        Money(minorUnits: 0 - value.minorUnits, currency: value.currency)
    }

    public static func += (lhs: inout Money, rhs: Money) { lhs = lhs + rhs }
    public static func -= (lhs: inout Money, rhs: Money) { lhs = lhs - rhs }

    /// Scale by an integer count (e.g. three identical coffees).
    public static func * (lhs: Money, rhs: Int) -> Money {
        Money(
            minorUnits: lhs.minorUnits.multipliedReportingOverflowOrClamped(by: Int64(rhs)),
            currency: lhs.currency
        )
    }

    /// Scale by a decimal factor (tip, split, percentage), rounding half-up to the minor unit.
    public func scaled(by factor: Decimal) -> Money {
        var product = Decimal(minorUnits) * factor
        var rounded = Decimal()
        NSDecimalRound(&rounded, &product, 0, .plain)
        return Money(
            minorUnits: NSDecimalNumber(decimal: rounded).int64Value,
            currency: currency
        )
    }

    /// Split into `parts` shares that sum *exactly* back to the original.
    ///
    /// Splitting 100 into 3 gives [34, 33, 33], not three lots of 33.33 that lose a minor unit. The
    /// remainder is distributed one minor unit at a time to the earliest shares.
    public func split(into parts: Int) -> [Money] {
        precondition(parts > 0, "cannot split money into \(parts) parts")
        let count = Int64(parts)
        let base = minorUnits / count
        let remainder = minorUnits % count
        // `remainder` carries the sign of `minorUnits`, so this works for negative amounts too.
        let step: Int64 = remainder < 0 ? -1 : 1
        var leftover = remainder.magnitudeClamped
        return (0..<parts).map { _ in
            var share = base
            if leftover > 0 {
                share += step
                leftover -= 1
            }
            return Money(minorUnits: share, currency: currency)
        }
    }

    // MARK: - Conversion

    /// Convert to another currency at an explicit rate.
    ///
    /// `rate` is the price of one major unit of `self.currency` expressed in major units of `target`
    /// — converting 10 USD to UZS at 12 800 so'm per dollar means `rate == 12_800`.
    ///
    /// The rate is always supplied by the caller and stored alongside the transaction rather than being
    /// looked up at read time, so historical spending doesn't silently rewrite itself when FX moves.
    public func converted(to target: Currency, rate: Decimal) -> Money {
        guard currency != target else { return self }
        let majors = decimalMajor * rate
        return Money(decimalMajor: majors, currency: target)
    }

    // MARK: - Comparison helpers

    private func requireSameCurrency(as other: Money, operation: String) {
        precondition(
            currency == other.currency,
            "Refusing to \(operation) \(currency.code) and \(other.currency.code). "
                + "Convert explicitly with converted(to:rate:) first."
        )
    }
}

// MARK: - Comparable

extension Money: Comparable {
    /// Ordering is only defined within a currency; comparing across currencies traps.
    public static func < (lhs: Money, rhs: Money) -> Bool {
        lhs.requireSameCurrency(as: rhs, operation: "compare")
        return lhs.minorUnits < rhs.minorUnits
    }
}

// MARK: - Sequence sum

extension Sequence where Element == Money {
    /// Sum a sequence of same-currency amounts. Returns zero in `currency` when empty.
    public func total(in currency: Currency) -> Money {
        reduce(Money.zero(currency), +)
    }
}

// MARK: - CustomStringConvertible

extension Money: CustomStringConvertible {
    /// Unambiguous debug form. User-facing formatting lives in `MoneyFormatter`.
    public var description: String {
        "\(decimalMajor) \(currency.code)"
    }
}

// MARK: - Overflow handling

extension Int64 {
    /// Saturating magnitude — `Int64.min.magnitude` does not fit in `Int64`, so clamp instead of trapping.
    fileprivate var magnitudeClamped: Int64 {
        self == Int64.min ? Int64.max : (self < 0 ? -self : self)
    }

    /// Saturating multiply.
    ///
    /// Amounts this large are always bad input rather than real money, and clamping keeps a nonsense
    /// entry from crashing the app mid-typing. Validation rejects them before they reach storage.
    fileprivate func multipliedReportingOverflowOrClamped(by other: Int64) -> Int64 {
        let (result, overflow) = multipliedReportingOverflow(by: other)
        guard overflow else { return result }
        let negative = (self < 0) != (other < 0)
        return negative ? Int64.min : Int64.max
    }
}
