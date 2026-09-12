import Foundation

/// Everything the planner needs, as plain values.
struct PlannerInput: Sendable {
    var dailyGoalMinutes: Int
    /// Concept ID -> current state. Concepts absent from this map have never
    /// been touched.
    var progress: [String: ReviewState]
    var now: Date = Date()
}

/// The shape of one day's work.
struct PlannedSession: Equatable, Sendable {
    var reviewConceptIDs: [String] = []
    var newConceptID: String?
    var quizConceptIDs: [String] = []
    var taskConceptID: String?
    var estimatedMinutes: Int = 0

    var isEmpty: Bool {
        reviewConceptIDs.isEmpty && newConceptID == nil
            && quizConceptIDs.isEmpty && taskConceptID == nil
    }
}

/// Builds the daily session.
///
/// The ordering rules encode the pedagogy:
///
/// - **Due reviews come before new material.** Retrieval of things on the edge
///   of being forgotten is where the learning actually happens; new content is
///   the reward, not the point.
/// - **At most one new concept a day.** Volume is the enemy of retention, and
///   a cap keeps the review queue from compounding faster than it drains.
/// - **A ceiling on concepts in flight.** Past roughly seven partially-learned
///   ideas, everything degrades. New material stops until the backlog clears.
/// - **Quizzes interleave.** Mixing the new concept with older ones is harder
///   in the moment and measurably better for retention and discrimination than
///   blocking practice on one topic.
struct SessionPlanner: Sendable {

    let store: CurriculumStore

    /// Concepts in `.learning` beyond which no new concept is introduced.
    var maxConceptsInFlight = 7
    /// Hard cap on warm-up items regardless of available time.
    var maxReviewItems = 12
    /// Older concepts mixed into the quiz alongside today's.
    var interleavedQuizConcepts = 3

    // Rough per-activity costs, in minutes.
    private let minutesPerReviewItem = 1.5
    private let minutesPerQuiz = 4.0
    private let minutesPerTask = 8.0

    init(store: CurriculumStore) {
        self.store = store
    }

    func plan(_ input: PlannerInput) -> PlannedSession {
        var session = PlannedSession()
        var budget = Double(input.dailyGoalMinutes)

        // --- 1. Due reviews, most overdue first.
        let due = dueConcepts(input)
        let affordableReviews = max(1, Int(budget * 0.4 / minutesPerReviewItem))
        session.reviewConceptIDs = Array(due.prefix(min(maxReviewItems, affordableReviews)))
        budget -= Double(session.reviewConceptIDs.count) * minutesPerReviewItem

        // --- 2. A new concept, if there's room in the day and in the head.
        let inFlight = input.progress.values.filter { $0.state == .learning }.count
        if inFlight < maxConceptsInFlight, let candidate = nextNewConcept(input) {
            if budget >= Double(candidate.estimatedMinutes) + minutesPerQuiz {
                session.newConceptID = candidate.id
                budget -= Double(candidate.estimatedMinutes)
            }
        }

        // --- 3. Quiz: today's concept plus interleaved older ones.
        if budget >= minutesPerQuiz {
            session.quizConceptIDs = quizConcepts(input, newConceptID: session.newConceptID)
            if !session.quizConceptIDs.isEmpty { budget -= minutesPerQuiz }
        }

        // --- 4. Hands-on task.
        if budget >= minutesPerTask {
            session.taskConceptID = taskConcept(input, newConceptID: session.newConceptID)
            if session.taskConceptID != nil { budget -= minutesPerTask }
        }

        session.estimatedMinutes = estimateMinutes(session)
        return session
    }

    // MARK: Steps

    /// Concepts due for review, most overdue first. Ties break toward lower
    /// mastery, so shakier material surfaces earlier in the warm-up.
    private func dueConcepts(_ input: PlannerInput) -> [String] {
        input.progress
            .filter { _, state in
                guard state.state == .learning || state.state == .review || state.state == .mastered
                else { return false }
                guard let dueDate = state.dueDate else { return true }
                return dueDate <= input.now
            }
            .sorted { lhs, rhs in
                let lhsOverdue = SpacedRepetition.overdueDays(lhs.value, now: input.now)
                let rhsOverdue = SpacedRepetition.overdueDays(rhs.value, now: input.now)
                if abs(lhsOverdue - rhsOverdue) > 0.01 { return lhsOverdue > rhsOverdue }
                return lhs.value.masteryScore < rhs.value.masteryScore
            }
            .map(\.key)
    }

