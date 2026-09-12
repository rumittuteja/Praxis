import Testing
import Foundation
@testable import Praxis

@Suite("Spaced repetition")
struct SpacedRepetitionTests {

    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    @Test("A first pass schedules one day out")
    func firstPass() {
        let state = SpacedRepetition.review(ReviewState(), score: 0.9, confidence: .fairlySure, now: now)
        #expect(state.repetitions == 1)
        #expect(state.intervalDays == 1)
        #expect(state.attempts == 1)
        #expect(state.correctCount == 1)
        #expect(state.masteryScore > 0.8)
    }

    @Test("Intervals follow SM-2: 1 day, then 6, then ease-scaled")
    func intervalProgression() {
        var state = ReviewState()
        state = SpacedRepetition.review(state, score: 1.0, confidence: .certain, now: now)
        #expect(state.intervalDays == 1)
        state = SpacedRepetition.review(state, score: 1.0, confidence: .certain, now: now)
        #expect(state.intervalDays == 6)
        state = SpacedRepetition.review(state, score: 1.0, confidence: .certain, now: now)
        #expect(state.intervalDays > 6)
        #expect(state.repetitions == 3)
    }

    @Test("A lapse resets the repetition count")
    func lapseResets() {
        var state = ReviewState()
        for _ in 0..<3 {
            state = SpacedRepetition.review(state, score: 1.0, confidence: .certain, now: now)
        }
        #expect(state.repetitions == 3)

        state = SpacedRepetition.review(state, score: 0.1, confidence: .unsure, now: now)
        #expect(state.repetitions == 0)
        #expect(state.intervalDays >= 1)
    }

    @Test("Being wrong while certain returns the card tomorrow")
    func overconfidentLapseIsHarsher() {
        var base = ReviewState()
        for _ in 0..<3 {
            base = SpacedRepetition.review(base, score: 1.0, confidence: .fairlySure, now: now)
        }

        let confidentMiss = SpacedRepetition.review(base, score: 0.2, confidence: .certain, now: now)
        let hedgedMiss = SpacedRepetition.review(base, score: 0.2, confidence: .guessing, now: now)

        #expect(confidentMiss.intervalDays == 1)
        #expect(confidentMiss.intervalDays <= hedgedMiss.intervalDays)
    }

    @Test("Ease factor never drops below the SM-2 floor")
    func easeFactorFloor() {
        var state = ReviewState()
        for _ in 0..<40 {
            state = SpacedRepetition.review(state, score: 0.0, confidence: .guessing, now: now)
        }
        #expect(state.easeFactor >= SpacedRepetition.minimumEaseFactor)
    }

    @Test("Confidence above accuracy registers as overconfidence")
    func calibrationBias() {
        var state = ReviewState()
        for _ in 0..<5 {
            state = SpacedRepetition.review(state, score: 0.2, confidence: .certain, now: now)
        }
        #expect(state.calibrationBias > 0.3)
        #expect(state.calibrationSamples == 5)
    }

    @Test("Accuracy above confidence registers as underconfidence")
    func underconfidence() {
        var state = ReviewState()
        for _ in 0..<5 {
            state = SpacedRepetition.review(state, score: 1.0, confidence: .guessing, now: now)
        }
        #expect(state.calibrationBias < 0)
    }

    @Test("Mastery requires sustained performance, not just repetitions")
    func masteryNeedsMoreThanRepetition() {
        // Scores that pass but only barely should not reach mastered.
        var state = ReviewState()
        for _ in 0..<8 {
            state = SpacedRepetition.review(state, score: 0.62, confidence: .unsure, now: now)
        }
        #expect(state.state != .mastered)
        #expect(state.masteryScore < SpacedRepetition.masteryThreshold)
    }

    @Test("Sustained high performance eventually reaches mastered")
    func masteryReachable() {
        var state = ReviewState()
        var clock = now
        for _ in 0..<10 {
            state = SpacedRepetition.review(state, score: 1.0, confidence: .certain, now: clock)
            clock = state.dueDate ?? clock.addingTimeInterval(86_400)
        }
        #expect(state.state == .mastered)
        #expect(state.masteredAt != nil)
    }

    @Test("Retrievability decays with elapsed time")
    func retrievabilityDecays() {
        var state = ReviewState()
        state = SpacedRepetition.review(state, score: 1.0, confidence: .certain, now: now)
        state = SpacedRepetition.review(state, score: 1.0, confidence: .certain, now: now)

        let sameDay = SpacedRepetition.retrievability(state, now: now)
        let muchLater = SpacedRepetition.retrievability(state, now: now.addingTimeInterval(86_400 * 30))
        #expect(sameDay > muchLater)
        #expect(muchLater < 0.2)
    }

    @Test("Intervals are capped so nothing disappears for years")
    func intervalCap() {
        var state = ReviewState()
        var clock = now
        for _ in 0..<30 {
            state = SpacedRepetition.review(state, score: 1.0, confidence: .certain, now: clock)
            clock = state.dueDate ?? clock
        }
        #expect(state.intervalDays <= 365)
    }
}

@Suite("Streaks")
struct StreakTests {
    private let calendar = Calendar(identifier: .gregorian)
    private func day(_ offset: Int) -> Date {
        Date(timeIntervalSince1970: 1_700_000_000).addingTimeInterval(Double(offset) * 86_400)
    }

    @Test("First completion starts a streak of one")
    func firstCompletion() {
        let result = StreakTracker.recordCompletion(
            on: day(0), lastCompletedDay: nil, currentStreak: 0, longestStreak: 0, calendar: calendar)
        #expect(result.streak == 1)
        #expect(result.longest == 1)
    }

    @Test("Consecutive days extend the streak")
    func consecutive() {
        let result = StreakTracker.recordCompletion(
            on: day(1), lastCompletedDay: day(0), currentStreak: 3, longestStreak: 5, calendar: calendar)
        #expect(result.streak == 4)
        #expect(result.longest == 5)
    }

    @Test("A second session the same day does not double count")
    func sameDay() {
        let result = StreakTracker.recordCompletion(
            on: day(0), lastCompletedDay: day(0), currentStreak: 3, longestStreak: 5, calendar: calendar)
        #expect(result.streak == 3)
    }

    @Test("A missed day resets the streak")
    func gapResets() {
        let result = StreakTracker.recordCompletion(
            on: day(3), lastCompletedDay: day(0), currentStreak: 7, longestStreak: 7, calendar: calendar)
        #expect(result.streak == 1)
        #expect(result.longest == 7)
    }
}
