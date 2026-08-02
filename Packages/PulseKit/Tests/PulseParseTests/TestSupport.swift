import Foundation

@testable import PulseParse

/// Locates the repository's gold data from inside the test bundle.
///
/// The lexicons and corpora live in `ml/data/` rather than in the package, because they are shared with
/// the Python fine-tuning pipeline. Walking up from `#filePath` keeps the tests reading the same files
/// the model trains on — if the two ever diverge, that is exactly the bug we want a test to catch.
enum TestData {

    static let repoRoot: URL = URL(filePath: #filePath)
        .deletingLastPathComponent()  // PulseParseTests
        .deletingLastPathComponent()  // Tests
        .deletingLastPathComponent()  // PulseKit
        .deletingLastPathComponent()  // Packages
        .deletingLastPathComponent()  // repo root

    static let lexiconDirectory = repoRoot.appending(path: "ml/data/lexicon")
    static let corpusDirectory = repoRoot.appending(path: "ml/data/corpus")

    static var lexiconsAvailable: Bool {
        FileManager.default.fileExists(atPath: lexiconDirectory.path())
            && ((try? FileManager.default.contentsOfDirectory(atPath: lexiconDirectory.path()))?
                .contains { $0.hasSuffix(".json") } ?? false)
    }

    /// The merged real lexicon, loaded once.
    static let real: MergedLexicon? = {
        guard lexiconsAvailable else { return nil }
        return try? Lexicon.merged(fromDirectory: lexiconDirectory)
    }()

    /// One gold corpus line.
    struct CorpusCase: Decodable {
        let text: String
        let lang: String
        let script: String?
        let expected: ParsedTransaction
        let difficulty: String?
        let notes: String?
        let source: String?

        /// Rows the generator produced, as opposed to hand-authored gold now mixed into training.
        var isSynthetic: Bool { (source ?? "").hasPrefix("synthetic") }
    }

    /// The held-out gold rows — the only ones training must never contain.
    static let heldOutGold: [CorpusCase] = {
        let url = generatedDirectory.appending(path: "test.labelled.jsonl")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        let decoder = JSONDecoder()
        return text.split(separator: "\n").compactMap { line in
            try? decoder.decode(CorpusCase.self, from: Data(line.utf8))
        }
    }()

    static let generatedDirectory = repoRoot.appending(path: "ml/data/generated")

    /// The generated training set, if it has been built. Not committed — it is reproducible from
    /// `ml/scripts/generate_training_data.py` with a fixed seed.
    static let synthetic: [CorpusCase] = {
        let url = generatedDirectory.appending(path: "train.labelled.jsonl")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        let decoder = JSONDecoder()
        return text.split(separator: "\n").compactMap { line in
            try? decoder.decode(CorpusCase.self, from: Data(line.utf8))
        }
    }()

    /// Every corpus line across all languages.
    static let corpus: [CorpusCase] = {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: corpusDirectory, includingPropertiesForKeys: nil
        ) else { return [] }

        let decoder = JSONDecoder()
        return files
            .filter { $0.pathExtension == "jsonl" && $0.lastPathComponent != "all.jsonl" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .flatMap { url -> [CorpusCase] in
                guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
                return text.split(separator: "\n").compactMap { line in
                    try? decoder.decode(CorpusCase.self, from: Data(line.utf8))
                }
            }
    }()
}

/// A small hand-built lexicon so the parser's algorithms can be tested without depending on the
/// evolving gold data.
enum SyntheticLexicon {

    static let merged: MergedLexicon = {
        let json = """
            {
              "language": "test",
              "scripts": ["latin", "cyrillic"],
              "magnitude_words": [
                {"surface": "ming",    "multiplier": 1000},
                {"surface": "k",       "multiplier": 1000},
                {"surface": "тыс",     "multiplier": 1000},
                {"surface": "тыща",    "multiplier": 1000},
                {"surface": "тысяч",   "multiplier": 1000},
                {"surface": "million", "multiplier": 1000000},
                {"surface": "mln",     "multiplier": 1000000},
                {"surface": "лям",     "multiplier": 1000000}
              ],
              "number_words": [
                {"surface": "bir", "value": 1}, {"surface": "ikki", "value": 2},
                {"surface": "uch", "value": 3}, {"surface": "to'rt", "value": 4},
                {"surface": "besh", "value": 5}, {"surface": "o'n", "value": 10},
                {"surface": "yigirma", "value": 20}, {"surface": "ellik", "value": 50},
                {"surface": "yuz", "value": 100},
                {"surface": "два", "value": 2}, {"surface": "пять", "value": 5},
                {"surface": "двадцать", "value": 20}, {"surface": "сто", "value": 100},
                {"surface": "пятьсот", "value": 500}
              ],
              "currency_words": [
                {"surface": "so'm", "iso": "UZS"}, {"surface": "сум", "iso": "UZS"},
                {"surface": "dollar", "iso": "USD"}, {"surface": "рублей", "iso": "RUB"}
              ],
              "expense_markers": [{"surface": "sarfladim"}, {"surface": "потратил"}, {"surface": "spent"}],
              "income_markers": [{"surface": "oldim"}, {"surface": "зарплата"}, {"surface": "salary"}],
              "category_keywords": [
                {"category": "dining", "keywords": ["obed", "обед", "lunch"]},
                {"category": "transport", "keywords": ["taksi", "такси", "taxi"]}
              ],
              "date_expressions": [
                {"surface": "kecha", "meaning": "yesterday"},
                {"surface": "вчера", "meaning": "yesterday"},
                {"surface": "bugun", "meaning": "today"}
              ],
              "merchants": [{"surface": "korzinka", "canonical": "Korzinka", "category": "groceries"}],
              "noise_words": ["uchun", "на", "for"]
            }
            """
        let lexicon = try! JSONDecoder().decode(Lexicon.self, from: Data(json.utf8))
        return MergedLexicon(lexicons: [lexicon])
    }()

    static let amountParser = AmountParser(lexicon: merged)
}

/// Tokenize and parse in one step, the way the real pipeline does.
func amounts(_ text: String) -> [AmountParser.Match] {
    let normalized = TextNormalizer().normalize(text)
    return SyntheticLexicon.amountParser.amounts(in: normalized.tokens)
}

func principalAmount(_ text: String) -> AmountParser.Match? {
    let normalized = TextNormalizer().normalize(text)
    return SyntheticLexicon.amountParser.principalAmount(in: normalized.tokens)
}