    /// The next concept to introduce.
    ///
    /// Among everything unlocked and untouched, prefer the lowest tier, then
    /// the track the learner has advanced *least* far in. Spreading attention
    /// across tracks rather than draining one at a time gives the interleaved
    /// quizzes something to work with and keeps the AWS material moving
    /// alongside the prompting material instead of after it.
    func nextNewConcept(_ input: PlannerInput) -> Concept? {
        let satisfied = satisfiedConceptIDs(input)
        let startedPerTrack = startedCountByTrack(input)

        let candidates = store.unlockedConcepts(given: satisfied).filter { concept in
            let state = input.progress[concept.id]?.state
            return state == nil || state == .available || state == .locked
        }

        return candidates.min { lhs, rhs in
            if lhs.tier != rhs.tier { return lhs.tier < rhs.tier }
            let lhsStarted = startedPerTrack[lhs.trackID] ?? 0
            let rhsStarted = startedPerTrack[rhs.trackID] ?? 0
            if lhsStarted != rhsStarted { return lhsStarted < rhsStarted }
            let lhsOrder = store.track(lhs.trackID)?.order ?? .max
            let rhsOrder = store.track(rhs.trackID)?.order ?? .max
            if lhsOrder != rhsOrder { return lhsOrder < rhsOrder }
            return lhs.id < rhs.id
        }
    }

    /// Today's concept plus the weakest older ones, so the quiz forces the
    /// learner to discriminate between similar ideas rather than pattern-match
    /// to whatever they just read.
    private func quizConcepts(_ input: PlannerInput, newConceptID: String?) -> [String] {
        var selected: [String] = []
        if let newConceptID { selected.append(newConceptID) }

        let older = input.progress
            .filter { id, state in
                id != newConceptID && (state.state == .learning || state.state == .review || state.state == .mastered)
            }
            .sorted { lhs, rhs in
                let lhsRisk = SpacedRepetition.retrievability(lhs.value, now: input.now)
                let rhsRisk = SpacedRepetition.retrievability(rhs.value, now: input.now)
                if abs(lhsRisk - rhsRisk) > 0.001 { return lhsRisk < rhsRisk }
                return lhs.value.masteryScore < rhs.value.masteryScore
            }
            .map(\.key)

        selected.append(contentsOf: older.prefix(interleavedQuizConcepts))
        return selected
    }

    /// Today's concept if it supports hands-on work, otherwise the weakest
    /// concept currently being learned — the one most in need of application.
    private func taskConcept(_ input: PlannerInput, newConceptID: String?) -> String? {
        if let newConceptID, let concept = store.concept(newConceptID), !concept.practiceKinds.isEmpty {
            return newConceptID
        }
        return input.progress
            .filter { $0.value.state == .learning }
            .min { $0.value.masteryScore < $1.value.masteryScore }?
            .key
    }

    // MARK: Helpers

    /// Concepts whose prerequisites count as met: mastery is good enough to
    /// build on, which is `.review` or better — not full mastery, or the tree
    /// would barely open.
    func satisfiedConceptIDs(_ input: PlannerInput) -> Set<String> {
        Set(input.progress.compactMap { id, state in
            (state.state == .review || state.state == .mastered) ? id : nil
        })
    }

    private func startedCountByTrack(_ input: PlannerInput) -> [String: Int] {
        var counts: [String: Int] = [:]
        for (id, state) in input.progress where state.state != .available && state.state != .locked {
            guard let concept = store.concept(id) else { continue }
            counts[concept.trackID, default: 0] += 1
        }
        return counts
    }

    private func estimateMinutes(_ session: PlannedSession) -> Int {
        var total = Double(session.reviewConceptIDs.count) * minutesPerReviewItem
        if let newConceptID = session.newConceptID {
            total += Double(store.concept(newConceptID)?.estimatedMinutes ?? 6)
        }
        if !session.quizConceptIDs.isEmpty { total += minutesPerQuiz }
        if session.taskConceptID != nil { total += minutesPerTask }
        total += 1  // reflection
        return max(1, Int(total.rounded()))
    }
}
