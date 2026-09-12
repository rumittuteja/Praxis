import Foundation
import SwiftData

/// Where a concept sits in the learner's journey.
enum ConceptState: String, Codable, CaseIterable, Sendable {
    /// Prerequisites not yet met.
    case locked
    /// Unlocked but never studied.
    case available
    /// Seen at least once, mastery still below the review threshold.
    case learning
    /// Mastered enough to leave the daily rotation; resurfaces on schedule.
    case review
    /// Sustained high mastery across spaced repetitions.
    case mastered
}

/// Per-learner, per-concept state. Holds both the SM-2 scheduling fields and
/// the mastery estimate the session planner reads.
@Model
final class ConceptProgress {
    @Attribute(.unique) var key: String   // "\(learnerID.uuidString)|\(conceptID)"
    var learnerID: UUID
    var conceptID: String

    // MARK: SM-2 scheduling state

    /// Consecutive successful reviews. Resets to 0 on a lapse.
    var repetitions: Int
    /// SM-2 ease factor. Starts at 2.5, floors at 1.3.
    var easeFactor: Double
    /// Current inter-review interval in days.
    var intervalDays: Double
    var dueDate: Date?
    var lastReviewed: Date?

    // MARK: Mastery

    /// Exponentially weighted estimate of performance, 0...1. This is what
    /// gates progression, not raw repetition count — someone can repeat a card
    /// five times and still not understand it.
    var masteryScore: Double
    var attempts: Int
    var correctCount: Int

    /// Mean signed gap between stated confidence and actual correctness,
    /// -1...1. Positive means overconfident. Surfacing this is one of the
    /// highest-value things a tutor can do; people rarely notice it alone.
    var calibrationBias: Double
    var calibrationSamples: Int

    var stateRaw: String
    var firstSeen: Date?
    var masteredAt: Date?

    var state: ConceptState {
        get { ConceptState(rawValue: stateRaw) ?? .available }
        set { stateRaw = newValue.rawValue }
    }

    var isDue: Bool {
        guard let dueDate else { return state == .available || state == .learning }
        return dueDate <= Date()
    }

    static func makeKey(learnerID: UUID, conceptID: String) -> String {
        "\(learnerID.uuidString)|\(conceptID)"
    }

    init(learnerID: UUID, conceptID: String, state: ConceptState = .available) {
        self.key = ConceptProgress.makeKey(learnerID: learnerID, conceptID: conceptID)
        self.learnerID = learnerID
        self.conceptID = conceptID
        self.repetitions = 0
        self.easeFactor = 2.5
        self.intervalDays = 0
        self.dueDate = nil
        self.lastReviewed = nil
        self.masteryScore = 0
        self.attempts = 0
        self.correctCount = 0
        self.calibrationBias = 0
        self.calibrationSamples = 0
        self.stateRaw = state.rawValue
        self.firstSeen = nil
        self.masteredAt = nil
    }
}
