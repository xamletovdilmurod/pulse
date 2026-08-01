import Foundation

/// Longest-match lookup of multi-word phrases over a token stream.
///
/// Lexicon entries are not all single words — `yandex taxi`, `last friday`, `kofe s soboy`, `har oy` —
/// and matching greedily by the longest phrase matters: `yandex taxi` must win over a bare `yandex`, and
/// `har oy` ("every month", a recurrence) must win over `oy` ("month").
struct PhraseIndex<Value: Sendable>: Sendable {

    private let table: [String: Value]
    private let maxWords: Int

    init(_ table: [String: Value]) {
        self.table = table
        self.maxWords = table.keys.map { $0.split(separator: " ").count }.max() ?? 1
    }

    init(_ keys: Set<String>) where Value == Bool {
        self.init(Dictionary(uniqueKeysWithValues: keys.map { ($0, true) }))
    }

    var isEmpty: Bool { table.isEmpty }

    /// The longest entry matching at `index`, or `nil`.
    ///
    /// When no literal phrase matches a single token, `stems` supplies morphological fallbacks so
    /// `obedga` can still reach the entry filed under `obed`.
    func match(
        _ tokens: [String],
        at index: Int,
        stems: (String) -> [String] = { _ in [] }
    ) -> (value: Value, length: Int)? {
        let longest = min(maxWords, tokens.count - index)
        guard longest > 0 else { return nil }

        for length in stride(from: longest, through: 1, by: -1) {
            let phrase = tokens[index..<(index + length)].joined(separator: " ")
            if let value = table[phrase] {
                return (value, length)
            }
        }

        // Morphology is only worth trying on a single token; suffixes attach to words, not phrases.
        for candidate in stems(tokens[index]) {
            if let value = table[candidate] {
                return (value, 1)
            }
        }
        return nil
    }

    /// Every non-overlapping match across the whole stream, left to right.
    func matches(
        _ tokens: [String],
        stems: (String) -> [String] = { _ in [] }
    ) -> [(value: Value, range: Range<Int>)] {
        var results: [(value: Value, range: Range<Int>)] = []
        var index = 0
        while index < tokens.count {
            if let hit = match(tokens, at: index, stems: stems) {
                results.append((hit.value, index..<(index + hit.length)))
                index += hit.length
            } else {
                index += 1
            }
        }
        return results
    }

    /// Whether anything matches anywhere.
    func containsMatch(_ tokens: [String], stems: (String) -> [String] = { _ in [] }) -> Bool {
        !matches(tokens, stems: stems).isEmpty
    }
}

/// Strips Uzbek case and possessive suffixes to reach a stem the lexicon might list.
///
/// Uzbek is agglutinative and productive: `obed` → `obedga` (to lunch), `korzinka` → `korzinkadan`
/// (from Korzinka), `taksi` → `taksida` (in a taxi). Enumerating every inflected form in the lexicon is
/// impossible, so the suffixes come off here instead.
///
/// This is deliberately shallow and conservative. It returns *candidates*, never a claim — a wrong
/// stem simply fails to match anything, which costs nothing, whereas aggressive stripping would start
/// producing confident wrong matches. Hence the stem-length floor.
enum UzbekMorphology {

    /// Ordered longest-first so `larida` is tried before `da`.
    private static let suffixes: [String] = [
        "larimizga", "laringizga", "larimizdan", "laringizdan",
        "larimiz", "laringiz", "lariga", "laridan", "larida", "larini",
        "imizga", "ingizga", "imizdan", "ingizdan", "larga", "lardan", "larda", "larni",
        "gacha", "dagi", "ning", "imiz", "ingiz", "lari", "lik", "liq", "lar",
        "dan", "ga", "da", "ni", "im", "ing", "si", "cha",
    ]

    /// The shortest stem we will accept. Below this, stripping produces noise that matches by accident.
    private static let minimumStemLength = 3

    static func stems(of token: String) -> [String] {
        var results: [String] = []
        for suffix in suffixes where token.hasSuffix(suffix) {
            let stem = String(token.dropLast(suffix.count))
            guard stem.count >= minimumStemLength else { continue }
            results.append(stem)
            // Uzbek stacks suffixes (`larimizga`), and a vowel is often dropped at the boundary
            // (`shahar` + `ga` → `shaharga`, but `singil` + `im` → `singlim`). One extra pass catches
            // the common two-suffix case without opening the door to nonsense.
            for inner in suffixes where stem.hasSuffix(inner) {
                let deeper = String(stem.dropLast(inner.count))
                if deeper.count >= minimumStemLength {
                    results.append(deeper)
                }
            }
        }
        return results
    }
}
