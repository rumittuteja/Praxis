import Foundation
import SwiftData

/// The steps of a daily session, in the order they're presented.
enum SessionStep: String, Codable, CaseIterable, Sendable {
    /// Retrieval practice on due items, before any new material. Starting with
    /// recall rather than re-reading is the single biggest lever in the app.
    case warmup
    /// New concept: worked example, then explanation.
    case lesson
    /// Interleaved quiz over the new concept plus older ones.
    case quiz
    /// Hands-on task, graded.
    case task
    /// Short written reflection — self-explanation aids transfer.
    case reflection

    /// Localized. `symbol` below is deliberately not — those are SF Symbol
    /// identifiers, not text, and must never be translated.
    var title: String {
        switch self {
        case .warmup:
            return String(localized: "Warm-up", comment: "Session step: retrieval practice on due concepts")
        case .lesson:
            return String(localized: "Today's concept", comment: "Session step: the new lesson")
        case .quiz:
            return String(localized: "Check yourself", comment: "Session step: the quiz")
        case .task:
            return String(localized: "Hands-on", comment: "Session step: the practical task")
        case .reflection:
            return String(localized: "Reflect", comment: "Session step: written reflection")
        }
    }

    var symbol: String {
        switch self {
        case .warmup:     return "arrow.triangle.2.circlepath"
        case .lesson:     return "book"
        case .quiz:       return "checkmark.circle"
        case .task:       return "hammer"
        case .reflection: return "text.quote"
        }
    }
}

/// One day's plan for one learner. Generated lazily on first open of the day
/// and then fixed, so the session doesn't reshuffle underneath the learner.
@Model
final class DailyPlan {
    @Attribute(.unique) var key: String   // "\(learnerID.uuidString)|\(yyyy-MM-dd)"
    var learnerID: UUID
    /// Start of day in the learner's current calendar.
    var day: Date

    /// Due concepts to retrieve, oldest-due first.
    var reviewConceptIDs: [String]
    /// The new concept introduced today, if any. Nil on pure-review days.
    var newConceptID: String?
    /// Concepts the quiz draws from — the new one plus interleaved older ones.
    var quizConceptIDs: [String]
    var taskConceptID: String?

    var estimatedMinutes: Int
    var completedStepsRaw: [String]
    var startedAt: Date?
    var completedAt: Date?

    var completedSteps: Set<SessionStep> {
        get { Set(completedStepsRaw.compactMap(SessionStep.init(rawValue:))) }
        set { completedStepsRaw = newValue.map(\.rawValue) }
    }

    /// Steps actually scheduled today, in order. A day with nothing due skips
    /// the warm-up; a pure-review day skips lesson and task.
    var plannedSteps: [SessionStep] {
        var steps: [SessionStep] = []
        if !reviewConceptIDs.isEmpty { steps.append(.warmup) }
        if newConceptID != nil { steps.append(.lesson) }
        if !quizConceptIDs.isEmpty { steps.append(.quiz) }
        if taskConceptID != nil { steps.append(.task) }
        steps.append(.reflection)
        return steps
    }

    var nextStep: SessionStep? {
        plannedSteps.first { !completedSteps.contains($0) }
    }

    var progressFraction: Double {
        let planned = plannedSteps
        guard !planned.isEmpty else { return 0 }
        let done = planned.filter { completedSteps.contains($0) }.count
        return Double(done) / Double(planned.count)
    }

    var isComplete: Bool { nextStep == nil }

    /// Stable per-day key. Built from calendar components rather than a
    /// `DateFormatter` so there is no shared mutable formatter to race on.
    static func makeKey(learnerID: UUID, day: Date, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: day)
        let year = parts.year ?? 0
        let month = parts.month ?? 0
        let dayOfMonth = parts.day ?? 0
        let stamp = String(format: "%04d-%02d-%02d", year, month, dayOfMonth)
        return "\(learnerID.uuidString)|\(stamp)"
    }

    init(
        learnerID: UUID,
        day: Date,
        reviewConceptIDs: [String],
        newConceptID: String?,
        quizConceptIDs: [String],
        taskConceptID: String?,
        estimatedMinutes: Int,
        calendar: Calendar = .current
    ) {
        self.key = DailyPlan.makeKey(learnerID: learnerID, day: day, calendar: calendar)
        self.learnerID = learnerID
        self.day = calendar.startOfDay(for: day)
        self.reviewConceptIDs = reviewConceptIDs
        self.newConceptID = newConceptID
        self.quizConceptIDs = quizConceptIDs
        self.taskConceptID = taskConceptID
        self.estimatedMinutes = estimatedMinutes
        self.completedStepsRaw = []
        self.startedAt = nil
        self.completedAt = nil
    }
}

/// A learner's written reflection at the end of a session.
@Model
final class Reflection {
    @Attribute(.unique) var id: UUID
    var learnerID: UUID
    var day: Date
    var conceptIDs: [String]
    var promptText: String
    var responseText: String
    var createdAt: Date

    init(learnerID: UUID, day: Date, conceptIDs: [String], promptText: String, responseText: String) {
        self.id = UUID()
        self.learnerID = learnerID
        self.day = day
        self.conceptIDs = conceptIDs
        self.promptText = promptText
        self.responseText = responseText
        self.createdAt = Date()
    }
}
