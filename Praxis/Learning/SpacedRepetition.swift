import Foundation

/// The scheduling and mastery state for one concept, as a pure value.
///
/// Kept separate from the `ConceptProgress` SwiftData model so the algorithm
/// can be exercised in tests without a model container, and so a scheduling
/// bug can never leave a half-updated managed object behind.
struct ReviewState: Equatable, Sendable {
    var repetitions: Int = 0
    var easeFactor: Double = 2.5
    var intervalDays: Double = 0
    var dueDate: Date?
    var lastReviewed: Date?
    var masteryScore: Double = 0
    var attempts: Int = 0
    var correctCount: Int = 0
    var calibrationBias: Double = 0
    var calibrationSamples: Int = 0
    var state: ConceptState = .available
    var firstSeen: Date?
    var masteredAt: Date?
}

/// SM-2 with two departures from the textbook algorithm, both deliberate:
///
/// 1. **Mastery is tracked separately from repetition count.** Vanilla SM-2
///    treats "answered correctly 4 times" as knowing something. It isn't —
///    a learner can pass four easy recalls and still not be able to apply the
///    idea. Progression gates on the mastery estimate; the interval only
///    decides *when* the question comes back.
///
/// 2. **Confidence is recorded and compared against correctness.** Being
///    wrong while certain is a different failure from being wrong while
///    guessing, and it deserves a shorter interval, because the learner has
///    no internal signal telling them to review it.
enum SpacedRepetition {

    /// Score at or above which a review counts as a pass (SM-2 quality >= 3).
    static let passThreshold = 0.6
    /// Mastery required to leave active learning.
    static let reviewThreshold = 0.7
    /// Mastery required, alongside a long interval, to count as mastered.
    static let masteryThreshold = 0.85
    static let minimumEaseFactor = 1.3
    /// Interval in days a concept must reach before it can be called mastered.
    static let masteryIntervalDays: Double = 21

    /// Apply one graded review.
    ///
    /// - Parameters:
    ///   - state: Current state for this concept.
    ///   - score: Performance on this review, 0...1.
    ///   - confidence: What the learner said before seeing the answer.
    ///   - now: Injected for testability.
    static func review(
        _ state: ReviewState,
        score rawScore: Double,
        confidence: ConfidenceLevel?,
        now: Date = Date()
    ) -> ReviewState {
        var next = state
        let score = min(max(rawScore, 0), 1)
        let quality = score * 5.0
        let passed = score >= passThreshold

        next.attempts += 1
        if passed { next.correctCount += 1 }
        if next.firstSeen == nil { next.firstSeen = now }
        next.lastReviewed = now

        // --- Mastery: exponentially weighted, fast-moving while evidence is
        // thin and progressively more stable as attempts accumulate.
        let weight = max(0.15, 1.0 / Double(next.attempts))
        next.masteryScore = next.masteryScore * (1 - weight) + score * weight

        // --- Calibration: positive means confident-and-wrong.
        if let confidence {
            let gap = confidence.normalized - score
            next.calibrationSamples += 1
            let calWeight = max(0.15, 1.0 / Double(next.calibrationSamples))
            next.calibrationBias = next.calibrationBias * (1 - calWeight) + gap * calWeight
        }

        // --- Ease factor (standard SM-2 curve).
        let delta = 0.1 - (5 - quality) * (0.08 + (5 - quality) * 0.02)
        next.easeFactor = max(minimumEaseFactor, next.easeFactor + delta)

        // --- Interval.
        if passed {
            next.repetitions += 1
            switch next.repetitions {
            case 1:  next.intervalDays = 1
            case 2:  next.intervalDays = 6
            default: next.intervalDays = (next.intervalDays * next.easeFactor).rounded()
            }
            // A confident-but-shaky pass comes back sooner than the raw
            // interval suggests.
            if let confidence, confidence == .guessing {
                next.intervalDays = max(1, next.intervalDays * 0.6)
            }
        } else {
            next.repetitions = 0
            // A lapse the learner *expected* is a smaller setback than one
            // that blindsided them; the latter returns tomorrow regardless.
            let wasOverconfident = (confidence?.rawValue ?? 0) >= ConfidenceLevel.fairlySure.rawValue
            next.intervalDays = wasOverconfident ? 1 : max(1, next.intervalDays * 0.3)
        }

        next.intervalDays = min(next.intervalDays, 365)
        next.dueDate = Calendar.current.date(
            byAdding: .day,
            value: Int(next.intervalDays.rounded()),
            to: now
        ) ?? now.addingTimeInterval(next.intervalDays * 86_400)

        next.state = nextState(for: next, now: now)
        if next.state == .mastered && next.masteredAt == nil {
            next.masteredAt = now
        } else if next.state != .mastered {
            next.masteredAt = nil
        }

        return next
    }

    private static func nextState(for state: ReviewState, now: Date) -> ConceptState {
        if state.masteryScore >= masteryThreshold
            && state.repetitions >= 4
            && state.intervalDays >= masteryIntervalDays {
            return .mastered
        }
        if state.masteryScore >= reviewThreshold && state.repetitions >= 2 {
            return .review
        }
        return .learning
    }

    /// How overdue a concept is, in days. Negative means not yet due.
    /// Used to order the warm-up queue: most-overdue first, because those are
    /// closest to being forgotten outright.
    static func overdueDays(_ state: ReviewState, now: Date = Date()) -> Double {
        guard let dueDate = state.dueDate else { return 0 }
        return now.timeIntervalSince(dueDate) / 86_400
    }

    /// Estimated probability of successful recall right now, from the
    /// exponential forgetting curve, using the current interval as the
    /// stability parameter. Drives the "at risk" list on the progress screen.
    static func retrievability(_ state: ReviewState, now: Date = Date()) -> Double {
        guard let lastReviewed = state.lastReviewed, state.intervalDays > 0 else { return 0 }
        let elapsedDays = now.timeIntervalSince(lastReviewed) / 86_400
        guard elapsedDays > 0 else { return 1 }
        return exp(-elapsedDays / max(state.intervalDays, 0.5))
    }
}

// MARK: - Bridging to the persisted model

extension ConceptProgress {
    var reviewState: ReviewState {
        ReviewState(
            repetitions: repetitions,
            easeFactor: easeFactor,
            intervalDays: intervalDays,
            dueDate: dueDate,
            lastReviewed: lastReviewed,
            masteryScore: masteryScore,
            attempts: attempts,
            correctCount: correctCount,
            calibrationBias: calibrationBias,
            calibrationSamples: calibrationSamples,
            state: state,
            firstSeen: firstSeen,
            masteredAt: masteredAt
        )
    }

    func apply(_ newState: ReviewState) {
        repetitions = newState.repetitions
        easeFactor = newState.easeFactor
        intervalDays = newState.intervalDays
        dueDate = newState.dueDate
        lastReviewed = newState.lastReviewed
        masteryScore = newState.masteryScore
        attempts = newState.attempts
        correctCount = newState.correctCount
        calibrationBias = newState.calibrationBias
        calibrationSamples = newState.calibrationSamples
        state = newState.state
        firstSeen = newState.firstSeen
        masteredAt = newState.masteredAt
    }

    /// Record one graded review against this concept.
    func recordReview(score: Double, confidence: ConfidenceLevel?, now: Date = Date()) {
        apply(SpacedRepetition.review(reviewState, score: score, confidence: confidence, now: now))
    }
}
