import Foundation
import SwiftData

enum QuizItemKind: String, Codable, CaseIterable, Sendable {
    /// Single correct option.
    case multipleChoice
    /// "Which of these are true" — partial credit.
    case multipleSelect
    /// Free text graded by the model against an expected-answer rubric.
    case shortAnswer
    /// Show broken/suboptimal code or a prompt; learner explains the flaw.
    case critique
    /// Predict the output/behavior before being shown it (generation effect).
    case prediction
}

/// How sure the learner said they were, before seeing the answer.
/// Comparing this against correctness is what produces `calibrationBias`.
enum ConfidenceLevel: Int, Codable, CaseIterable, Sendable {
    case guessing = 0
    case unsure = 1
    case fairlySure = 2
    case certain = 3

    var label: String {
        switch self {
        case .guessing:
            return String(localized: "Guessing", comment: "Confidence before an answer is revealed: no idea")
        case .unsure:
            return String(localized: "Unsure", comment: "Confidence before an answer is revealed: leaning one way")
        case .fairlySure:
            return String(localized: "Fairly sure", comment: "Confidence before an answer is revealed: reasonably confident")
        case .certain:
            return String(localized: "Certain", comment: "Confidence before an answer is revealed: completely sure")
        }
    }

    /// Normalised 0...1, for comparison against a 0/1 correctness outcome.
    var normalized: Double { Double(rawValue) / 3.0 }
}

/// One graded question inside an attempt.
struct QuizItemRecord: Codable, Hashable, Sendable, Identifiable {
    var id: UUID
    var conceptID: String
    var kindRaw: String
    var prompt: String
    /// Present for choice-based kinds.
    var options: [String]
    /// Indices into `options` that are correct.
    var correctIndices: [Int]
    /// For short-answer/critique/prediction: what a good answer contains.
    var expectedAnswer: String?

    var selectedIndices: [Int]
    var writtenAnswer: String?
    var confidenceRaw: Int
    /// 0...1. Binary for choice questions, graded for free text.
    var score: Double
    var explanation: String
    /// Model feedback on a free-text answer.
    var feedback: String?

    var kind: QuizItemKind { QuizItemKind(rawValue: kindRaw) ?? .multipleChoice }
    var confidence: ConfidenceLevel { ConfidenceLevel(rawValue: confidenceRaw) ?? .unsure }
    var isCorrect: Bool { score >= 0.999 }
}

@Model
final class QuizAttempt {
    @Attribute(.unique) var id: UUID
    var learnerID: UUID
    /// Quizzes interleave concepts on purpose, so this is a set not a single ID.
    var conceptIDs: [String]
    var startedAt: Date
    var completedAt: Date?
    var items: [QuizItemRecord]
    var usage: UsageStats

    /// Mean item score, 0...1.
    var score: Double {
        guard !items.isEmpty else { return 0 }
        return items.map(\.score).reduce(0, +) / Double(items.count)
    }

    /// Mean signed (confidence − correctness). Positive = overconfident.
    var calibrationGap: Double {
        guard !items.isEmpty else { return 0 }
        let gaps = items.map { $0.confidence.normalized - $0.score }
        return gaps.reduce(0, +) / Double(gaps.count)
    }

    func items(for conceptID: String) -> [QuizItemRecord] {
        items.filter { $0.conceptID == conceptID }
    }

    init(learnerID: UUID, conceptIDs: [String], items: [QuizItemRecord], usage: UsageStats = .zero) {
        self.id = UUID()
        self.learnerID = learnerID
        self.conceptIDs = conceptIDs
        self.startedAt = Date()
        self.completedAt = nil
        self.items = items
        self.usage = usage
    }
}
