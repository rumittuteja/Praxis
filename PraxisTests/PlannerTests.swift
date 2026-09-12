import Testing
import Foundation
@testable import Praxis

@Suite("Session planner")
struct PlannerTests {

    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    // A small synthetic curriculum keeps these tests independent of edits to
    // the real syllabus.
    private func concept(_ id: String, track: String = "t1", tier: Int = 1,
                         requires: [String] = [], minutes: Int = 5) -> Concept {
        Concept(id: id, trackID: track, title: id.capitalized, tier: tier,
                summary: "summary", prerequisites: requires, objectives: ["o"],
                keyIdeas: ["k"], misconceptions: ["m"], practiceKinds: [.explanation],
                sources: [], estimatedMinutes: minutes, requiresAWSAccount: nil)
    }

    private func store(_ concepts: [Concept], tracks: [String] = ["t1"]) -> CurriculumStore {
        CurriculumStore(curriculum: Curriculum(
            version: 1, generatedNote: "",
            tracks: tracks.enumerated().map {
                Track(id: $1, title: $1, summary: "", order: $0)
            },
            concepts: concepts
        ))
    }

    private func mastered(dueIn days: Double) -> ReviewState {
        ReviewState(
            repetitions: 3, easeFactor: 2.5, intervalDays: 6,
            dueDate: now.addingTimeInterval(days * 86_400),
            lastReviewed: now.addingTimeInterval(-6 * 86_400),
            masteryScore: 0.8, attempts: 3, correctCount: 3,
            state: .review
        )
    }

    @Test("A brand new learner gets one new concept and no reviews")
    func firstSession() {
        let planner = SessionPlanner(store: store([concept("a"), concept("b")]))
        let session = planner.plan(PlannerInput(dailyGoalMinutes: 20, progress: [:], now: now))

        #expect(session.reviewConceptIDs.isEmpty)
        #expect(session.newConceptID != nil)
        #expect(!session.quizConceptIDs.isEmpty)
        #expect(session.estimatedMinutes > 0)
    }

    @Test("Locked concepts are never introduced")
    func respectsPrerequisites() {
        let planner = SessionPlanner(store: store([
            concept("basic", tier: 1),
            concept("advanced", tier: 1, requires: ["basic"])
        ]))
        let session = planner.plan(PlannerInput(dailyGoalMinutes: 30, progress: [:], now: now))
        #expect(session.newConceptID == "basic")
    }

    @Test("A concept unlocks once its prerequisite reaches review")
    func unlocksAfterReview() {
        let planner = SessionPlanner(store: store([
            concept("basic", tier: 1),
            concept("advanced", tier: 1, requires: ["basic"])
        ]))
        let session = planner.plan(PlannerInput(
            dailyGoalMinutes: 30,
            progress: ["basic": mastered(dueIn: 5)],
            now: now
        ))
        #expect(session.newConceptID == "advanced")
    }

    @Test("Overdue reviews are ordered most-overdue first")
    func reviewOrdering() {
        let planner = SessionPlanner(store: store([concept("a"), concept("b"), concept("c")]))
        let session = planner.plan(PlannerInput(
            dailyGoalMinutes: 60,
            progress: [
                "a": mastered(dueIn: -1),
                "b": mastered(dueIn: -10),
                "c": mastered(dueIn: -5)
            ],
            now: now
        ))
        #expect(Array(session.reviewConceptIDs.prefix(3)) == ["b", "c", "a"])
    }

    @Test("Concepts not yet due are left out of the warm-up")
    func skipsNotDue() {
        let planner = SessionPlanner(store: store([concept("a"), concept("b")]))
        let session = planner.plan(PlannerInput(
            dailyGoalMinutes: 60,
            progress: ["a": mastered(dueIn: -2), "b": mastered(dueIn: 9)],
            now: now
        ))
        #expect(session.reviewConceptIDs == ["a"])
    }

    @Test("No new concept while too many are already in flight")
    func respectsWorkingMemoryCap() {
        let concepts = (0..<12).map { concept("c\($0)") }
        let planner = SessionPlanner(store: store(concepts))

        var progress: [String: ReviewState] = [:]
        for index in 0..<8 {
            progress["c\(index)"] = ReviewState(
                intervalDays: 1, dueDate: now.addingTimeInterval(86_400),
                lastReviewed: now, masteryScore: 0.3, attempts: 1, state: .learning
            )
        }
        let session = planner.plan(PlannerInput(dailyGoalMinutes: 60, progress: progress, now: now))
        #expect(session.newConceptID == nil, "should not add a 9th concept in flight")
    }

    @Test("A small daily goal drops the task before the reviews")
    func budgetPrioritisesReviews() {
        let planner = SessionPlanner(store: store([concept("a"), concept("b")]))
        let session = planner.plan(PlannerInput(
            dailyGoalMinutes: 5,
            progress: ["a": mastered(dueIn: -3)],
            now: now
        ))
        #expect(!session.reviewConceptIDs.isEmpty)
        #expect(session.taskConceptID == nil)
    }

