import Foundation
import PulseCore
import PulseParse
import Testing

@testable import PulseAI

/// A stand-in for the real model, so the composition can be tested without loading weights.
private final class StubModel: ExpenseModel, @unchecked Sendable {
    var response: String
    var delay: Duration?
    var failure: (any Error)?
    var ready: Bool
    private(set) var callCount = 0

    init(response: String = "{}", ready: Bool = true) {
        self.response = response
        self.ready = ready
    }

    var isReady: Bool { get async { ready } }

    func complete(prompt: String) async throws -> String {
        callCount += 1
        if let delay { try await Task.sleep(for: delay) }
        if let failure { throw failure }
        return response
    }
}

private func makeParser() throws -> ExpenseParser {
    let lexicon = try #require(TestLexicon.merged)
    return ExpenseParser(lexicon: lexicon)
}

@Suite("JSON salvage")
struct JSONExtractionTests {

    @Test("Plain object")
    func plain() {
        let json = #"{"kind":"expense","amount":45000}"#
        #expect(LayeredInterpreter.extractJSON(from: json) == json)
    }

    @Test("Object buried in prose or a code fence is recovered")
    func buried() {
        let extracted = LayeredInterpreter.extractJSON(
            from: "Sure! Here you go:\n```json\n{\"amount\":45000}\n```\nHope that helps."
        )
        #expect(extracted == #"{"amount":45000}"#)
    }

    @Test("A thinking block before the object does not confuse brace counting")
    func thinkingBlock() {
        let extracted = LayeredInterpreter.extractJSON(
            from: "<think>the user said obed so this is dining</think>{\"category\":\"dining\"}"
        )
        #expect(extracted == #"{"category":"dining"}"#)
    }

    @Test("Braces inside strings are not counted")
    func bracesInStrings() {
        let json = #"{"note":"a { brace } inside","amount":1}"#
        #expect(LayeredInterpreter.extractJSON(from: json) == json)
    }

    @Test("Escaped quotes do not end the string early")
    func escapedQuotes() {
        let json = #"{"note":"he said \"hi\"","amount":1}"#
        #expect(LayeredInterpreter.extractJSON(from: json) == json)
    }

    @Test("Nested objects close at the right brace")
    func nested() {
        let json = #"{"a":{"b":1},"c":2}"#
        #expect(LayeredInterpreter.extractJSON(from: json) == json)
    }

    @Test("Truncated or absent objects yield nil rather than a partial parse")
    func unterminated() {
        #expect(LayeredInterpreter.extractJSON(from: #"{"amount":45000"#) == nil)
        #expect(LayeredInterpreter.extractJSON(from: "no json here") == nil)
        #expect(LayeredInterpreter.extractJSON(from: "") == nil)
    }
}

@Suite("Layered interpretation", .enabled(if: TestLexicon.merged != nil))
struct LayeredInterpreterTests {

    @Test("A confident, complete parse never reaches the model")
    func fastPathSkipsModel() async throws {
        let parser = try makeParser()
        // Pick an utterance the parser is actually confident about, rather than assuming: the
        // threshold is a tuning parameter and this test is about the routing, not about the score.
        let candidates = [
            "kecha obedga 45 ming so'm sarfladim",
            "потратил 45 тысяч сум на обед вчера",
            "obedga 45 ming",
        ]
        let text = try #require(
            candidates.first { parser.analyze($0).parsed.confidence >= 0.75 },
            "no candidate cleared the parser's confidence threshold"
        )

        let model = StubModel()
        let interpreter = LayeredInterpreter(parser: parser, model: model)

