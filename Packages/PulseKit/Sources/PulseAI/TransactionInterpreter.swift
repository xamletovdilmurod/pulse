import Foundation
import PulseCore
import PulseParse

/// Anything that can turn an utterance into a structured reading.
///
/// Both the deterministic parser and the fine-tuned model conform, which is what lets the app treat
/// them interchangeably and lets the layered composition below be tested with a stub instead of a
/// 400 MB model.
public protocol TransactionInterpreter: Sendable {
    func interpret(_ text: String) async throws -> ParseOutcome
}

/// A language model that emits the parse as JSON.
public protocol ExpenseModel: Sendable {
    /// Whether the weights are loaded and inference can run right now.
    var isReady: Bool { get async }

    /// Run the model and return its raw completion.
    func complete(prompt: String) async throws -> String
}

public enum InterpreterError: Error, Sendable {
    case modelUnavailable
    case malformedModelOutput(String)
}

/// The deterministic parser, as an interpreter.
public struct DeterministicInterpreter: TransactionInterpreter {
    private let parser: ExpenseParser

    public init(parser: ExpenseParser) {
        self.parser = parser
    }

    public func interpret(_ text: String) async throws -> ParseOutcome {
        parser.parse(text)
    }
}
