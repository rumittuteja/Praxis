import Foundation

/// Aggregate view of one track's progress, for the map screen.
struct TrackSummary: Identifiable, Sendable {
    var id: String { trackID }
    var trackID: String
    var title: String
    var total: Int
    var mastered: Int
    var inReview: Int
    var learning: Int
    var available: Int
    var locked: Int
    /// Mean mastery across every concept in the track, counting untouched
    /// ones as zero — so this reads as "how far through the track am I",
    /// not "how well am I doing on the bits I've tried".
    var meanMastery: Double

    var startedCount: Int { mastered + inReview + learning }
    var completionFraction: Double { total == 0 ? 0 : Double(mastered) / Double(total) }
}

/// A concept the learner is likely to have forgotten.
struct AtRiskConcept: Identifiable, Sendable {
    var id: String { conceptID }
    var conceptID: String
    var title: String
    var trackID: String
    /// Estimated probability of recalling it right now, 0...1.
    var retrievability: Double
    var daysOverdue: Double
}

/// Derived, read-only analysis over the progress graph. Everything here is a
/// pure function of `[conceptID: ReviewState]` plus the curriculum.
struct MasteryModel: Sendable {

    let store: CurriculumStore
    let progress: [String: ReviewState]

    init(store: CurriculumStore, progress: [String: ReviewState]) {
        self.store = store
        self.progress = progress
    }

    // MARK: Track rollups

    func trackSummaries() -> [TrackSummary] {
        store.tracks.map { track in
            let concepts = store.concepts(inTrack: track.id)
            var counts: [ConceptState: Int] = [:]
            var masterySum = 0.0

            let satisfied = Set(progress.compactMap { id, state in
                (state.state == .review || state.state == .mastered) ? id : nil
            })

            for concept in concepts {
                let state = progress[concept.id]
                masterySum += state?.masteryScore ?? 0
                let resolved = state?.state
                    ?? (store.prerequisitesMet(for: concept, given: satisfied) ? .available : .locked)
                counts[resolved, default: 0] += 1
            }

            return TrackSummary(
                trackID: track.id,
                title: track.title,
                total: concepts.count,
                mastered: counts[.mastered] ?? 0,
                inReview: counts[.review] ?? 0,
                learning: counts[.learning] ?? 0,
                available: counts[.available] ?? 0,
                locked: counts[.locked] ?? 0,
                meanMastery: concepts.isEmpty ? 0 : masterySum / Double(concepts.count)
            )
        }
    }

    // MARK: Headline numbers

    var conceptsMastered: Int {
        progress.values.filter { $0.state == .mastered }.count
    }

    var conceptsStarted: Int {
        progress.values.filter { $0.state != .available && $0.state != .locked }.count
    }

    var overallMastery: Double {
        let total = store.allConcepts.count
        guard total > 0 else { return 0 }
        let sum = store.allConcepts.reduce(0.0) { $0 + (progress[$1.id]?.masteryScore ?? 0) }
        return sum / Double(total)
    }

    /// Mean calibration bias across everything with samples. Positive means
    /// the learner is systematically more confident than they should be.
    var calibrationBias: Double {
        let sampled = progress.values.filter { $0.calibrationSamples > 0 }
        guard !sampled.isEmpty else { return 0 }
        return sampled.reduce(0.0) { $0 + $1.calibrationBias } / Double(sampled.count)
    }

    /// Plain-language reading of the calibration number, since a signed
    /// decimal means nothing to most people.
    var calibrationDescription: String {
        let bias = calibrationBias
        switch bias {
        case ..<(-0.2):  return "You underrate yourself — you're right more often than you expect."
        case (-0.2)..<0.1: return "Well calibrated. Your confidence tracks your accuracy."
        case 0.1..<0.25: return "Slightly overconfident on a few topics."
        default:         return "Overconfident: you're often certain on answers you get wrong."
        }
    }

    // MARK: At-risk

    /// Concepts most likely to have decayed, worst first.
    func atRisk(limit: Int = 5, now: Date = Date()) -> [AtRiskConcept] {
        progress
            .filter { $0.value.state == .review || $0.value.state == .mastered }
            .compactMap { id, state in
                guard let concept = store.concept(id) else { return nil }
                return AtRiskConcept(
                    conceptID: id,
                    title: concept.title,
                    trackID: concept.trackID,
                    retrievability: SpacedRepetition.retrievability(state, now: now),
                    daysOverdue: SpacedRepetition.overdueDays(state, now: now)
                )
            }
            .filter { $0.retrievability < 0.8 }
            .sorted { $0.retrievability < $1.retrievability }
            .prefix(limit)
            .map { $0 }
    }

    var dueCount: Int {
        let now = Date()
        return progress.values.filter { state in
            guard state.state != .available && state.state != .locked else { return false }
            guard let dueDate = state.dueDate else { return true }
            return dueDate <= now
        }.count
    }

    // MARK: Task scope

    /// How much scaffolding today's task should carry, 1...5.
    ///
    /// This is the "scope grows with knowledge" rule made concrete. A concept's
    /// own tier sets the floor; demonstrated mastery on it and on the track
    /// around it raises the ceiling. The generator turns this number into the
    /// difference between "follow these five steps" and "here's a goal and a
    /// constraint, go".
    func taskScopeTier(for concept: Concept) -> Int {
        let own = progress[concept.id]?.masteryScore ?? 0
        let trackConcepts = store.concepts(inTrack: concept.trackID)
        let trackMastery = trackConcepts.isEmpty ? 0 : trackConcepts.reduce(0.0) {
            $0 + (progress[$1.id]?.masteryScore ?? 0)
        } / Double(trackConcepts.count)

        var scope = concept.tier
        if own >= 0.7 { scope += 1 }
        if trackMastery >= 0.6 { scope += 1 }
        // Never jump more than one tier above the concept's own difficulty:
        // desirable difficulty stops being desirable when it's just unfair.
        return min(min(scope, concept.tier + 1), 5)
    }
}

// MARK: - Streaks

enum StreakTracker {

    /// Update a learner's streak after finishing a session.
    ///
    /// Same-day repeats don't double-count; a one-day gap continues the
    /// streak's spirit only if it's literally yesterday, otherwise it resets.
    static func recordCompletion(
        on day: Date,
        lastCompletedDay: Date?,
        currentStreak: Int,
        longestStreak: Int,
        calendar: Calendar = .current
    ) -> (streak: Int, longest: Int, day: Date) {
        let today = calendar.startOfDay(for: day)

        guard let last = lastCompletedDay.map({ calendar.startOfDay(for: $0) }) else {
            return (1, max(longestStreak, 1), today)
        }
        if last == today {
            return (currentStreak, longestStreak, today)
        }
        let gap = calendar.dateComponents([.day], from: last, to: today).day ?? 0
        let streak = gap == 1 ? currentStreak + 1 : 1
        return (streak, max(longestStreak, streak), today)
    }
}
