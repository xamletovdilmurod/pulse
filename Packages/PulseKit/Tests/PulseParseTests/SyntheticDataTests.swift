import Foundation
import PulseCore
import Testing

@testable import PulseParse

/// Cross-checks the generated training set against the deterministic parser.
///
/// The two were built from the same lexicons but by completely independent code — the generator picks
/// a label and renders text for it, the parser reads text and infers a label. Where they disagree, one
/// of them has a bug, and finding out *before* a fine-tune bakes the error into model weights is worth
/// far more than the test costs.
///
/// The parser is not the authority here; it is a second opinion. So this asserts on the *agreement
/// rate*, and prints the disagreements for inspection rather than failing on any single one.
@Suite("Synthetic training data", .enabled(if: TestData.real != nil && !TestData.synthetic.isEmpty))
struct SyntheticDataTests {

    @Test("Generated utterances are well-formed")
    func wellFormed() throws {
        for row in TestData.synthetic.filter(\.isSynthetic).prefix(2_000) {
            #expect(!row.text.trimmingCharacters(in: .whitespaces).isEmpty)
            // A rendering slot that never got filled would train the model on literal braces.
            #expect(!row.text.contains("{"), "unfilled frame slot: \(row.text)")
            #expect(!row.text.contains("<"), "template placeholder leaked: \(row.text)")
            // Doubled spaces mean a slot rendered empty and the frame collapsed badly.
            #expect(!row.text.contains("  "), "collapsed frame: \(row.text)")

            // Reject rows deliberately blank every slot — that shape *is* the label. Only the rows
            // that claim to be transactions must actually carry one.
            if row.expected.confidence > 0 {
                #expect(row.expected.amount != nil, "no amount: \(row.text)")
                #expect(row.expected.category != nil, "no category: \(row.text)")
            } else {
                #expect(row.expected.amount == nil, "reject row kept an amount: \(row.text)")
                #expect(row.expected.category == .other, "reject row must use 'other': \(row.text)")
            }
        }
    }

    @Test("Amounts agree with an independent reading of the text")
    func amountAgreement() throws {
        let lexicon = try #require(TestData.real)
        let parser = ExpenseParser(lexicon: lexicon)

        var checked = 0
        var agreed = 0
        var disagreements: [String] = []

        for row in TestData.synthetic {
            guard row.isSynthetic, row.expected.confidence > 0, let expected = row.expected.amount
            else { continue }
            checked += 1
            let got = parser.analyze(row.text).parsed.amount
            if got == expected {
                agreed += 1
            } else if disagreements.count < 20 {
                disagreements.append(
                    "  \"\(row.text)\" — generator says \(expected), parser reads "
                        + (got.map(String.init(describing:)) ?? "nil")
                )
            }
        }

        let rate = Double(agreed) / Double(max(checked, 1))
        print("""

            ┌─ Synthetic data cross-check (\(checked) rows)
            │  amount agreement with deterministic parser: \(agreed)/\(checked) \
            (\(Int((rate * 100).rounded()))%)
            └─ sample disagreements
            \(disagreements.joined(separator: "\n"))

            """)

        // Some disagreement is expected and healthy — the generator deliberately produces forms the
        // deterministic parser cannot handle, which is precisely what the model is being trained for.
        // A collapse below this floor, though, means the generator is rendering text that does not say
        // what its label claims.
        #expect(rate > 0.80, "synthetic amounts diverge from the text that encodes them")
    }

    @Test("Categories and direction agree at a sane rate")
    func categoryAgreement() throws {
        let lexicon = try #require(TestData.real)
        let parser = ExpenseParser(lexicon: lexicon)

        var categoryAgreed = 0
        var kindAgreed = 0
        let rows = Array(
            TestData.synthetic.filter { $0.isSynthetic && $0.expected.confidence > 0 }.prefix(3_000)
        )

        for row in rows {
            let parsed = parser.analyze(row.text).parsed
            if parsed.category == row.expected.category { categoryAgreed += 1 }
            if parsed.kind == row.expected.kind { kindAgreed += 1 }
        }

        let categoryRate = Double(categoryAgreed) / Double(rows.count)
        let kindRate = Double(kindAgreed) / Double(rows.count)
        print(
            "│  category agreement: \(Int((categoryRate * 100).rounded()))%  "
                + "kind agreement: \(Int((kindRate * 100).rounded()))%"
        )

        #expect(categoryRate > 0.75, "generated category words do not map back to their category")
        #expect(kindRate > 0.85, "generated income/expense framing does not read as its label")
    }

    @Test("No training row duplicates a held-out gold row")
    func noTestLeakage() throws {
        // Part of the gold corpus is now mixed into training on purpose — templates alone taught the
        // model template shapes rather than the language. What must never leak is the *held-out*
        // portion, because training on the benchmark would make every accuracy number a lie.
        let goldTexts = Set(
            TestData.heldOutGold.map { $0.text.trimmingCharacters(in: .whitespaces).lowercased() }
        )
        let leaked = TestData.synthetic
            .map { $0.text.trimmingCharacters(in: .whitespaces).lowercased() }
            .filter(goldTexts.contains)
        #expect(leaked.isEmpty, "training set overlaps the held-out gold corpus: \(leaked.prefix(5))")
    }
}
