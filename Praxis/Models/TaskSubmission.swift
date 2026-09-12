import Foundation
import SwiftData

/// One dimension a hands-on task is judged on. Rubrics are generated with the
/// task and shown to the learner *before* they start — hidden rubrics teach
/// people to guess at what the grader wants instead of at the actual skill.
struct RubricCriterion: Codable, Hashable, Sendable, Identifiable {
    var id: String
    var title: String
    var detail: String
    /// Relative weight within the task. Normalised at scoring time.
    var weight: Double
}

struct RubricScore: Codable, Hashable, Sendable, Identifiable {
    var id: String { criterionID }
    var criterionID: String
    /// 0...1 on this criterion.
    var score: Double
    var justification: String
}

enum SubmissionKind: String, Codable, Sendable {
    /// "Write a prompt that…" — the artifact is a prompt.
    case prompt
    /// "Build/modify…" — the artifact is code or a diff.
    case code
    /// "Run this and report what happened" — the artifact is output plus analysis.
    case investigation
    /// "Explain in your own words" — elaborative interrogation.
    case explanation
}

@Model
final class TaskSubmission {
    @Attribute(.unique) var id: UUID
    var learnerID: UUID
    var conceptID: String

    /// When the task was issued. Needed as a stable sort key: `id` is a UUID
    /// and UUID is not Comparable, and the submitted/graded dates are optional.
    var createdAt: Date

    var kindRaw: String
    var taskTitle: String
    var taskBriefMarkdown: String
    var rubric: [RubricCriterion]
    /// Tier of the concept when the task was issued, so the progression from
    /// "follow these steps" to "here's a goal, figure it out" is auditable.
    var scopeTier: Int

    var submittedText: String
    var submittedAt: Date?

    var gradedAt: Date?
    /// Weighted mean of `rubricScores`, 0...1.
    var overallScore: Double
    var rubricScores: [RubricScore]
    var feedbackMarkdown: String
    var strengths: [String]
    var gaps: [String]
    /// The single most useful next action, per the grader.
    var nextStep: String?

    var usage: UsageStats

    var kind: SubmissionKind { SubmissionKind(rawValue: kindRaw) ?? .explanation }
    var isGraded: Bool { gradedAt != nil }
    /// 0.7 is the pass bar; below that the concept stays in active rotation.
    var passed: Bool { isGraded && overallScore >= 0.7 }

    init(
        learnerID: UUID,
        conceptID: String,
        kind: SubmissionKind,
        taskTitle: String,
        taskBriefMarkdown: String,
        rubric: [RubricCriterion],
        scopeTier: Int
    ) {
        self.id = UUID()
        self.learnerID = learnerID
        self.conceptID = conceptID
        self.createdAt = Date()
        self.kindRaw = kind.rawValue
        self.taskTitle = taskTitle
        self.taskBriefMarkdown = taskBriefMarkdown
        self.rubric = rubric
        self.scopeTier = scopeTier
        self.submittedText = ""
        self.submittedAt = nil
        self.gradedAt = nil
        self.overallScore = 0
        self.rubricScores = []
        self.feedbackMarkdown = ""
        self.strengths = []
        self.gaps = []
        self.nextStep = nil
        self.usage = .zero
    }
}
