import Foundation

/// An ISO 4217 currency.
///
/// `minorUnitExponent` is the ISO-defined number of decimal places used for *storage and arithmetic*.
/// `displayFractionDigits` is how many we actually *show*, which is not always the same thing. The Uzbek
/// so'm is the motivating case: ISO 4217 assigns UZS two minor units (tiyin), but tiyin have been
/// worthless for decades and no Uzbek ever writes them. So we store exactly per ISO and display zero
/// decimals — arithmetic stays standards-correct while the UI stays honest to how people actually think.
public struct Currency: Hashable, Sendable, Codable {

    /// ISO 4217 alpha-3 code, uppercased (e.g. `"UZS"`).
    public let code: String

    /// ISO 4217 exponent: how many decimal digits the minor unit has. Drives all arithmetic.
    public let minorUnitExponent: Int

    /// How many fraction digits to render. May be less than `minorUnitExponent` (see UZS).
    public let displayFractionDigits: Int

    /// Short symbol for compact UI (`"$"`, `"so'm"`). Not necessarily unique across currencies.
    public let symbol: String

    /// Whether the symbol goes before the digits (`$12.35`) or after them (`45 000 so'm`).
    /// This is a property of the currency's own convention, not of the user's locale.
    public let symbolIsPrefix: Bool

    public init(
        code: String,
        minorUnitExponent: Int,
        displayFractionDigits: Int? = nil,
        symbol: String,
        symbolIsPrefix: Bool = false
    ) {
        precondition(minorUnitExponent >= 0, "minorUnitExponent cannot be negative")
        let display = displayFractionDigits ?? minorUnitExponent
        precondition(
            display >= 0 && display <= minorUnitExponent,
            "displayFractionDigits must be between 0 and minorUnitExponent"
        )
        self.code = code.uppercased()
        self.minorUnitExponent = minorUnitExponent
        self.displayFractionDigits = display
        self.symbol = symbol
        self.symbolIsPrefix = symbolIsPrefix
    }

    /// The number of minor units in one major unit (e.g. 100 for USD, 1 for JPY).
    public var minorUnitsPerMajor: Int64 {
        var result: Int64 = 1
        for _ in 0..<minorUnitExponent { result *= 10 }
        return result
    }
}

// MARK: - Known currencies

extension Currency {

    /// Uzbek so'm — the app's default. Stored with ISO's two minor units, displayed with none.
    public static let uzs = Currency(
        code: "UZS", minorUnitExponent: 2, displayFractionDigits: 0, symbol: "so'm"
    )

    public static let usd = Currency(code: "USD", minorUnitExponent: 2, symbol: "$", symbolIsPrefix: true)
    public static let eur = Currency(code: "EUR", minorUnitExponent: 2, symbol: "€", symbolIsPrefix: true)
    public static let rub = Currency(code: "RUB", minorUnitExponent: 2, symbol: "₽")
    public static let kzt = Currency(code: "KZT", minorUnitExponent: 2, displayFractionDigits: 0, symbol: "₸")
    public static let kgs = Currency(code: "KGS", minorUnitExponent: 2, displayFractionDigits: 0, symbol: "с")
    public static let tjs = Currency(code: "TJS", minorUnitExponent: 2, symbol: "SM")
    public static let try_ = Currency(code: "TRY", minorUnitExponent: 2, symbol: "₺", symbolIsPrefix: true)
    public static let gbp = Currency(code: "GBP", minorUnitExponent: 2, symbol: "£", symbolIsPrefix: true)
    public static let aed = Currency(code: "AED", minorUnitExponent: 2, symbol: "د.إ")
    public static let cny = Currency(code: "CNY", minorUnitExponent: 2, symbol: "¥", symbolIsPrefix: true)
    public static let jpy = Currency(code: "JPY", minorUnitExponent: 0, symbol: "¥", symbolIsPrefix: true)
    public static let krw = Currency(code: "KRW", minorUnitExponent: 0, symbol: "₩", symbolIsPrefix: true)

    /// Every currency Pulse knows how to name and format, in rough order of relevance to an Uzbek user.
    public static let known: [Currency] = [
        .uzs, .usd, .eur, .rub, .kzt, .kgs, .tjs, .try_, .gbp, .aed, .cny, .jpy, .krw,
    ]

    private static let byCode: [String: Currency] = Dictionary(
        uniqueKeysWithValues: known.map { ($0.code, $0) }
    )

    /// Look up a known currency by ISO code, case-insensitively.
    ///
    /// Returns `nil` for unknown codes rather than inventing a currency: guessing the minor-unit exponent
    /// of a currency we don't know would silently corrupt amounts by a factor of 100.
    public static func known(code: String) -> Currency? {
        byCode[code.uppercased()]
    }
}

// MARK: - CustomStringConvertible

extension Currency: CustomStringConvertible {
    public var description: String { code }
}
