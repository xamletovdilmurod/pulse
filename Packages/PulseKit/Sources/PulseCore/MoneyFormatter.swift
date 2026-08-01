import Foundation

/// Renders `Money` for humans.
///
/// This does not use Foundation's built-in currency style directly, for one stubborn reason: the so'm has
/// no Unicode symbol, so the system renders it as the literal code — "UZS 45,000" — which no Uzbek would
/// ever write. Since so'm is this app's primary currency, the everyday case would be the ugly one. So the
/// digits are formatted with the user's locale (grouping and decimal separators are genuinely locale
/// business) and the symbol is attached according to the currency's own convention.
public struct MoneyFormatter: Sendable {

    public enum Style: Sendable {
        /// `45 000 so'm`, `$12.35`
        case full
        /// `45K so'm`, `$12.35` — for dense chart labels and tight rows.
        case compact
        /// `45 000` — digits only, for when the currency is already established by context.
        case plain
    }

    /// Sign rendering. Amounts are stored unsigned with the direction in `TransactionKind`, so the
    /// caller decides how to show direction.
    public enum SignStyle: Sendable {
        /// Show `-` only for genuinely negative values.
        case automatic
        /// Never show a sign; render the magnitude.
        case never
        /// Always show `+` or `−`, using the true minus sign for visual balance in lists.
        case always
    }

    public var locale: Locale

    public init(locale: Locale = .autoupdatingCurrent) {
        self.locale = locale
    }

    public func string(
        from money: Money,
        style: Style = .full,
        sign: SignStyle = .automatic
    ) -> String {
        let digits = formattedDigits(for: money, style: style)
        let signPrefix = signPrefix(for: money, sign: sign)

        switch style {
        case .plain:
            return signPrefix + digits
        case .full, .compact:
            let currency = money.currency
            return currency.symbolIsPrefix
                ? signPrefix + currency.symbol + digits
                : signPrefix + digits + "\u{00A0}" + currency.symbol
        }
    }

    // MARK: - Digits

    private func formattedDigits(for money: Money, style: Style) -> String {
        let magnitude = abs(money.decimalMajor)
        let fractionDigits = money.currency.displayFractionDigits

        switch style {
        case .compact:
            return magnitude.formatted(
                .number
                    .notation(.compactName)
                    .precision(.fractionLength(0...1))
                    .locale(locale)
            )
        case .full, .plain:
            return magnitude.formatted(
                .number
                    .grouping(.automatic)
                    .precision(.fractionLength(fractionDigits))
                    .locale(locale)
            )
        }
    }

    private func signPrefix(for money: Money, sign: SignStyle) -> String {
        switch sign {
        case .never:
            ""
        case .automatic:
            money.isNegative ? "\u{2212}" : ""
        case .always:
            money.isNegative ? "\u{2212}" : "+"
        }
    }
}

// MARK: - Convenience

extension Money {
    /// Format with the current locale. For repeated formatting, hold a `MoneyFormatter` instead.
    public func formatted(
        style: MoneyFormatter.Style = .full,
        sign: MoneyFormatter.SignStyle = .automatic,
        locale: Locale = .autoupdatingCurrent
    ) -> String {
        MoneyFormatter(locale: locale).string(from: self, style: style, sign: sign)
    }
}

private func abs(_ value: Decimal) -> Decimal {
    value < 0 ? -value : value
}