    @Test("Quizzes interleave the new concept with older ones")
    func quizInterleaves() {
        let planner = SessionPlanner(store: store([
            concept("old1"), concept("old2"), concept("fresh", tier: 2)
        ]))
        let session = planner.plan(PlannerInput(
            dailyGoalMinutes: 60,
            progress: ["old1": mastered(dueIn: 5), "old2": mastered(dueIn: 5)],
            now: now
        ))
        #expect(session.quizConceptIDs.count > 1)
        #expect(session.quizConceptIDs.first == session.newConceptID)
        #expect(session.quizConceptIDs.contains("old1") || session.quizConceptIDs.contains("old2"))
    }

    @Test("New concepts spread across tracks rather than draining one")
    func balancesTracks() {
        let planner = SessionPlanner(store: store([
            concept("a1", track: "t1"), concept("a2", track: "t1"),
            concept("b1", track: "t2")
        ], tracks: ["t1", "t2"]))

        // One concept already started in t1, so t2 should be preferred next.
        let session = planner.plan(PlannerInput(
            dailyGoalMinutes: 60,
            progress: ["a1": mastered(dueIn: 5)],
            now: now
        ))
        #expect(session.newConceptID == "b1")
    }

    @Test("Lower tiers are introduced before higher ones")
    func prefersLowerTier() {
        let planner = SessionPlanner(store: store([
            concept("hard", tier: 4), concept("easy", tier: 1)
        ]))
        let session = planner.plan(PlannerInput(dailyGoalMinutes: 60, progress: [:], now: now))
        #expect(session.newConceptID == "easy")
    }

    @Test("A pure-review day plans no lesson but still plans a quiz")
    func pureReviewDay() {
        // Every concept already started, none available.
        let planner = SessionPlanner(store: store([concept("a")]))
        let session = planner.plan(PlannerInput(
            dailyGoalMinutes: 30,
            progress: ["a": mastered(dueIn: -1)],
            now: now
        ))
        #expect(session.newConceptID == nil)
        #expect(!session.reviewConceptIDs.isEmpty)
        #expect(session.quizConceptIDs.contains("a"))
    }
}

@Suite("Mastery model")
struct MasteryModelTests {

    private func concept(_ id: String, track: String, tier: Int) -> Concept {
        Concept(id: id, trackID: track, title: id, tier: tier, summary: "",
                prerequisites: [], objectives: ["o"], keyIdeas: ["k"],
                misconceptions: ["m"], practiceKinds: [.code], sources: [],
                estimatedMinutes: 5, requiresAWSAccount: nil)
    }

    private var store: CurriculumStore {
        CurriculumStore(curriculum: Curriculum(
            version: 1, generatedNote: "",
            tracks: [Track(id: "t1", title: "One", summary: "", order: 1)],
            concepts: [concept("a", track: "t1", tier: 2), concept("b", track: "t1", tier: 2)]
        ))
    }

    @Test("Track rollups count states correctly")
    func trackSummary() throws {
        let model = MasteryModel(store: store, progress: [
            "a": ReviewState(masteryScore: 0.9, state: .mastered)
        ])
        let summary = try #require(model.trackSummaries().first)
        #expect(summary.total == 2)
        #expect(summary.mastered == 1)
        // Untouched concepts with no prerequisites read as available.
        #expect(summary.available == 1)
    }

    @Test("Task scope never exceeds one tier above the concept")
    func scopeIsBounded() {
        let concepts = store.allConcepts
        let model = MasteryModel(store: store, progress: [
            "a": ReviewState(masteryScore: 1.0, state: .mastered),
            "b": ReviewState(masteryScore: 1.0, state: .mastered)
        ])
        for concept in concepts {
            let scope = model.taskScopeTier(for: concept)
            #expect(scope <= concept.tier + 1)
            #expect(scope <= 5)
            #expect(scope >= concept.tier)
        }
    }

    @Test("Scope starts at the concept's own tier for a beginner")
    func scopeStartsLow() throws {
        let model = MasteryModel(store: store, progress: [:])
        let concept = try #require(store.concept("a"))
        #expect(model.taskScopeTier(for: concept) == concept.tier)
    }

    @Test("Overconfidence is described in plain language")
    func calibrationDescription() {
        let overconfident = MasteryModel(store: store, progress: [
            "a": ReviewState(calibrationBias: 0.5, calibrationSamples: 4, state: .review)
        ])
        #expect(overconfident.calibrationDescription.lowercased().contains("overconfident"))

        let calibrated = MasteryModel(store: store, progress: [
            "a": ReviewState(calibrationBias: 0.0, calibrationSamples: 4, state: .review)
        ])
        #expect(calibrated.calibrationDescription.lowercased().contains("calibrated"))
    }
}
