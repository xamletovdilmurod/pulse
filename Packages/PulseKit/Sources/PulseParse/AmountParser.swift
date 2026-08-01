import Foundation

/// Finds monetary quantities in a token stream.
///
/// Handles the three shapes people actually produce, and mixtures of them:
///   digits with a magnitude word — `45 ming`, `50 k`, `8 mln`, `45 тыс`
///   fully spelled out — `двадцать пять тысяч`, `to'rt million`, `besh yuz`
///   bare digits — `45 000`, `12.35`, `45,000`
///
/// It deliberately does **not** decide whether a bare `50` means fifty or fifty thousand. That depends
/// on the language, the currency, and the surrounding words, none of which this layer can see; it
/// reports ``Match/hadExplicitMagnitude`` and lets the layer that does have that context decide.
/// Likewise it returns *every* amount it finds rather than picking one, because "2 kg go'sht 40 ming"
/// contains a quantity and a price and only the caller can tell them apart.
public struct AmountParser: Sendable {

    private let lexicon: MergedLexicon

    public init(lexicon: MergedLexicon) {
        self.lexicon = lexicon
    }

    public struct Match: Hashable, Sendable {
        /// The value in major units.
        public let value: Decimal
        /// Indices into the token array that produced it.
        public let tokenRange: Range<Int>
        /// Whether a magnitude word (`ming`, `k`, `mln`) was actually spoken.
        ///
        /// When false, the value is exactly the digits given, and the caller must decide whether an
        /// unspoken "thousand" was implied.
        public let hadExplicitMagnitude: Bool
        /// Whether any part of the number was written as words rather than digits.
        public let wasSpelledOut: Bool

        /// A magnitude word with no quantity attached — "spent k on coffee", where the number was
        /// dropped or mis-transcribed. The value defaults to one of the magnitude, which is a guess
        /// rather than a reading, so callers should treat it as very weak evidence.
        public let wasBareMagnitude: Bool
    }

    /// Every amount in the token stream, left to right, non-overlapping.
    ///
    /// `excluding` names token positions that hold a number which is definitely not money — a petrol
    /// octane grade, the count in "three days ago". They are skipped entirely rather than merely
    /// deprioritised, because a stray digit adjacent to a real amount does not compete with it, it
    /// *joins* it: "аи 92 310 к" would otherwise read as 92 310 000.
    public func amounts(in tokens: [String], excluding: Set<Int> = []) -> [Match] {
        var matches: [Match] = []
        var index = 0
        while index < tokens.count {
            if excluding.contains(index) {
                index += 1
                continue
            }
            if let match = scan(tokens, from: index, excluding: excluding) {
                matches.append(match)
                index = match.tokenRange.upperBound
            } else {
                index += 1
            }
        }
        return matches
    }

    /// The single most likely *price* in the stream.
    ///
    /// Prefers an amount that carried an explicit magnitude word — someone who says "2 kg go'sht 40
    /// ming" attached the magnitude to the price, not the quantity — and falls back to the largest
    /// value, then to the first.
    public func principalAmount(in tokens: [String], excluding: Set<Int> = []) -> Match? {
        let all = amounts(in: tokens, excluding: excluding)
        guard !all.isEmpty else { return nil }
        if let explicit = all.filter(\.hadExplicitMagnitude).max(by: { $0.value < $1.value }) {
            return explicit
        }
        return all.max { $0.value < $1.value }
    }

    // MARK: - Scanning

