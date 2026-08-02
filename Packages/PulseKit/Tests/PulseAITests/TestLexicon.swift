import Foundation

@testable import PulseParse

/// Loads the repository's real lexicons for the PulseAI tests.
///
/// Duplicated from PulseParseTests rather than shared: test targets cannot import each other, and a
/// third target existing only to hold ten lines of path arithmetic would cost more than it saves.
enum TestLexicon {
    static let directory: URL = URL(filePath: #filePath)
        .deletingLastPathComponent()   // PulseAITests
        .deletingLastPathComponent()   // Tests
        .deletingLastPathComponent()   // PulseKit
        .deletingLastPathComponent()   // Packages
        .deletingLastPathComponent()   // repo root
        .appending(path: "ml/data/lexicon")

    static let merged: MergedLexicon? = try? Lexicon.merged(fromDirectory: directory)
}
