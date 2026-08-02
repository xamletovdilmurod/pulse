import Foundation
import PulseCore
import PulseParse

/// Runs the deterministic parser first and consults the model only when the parser is unsure.
///
/// The ordering is not an optimisation detail, it is the product decision. The parser answers in
/// microseconds, costs no battery, works with the model absent or still downloading, and — measured on
/// the held-out corpus — beats the 0.6B model on amount, category and direction. So it goes first, and
/// the model is spent only on the utterances the parser could not settle, where a ~600 ms wait is worth
/// it because the alternative is asking the user.
///
/// Reconciliation is deliberately conservative. A model that invents an amount produces a ledger entry
/// the user never notices is wrong, which is far worse than one extra tap — so the model may *add*
/// what the parser missed and may *raise* confidence, but its amount is only taken when the parser
/// found none, or when the model is markedly more certain.
public actor LayeredInterpreter: TransactionInterpreter {

    public struct Configuration: Sendable {
        /// Parser confidence at or above which the model is never consulted.
        public var parserSufficientConfidence: Double
        /// How much more confident the model must be before its amount overrides the parser's.
        public var modelOverrideMargin: Double
        /// Give up on the model after this long and return the parser's reading.
        public var modelTimeout: Duration

        public init(
            parserSufficientConfidence: Double = 0.75,
            modelOverrideMargin: Double = 0.25,
            modelTimeout: Duration = .seconds(6)
        ) {
            self.parserSufficientConfidence = parserSufficientConfidence
            self.modelOverrideMargin = modelOverrideMargin
            self.modelTimeout = modelTimeout
        }
    }

    private let parser: ExpenseParser
    private let model: (any ExpenseModel)?
    private let configuration: Configuration

    /// Instrumentation, so we can tell how often the model actually earns its place.
    public private(set) var statistics = Statistics()

    public struct Statistics: Sendable, Equatable {
        public var total = 0
        public var answeredByParser = 0
        public var escalatedToModel = 0
        public var modelImproved = 0
        public var modelFailed = 0

        public var escalationRate: Double {
            total == 0 ? 0 : Double(escalatedToModel) / Double(total)
        }
    }

    public init(
        parser: ExpenseParser,
        model: (any ExpenseModel)? = nil,
        configuration: Configuration = Configuration()
    ) {
        self.parser = parser
        self.model = model
        self.configuration = configuration
    }

    public func interpret(_ text: String) async throws -> ParseOutcome {
        statistics.total += 1

        let reading = parser.analyze(text)
        let parsed = reading.parsed
        let parserOutcome = parser.parse(text)

        // The parser is sure and complete: answer now, spend nothing.
        if parsed.isComplete, parsed.confidence >= configuration.parserSufficientConfidence {
            statistics.answeredByParser += 1
            return parserOutcome
        }

        // A confident refusal also needs no model. Questions and plans are recognised by structure —
        // an interrogative, a future marker — and a model is unlikely to know better.
        if case .notATransaction = parserOutcome, parsed.confidence < 0.15 {
            statistics.answeredByParser += 1
            return parserOutcome
        }

        guard let model, await model.isReady else {
            statistics.answeredByParser += 1
            return parserOutcome
        }

        statistics.escalatedToModel += 1
        do {
            let modelParse = try await withTimeout(configuration.modelTimeout) {
                try await Self.run(model: model, on: text)
            }
            let merged = reconcile(parser: parsed, model: modelParse)
            if merged != parsed {
                statistics.modelImproved += 1
            }
            return outcome(for: merged)
        } catch {
            // Any failure — timeout, malformed JSON, model not loaded — falls back to the parser.
            // The app must never be blocked by the model being unavailable.
            statistics.modelFailed += 1
            return parserOutcome
        }
    }

    // MARK: - Reconciliation

    /// Combine the two readings, preferring the parser wherever it committed to something.
    func reconcile(parser parsed: ParsedTransaction, model: ParsedTransaction) -> ParsedTransaction {
        var merged = parsed

        // Amount: the field where a wrong answer does the most damage. Take the model's only when the
        // parser found nothing, or when the model is much more certain.
        if parsed.amount == nil {
            merged.amount = model.amount
        } else if model.amount != nil,
            model.confidence > parsed.confidence + configuration.modelOverrideMargin
        {
            merged.amount = model.amount
        }

        // The remaining fields are cheap to correct and cheap to get wrong, so the model fills gaps.
        merged.category = parsed.category ?? model.category
        merged.currency = parsed.currency ?? model.currency
        merged.date = parsed.date ?? model.date
        merged.merchant = parsed.merchant ?? model.merchant
        merged.note = parsed.note ?? model.note

        // Direction: trust the model only when the parser had no categorical basis for its guess.
        if parsed.category == nil, model.category != nil {
            merged.kind = model.kind
        }

        // A refusal from either side is respected: it takes only one of them to notice that nothing
        // actually moved.
        merged.confidence = min(
            max(parsed.confidence, model.confidence),
            model.confidence < 0.15 ? model.confidence : 1
        )
        return merged
    }

    private func outcome(for parsed: ParsedTransaction) -> ParseOutcome {
        if parsed.confidence < 0.35 {
            return .notATransaction(reason: .unintelligible)
        }
        let missing = parsed.missingRequiredFields
        if missing.isEmpty, parsed.confidence >= configuration.parserSufficientConfidence {
            return .transaction(parsed)
        }
        return .needsConfirmation(parsed, missing: missing)
    }

    // MARK: - Model plumbing

    /// The instruction the model was fine-tuned against. It must match
    /// `SYSTEM_PROMPT` in `ml/scripts/generate_training_data.py` exactly — a model asked a different
    /// question than it was trained on answers a different question.
    public static let systemPrompt = """
        Extract the transaction from the user's message as JSON with keys: \
        kind, amount, currency, category, merchant, note, date, confidence. \
        The user writes in Uzbek, Russian, or English. \
        Use null for anything not stated. Do not guess.
        """

    private static func run(model: any ExpenseModel, on text: String) async throws -> ParsedTransaction {
        let completion = try await model.complete(prompt: text)
        guard let json = extractJSON(from: completion) else {
            throw InterpreterError.malformedModelOutput(completion)
        }
        return try JSONDecoder().decode(ParsedTransaction.self, from: Data(json.utf8))
    }

    /// Pull the first balanced JSON object out of a completion.
    ///
    /// Small models pad their output — a stray sentence, a code fence, a thinking block. Salvaging the
    /// object beats discarding an otherwise good parse, so this scans for brace balance rather than
    /// requiring the whole string to be JSON.
    static func extractJSON(from text: String) -> String? {
        guard let start = text.firstIndex(of: "{") else { return nil }
        var depth = 0
        var inString = false
        var escaped = false
        var index = start

        while index < text.endIndex {
            let character = text[index]
            if inString {
                if escaped {
                    escaped = false
                } else if character == "\\" {
                    escaped = true
                } else if character == "\"" {
                    inString = false
                }
            } else if character == "\"" {
                inString = true
            } else if character == "{" {
                depth += 1
            } else if character == "}" {
                depth -= 1
                if depth == 0 {
                    return String(text[start...index])
                }
            }
            index = text.index(after: index)
        }
        return nil
    }
}

// MARK: - Timeout

/// Run `work`, cancelling it if it outlives `duration`.
///
/// Inference on a phone is fast until it is not — a thermally throttled device under memory pressure
/// can take many seconds. The user is waiting on a keyboard, so we bound it and fall back.
func withTimeout<T: Sendable>(
    _ duration: Duration,
    work: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await work() }
        group.addTask {
            try await Task.sleep(for: duration)
            throw InterpreterError.modelUnavailable
        }
        guard let result = try await group.next() else {
            throw InterpreterError.modelUnavailable
        }
        group.cancelAll()
        return result
    }
}
