import Foundation
import PulseCore
import Testing

@testable import PulseParse

/// Measures the deterministic parser against the gold corpus.
///
/// These are not pass/fail unit tests so much as a standing benchmark. The deterministic layer is
/// explicitly *not* expected to handle everything — the long tail is the fine-tuned model's job — so the
/// thresholds here are floors that guard against regression, not targets. The printed report is the
/// point: it shows exactly which phenomena are still unhandled, which is what drives the next fix.
@Suite("Corpus evaluation", .enabled(if: TestData.real != nil && !TestData.corpus.isEmpty))
struct CorpusEvaluationTests {

    private struct Tally {
        var attempted = 0
        var correct = 0
        var rate: Double { attempted == 0 ? 1 : Double(correct) / Double(attempted) }
        var summary: String {
            "\(correct)/\(attempted) (\(Int((rate * 100).rounded()))%)"
        }
        mutating func record(_ ok: Bool) {
            attempted += 1
            if ok { correct += 1 }
        }
    }

    @Test("Deterministic parser benchmark")
    func benchmark() throws {
        let lexicon = try #require(TestData.real)
        let parser = ExpenseParser(lexicon: lexicon)

        var amount = Tally()
        var category = Tally()
        var kind = Tally()
        var currency = Tally()
        var date = Tally()
        var rejection = Tally()

        var byDifficulty: [String: Tally] = [:]
        var failures: [String] = []

        for testCase in TestData.corpus {
            let reading = parser.analyze(testCase.text)
            let got = reading.parsed
            let want = testCase.expected

            // The corpus marks non-transactions — questions, app commands, future intentions — with
            // very low confidence, but still fills `category` with the "other" placeholder. Scoring
            // those field-by-field would punish the parser for correctly declining to categorise a
            // question it already rejected. They are scored only on whether they were rejected.
            guard want.confidence >= 0.25 else {
                rejection.record(got.confidence < 0.35)
                if got.confidence >= 0.35, failures.count < 30 {
                    failures.append(
                        "  NOT-A-TRANSACTION accepted: \"\(testCase.text)\" "
                            + "conf=\(String(format: "%.2f", got.confidence))"
                    )
                }
                continue
            }

            // Amount: only scored where the corpus states one.
            var amountOK = true
            if let expected = want.amount {
                amountOK = got.amount == expected
                amount.record(amountOK)
            } else if got.amount != nil {
                // Inventing an amount that was never said is the worst failure mode here.
                amountOK = false
                amount.record(false)
            }

            var categoryOK = true
            if let expected = want.category {
                categoryOK = got.category == expected
                category.record(categoryOK)
            }

            kind.record(got.kind == want.kind)

            if let expected = want.currency {
                currency.record(got.currency == expected)
            } else if got.currency != nil {
                currency.record(false)
            }

            if let expected = want.date {
                date.record(got.date == expected)
            }

            let overallOK = amountOK && categoryOK
            byDifficulty[testCase.difficulty ?? "unknown", default: Tally()].record(overallOK)

            if !overallOK, failures.count < 30 {
                failures.append(
                    """
                      "\(testCase.text)"
                        want: amount=\(want.amount.map(String.init(describing:)) ?? "nil") \
                    category=\(want.category?.rawValue ?? "nil") kind=\(want.kind.rawValue)
                        got:  amount=\(got.amount.map(String.init(describing:)) ?? "nil") \
                    category=\(got.category?.rawValue ?? "nil") kind=\(got.kind.rawValue) \
                    conf=\(String(format: "%.2f", got.confidence))
                    """
                )
            }
        }

        let report = """

            ┌─ Deterministic parser vs gold corpus (\(TestData.corpus.count) utterances)
            │  amount      \(amount.summary)
            │  category    \(category.summary)
            │  kind        \(kind.summary)
            │  currency    \(currency.summary)
            │  date        \(date.summary)
            │  rejects non-transactions  \(rejection.summary)
            ├─ amount+category correct, by difficulty
            \(byDifficulty.sorted { $0.key < $1.key }.map { "│  \($0.key.padded(to: 10)) \($0.value.summary)" }.joined(separator: "\n"))
            └─ sample failures
            \(failures.joined(separator: "\n"))

            """
        print(report)

        // Floors, not targets. The model layer covers the rest.
        #expect(amount.rate >= 0.70, "amount extraction regressed: \(amount.summary)\n\(report)")
        #expect(kind.rate >= 0.80, "income/expense direction regressed: \(kind.summary)")
        #expect(category.rate >= 0.55, "category assignment regressed: \(category.summary)")
    }
}

extension String {
    fileprivate func padded(to width: Int) -> String {
        count >= width ? self : self + String(repeating: " ", count: width - count)
    }
}