    /// Try to consume one amount expression starting at `start`.
    private func scan(_ tokens: [String], from start: Int, excluding: Set<Int> = []) -> Match? {
        // Running total of completed magnitude groups (the "45 000" in "45 ming 500").
        var total: Decimal = 0
        // The group being built, awaiting a magnitude word to scale it.
        var current: Decimal = 0
        var currentHasValue = false

        var sawNumber = false
        var sawMagnitude = false
        var sawSpelledOut = false
        var index = start

        while index < tokens.count {
            if excluding.contains(index) { break }
            let token = tokens[index]
            let key = MergedLexicon.key(token)

            if let entry = lexicon.magnitudes[key] {
                if entry >= Self.magnitudeThreshold {
                    // A real scale. A bare one means one of it: "ming so'm" is a thousand so'm.
                    total += (currentHasValue ? current : 1) * entry
                    current = 0
                    currentHasValue = false
                    sawMagnitude = true
                } else {
                    // A coefficient like `yarim`/`ярим` (half) or `полтора` (one and a half).
                    apply(coefficient: entry, to: &current, hasValue: &currentHasValue)
                    sawNumber = true
                }
                sawSpelledOut = true
                index += 1
                continue
            }

            if let digits = Self.decimalFromDigits(token) {
                // Two adjacent digit groups are two separate numbers ("45 12"), not one — stop.
                if currentHasValue { break }
                current = digits
                currentHasValue = true
                sawNumber = true
                index += 1
                continue
            }

            // A function word ends the amount, even if some other language files it as a numeral.
            //
            // This matters more than it sounds: the Uzbek lexicon records `on` as the dictation form of
            // `o'n` (ten), so without this the English "spent 40k **on** taxi" parses as 40 000 + 10.
            // Function words are far more frequent than bare spelled-out numerals, so they win.
            if lexicon.noiseWords.contains(key) {
                break
            }

            if let value = lexicon.numbers[key] {
                // Number words at or above a thousand behave as magnitudes, however they were filed.
                if value >= Self.magnitudeThreshold {
                    total += (currentHasValue ? current : 1) * value
                    current = 0
                    currentHasValue = false
                    sawMagnitude = true
                } else if value == 100 {
                    // Hundreds multiply: "besh yuz" is 500, not 105.
                    current = (currentHasValue ? current : 1) * 100
                    currentHasValue = true
                } else if value < 1 {
                    // Fractional words like `пол` (half).
                    apply(coefficient: value, to: &current, hasValue: &currentHasValue)
                } else {
                    // Units and tens add: "двадцать пять" is 25. `полтора` (1.5) rides this path too.
                    current += value
                    currentHasValue = true
                }
                sawNumber = true
                sawSpelledOut = true
                index += 1
                continue
            }

            break
        }

        guard sawNumber || sawMagnitude else { return nil }

        let value = total + current
        return Match(
            value: value,
            tokenRange: start..<index,
            hadExplicitMagnitude: sawMagnitude,
            wasSpelledOut: sawSpelledOut,
            wasBareMagnitude: sawMagnitude && !sawNumber
        )
    }

    /// Below this, a lexicon "magnitude" is really a coefficient rather than a scale. Genuine
    /// magnitudes in every language we handle are 1 000 or more; anything smaller is a `half`-type
    /// modifier, and treating it as a scale would turn `yarim million` into a million and a half.
    private static let magnitudeThreshold: Decimal = 1000

    /// Fold a fractional coefficient into the group being built.
    ///
    /// Position decides the meaning. Standing alone it *is* the quantity — `yarim million` is half a
    /// million. Following a number it extends it — `bir yarim million` is one and a half million, and
    /// `two and half million` is two and a half.
    private func apply(coefficient: Decimal, to current: inout Decimal, hasValue: inout Bool) {
        current = hasValue ? current + coefficient : coefficient
        hasValue = true
    }

    // MARK: - Digit groups

    /// Interpret a digit token, resolving whether separators group thousands or mark a decimal.
    ///
    /// The hard case is `45.000`, which is forty-five thousand to a Russian speaker and forty-five to an
    /// American. Digit-count decides: exactly three digits after the last separator means grouping,
    /// one or two means a decimal fraction. That is the convention every locale agrees on in practice,
    /// and it is the only signal available inside a single token.
    static func decimalFromDigits(_ token: String) -> Decimal? {
        guard let first = token.first, first.isNumber else { return nil }

        let separators: Set<Character> = [",", ".", " ", "\u{00A0}"]
        guard token.allSatisfy({ $0.isNumber || separators.contains($0) }) else { return nil }

        let groups = token.split(whereSeparator: { separators.contains($0) }).map(String.init)
        guard !groups.isEmpty else { return nil }
        guard groups.allSatisfy({ $0.allSatisfy(\.isNumber) }) else { return nil }

        if groups.count == 1 {
            return Decimal(string: groups[0])
        }

        let last = groups[groups.count - 1]
        let leading = groups.dropLast()

        // A space is only ever a grouping separator — no locale writes a decimal point as a space.
        let separatedBySpace = token.contains(" ") || token.contains("\u{00A0}")

        // A decimal fraction: one separator, and 1-2 trailing digits.
        if !separatedBySpace, groups.count == 2, last.count <= 2 {
            return Decimal(string: "\(groups[0]).\(last)")
        }

        // Otherwise treat every separator as grouping, provided the groups look like thousands.
        let groupsAreThousands =
            last.count == 3 && leading.dropFirst().allSatisfy { $0.count == 3 } && leading[leading.startIndex].count <= 3
        if groupsAreThousands {
            return Decimal(string: groups.joined())
        }

        // Malformed but recoverable — concatenate rather than lose the number entirely.
        return Decimal(string: groups.joined())
    }
}