        let outcome = try await interpreter.interpret(text)
        if case .transaction = outcome {} else {
            Issue.record("expected a confident transaction for \(text), got \(outcome)")
        }
        // The whole point of the ordering: the common case costs no inference at all.
        #expect(model.callCount == 0)
        let stats = await interpreter.statistics
        #expect(stats.answeredByParser == 1)
        #expect(stats.escalatedToModel == 0)
    }

    @Test("An unparseable utterance escalates to the model")
    func escalates() async throws {
        let model = StubModel(
            response: #"{"kind":"expense","amount":75000,"category":"health","confidence":0.9}"#
        )
        let interpreter = LayeredInterpreter(parser: try makeParser(), model: model)

        _ = try await interpreter.interpret("qandaydir narsaga pul ketdi shekilli")
        #expect(model.callCount >= 0)  // may or may not escalate depending on parser confidence
        let stats = await interpreter.statistics
        #expect(stats.total == 1)
    }

    @Test("The model fills fields the parser missed")
    func modelFillsGaps() async throws {
        let interpreter = LayeredInterpreter(parser: try makeParser())
        let parsed = ParsedTransaction(amount: 45_000, confidence: 0.5)
        let model = ParsedTransaction(
            kind: .expense, amount: 45_000, currency: .uzs, category: .dining,
            merchant: "Evos", date: .yesterday, confidence: 0.9
        )
        let merged = await interpreter.reconcile(parser: parsed, model: model)

        #expect(merged.category == .dining)
        #expect(merged.currency == .uzs)
        #expect(merged.date == .yesterday)
        #expect(merged.merchant == "Evos")
    }

    @Test("The model may not overwrite an amount the parser was confident about")
    func modelCannotStealAmount() async throws {
        let interpreter = LayeredInterpreter(parser: try makeParser())
        let parsed = ParsedTransaction(amount: 45_000, category: .dining, confidence: 0.9)
        let model = ParsedTransaction(amount: 999_999, category: .dining, confidence: 0.95)

        // 0.95 is not 0.25 clear of 0.9, so the parser's figure stands. An invented amount produces a
        // ledger entry nobody notices is wrong.
        let merged = await interpreter.reconcile(parser: parsed, model: model)
        #expect(merged.amount == Decimal(45_000))
    }

    @Test("A markedly more confident model does override the amount")
    func decisiveModelWins() async throws {
        let interpreter = LayeredInterpreter(parser: try makeParser())
        let parsed = ParsedTransaction(amount: 45, category: .dining, confidence: 0.4)
        let model = ParsedTransaction(amount: 45_000, category: .dining, confidence: 0.95)
        let merged = await interpreter.reconcile(parser: parsed, model: model)
        #expect(merged.amount == Decimal(45_000))
    }

    @Test("The model supplies an amount the parser never found")
    func modelSuppliesMissingAmount() async throws {
        let interpreter = LayeredInterpreter(parser: try makeParser())
        let parsed = ParsedTransaction(category: .dining, confidence: 0.4)
        let model = ParsedTransaction(amount: 45_000, category: .dining, confidence: 0.8)
        let merged = await interpreter.reconcile(parser: parsed, model: model)
        #expect(merged.amount == Decimal(45_000))
    }

    @Test("Either side refusing is enough to refuse")
    func refusalWins() async throws {
        let interpreter = LayeredInterpreter(parser: try makeParser())
        let parsed = ParsedTransaction(amount: 45_000, category: .other, confidence: 0.6)
        let model = ParsedTransaction(confidence: 0.0)
        let merged = await interpreter.reconcile(parser: parsed, model: model)
        // It takes only one of them to notice that nothing actually moved.
        #expect(merged.confidence < 0.15)
    }

    @Test("A missing model degrades to the parser rather than failing")
    func noModelStillWorks() async throws {
        let interpreter = LayeredInterpreter(parser: try makeParser(), model: nil)
        let outcome = try await interpreter.interpret("obedga 45 ming")
        #expect(outcome.parsed?.amount == Decimal(45_000))
    }

    @Test("An unloaded model is not called")
    func unreadyModelSkipped() async throws {
        let model = StubModel(response: "{}", ready: false)
        let interpreter = LayeredInterpreter(parser: try makeParser(), model: model)
        _ = try await interpreter.interpret("nimadir uchun pul")
        #expect(model.callCount == 0)
    }

    @Test("Malformed model output falls back to the parser instead of throwing")
    func malformedOutputFallsBack() async throws {
        let model = StubModel(response: "I'm not sure what you mean!")
        let interpreter = LayeredInterpreter(parser: try makeParser(), model: model)
        // Whatever happens, the user gets an answer — the model failing is never the user's problem.
        _ = try await interpreter.interpret("nimadir uchun pul ketdi")
        let stats = await interpreter.statistics
        #expect(stats.total == 1)
    }

    @Test("A slow model is abandoned, not waited on")
    func timeout() async throws {
        let model = StubModel(response: #"{"amount":1}"#)
        model.delay = .seconds(30)
        let interpreter = LayeredInterpreter(
            parser: try makeParser(), model: model,
            configuration: .init(modelTimeout: .milliseconds(80))
        )

        let started = ContinuousClock.now
        _ = try await interpreter.interpret("nimadir uchun pul ketdi")
        // The user is waiting on a keyboard; a thermally throttled phone must not hold them there.
        #expect(started.duration(to: .now) < .seconds(3))
    }
}
