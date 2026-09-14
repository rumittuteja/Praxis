import Foundation
import Observation
import SwiftData

/// One warm-up card: recall the concept, then self-rate.
///
/// Deliberately free of model calls. Retrieval practice is the highest-value
/// part of the session and it should never be gated on the network, a rate
/// limit, or a per-card token cost.
struct WarmupItem: Identifiable, Sendable {
    var id: String { conceptID }
    var conceptID: String
    var title: String
    var trackID: String
    var prompt: String
    /// Shown only after the learner has attempted recall.
    var reveal: [String]
}

/// How well the learner judged their own recall, after seeing the answer.
enum RecallRating: String, CaseIterable, Identifiable, Sendable {
    case again, hard, good, easy

    var id: String { rawValue }

    var label: String {
        switch self {
        case .again:
            return String(localized: "Blank", comment: "Self-rated recall: nothing came back")
        case .hard:
            return String(localized: "Shaky", comment: "Self-rated recall: got the gist, missed the substance")
        case .good:
            return String(localized: "Got it", comment: "Self-rated recall: solid")
        case .easy:
            return String(localized: "Easy", comment: "Self-rated recall: immediate and complete")
        }
    }

    var score: Double {
        switch self {
        case .again: return 0.15
        case .hard:  return 0.5
        case .good:  return 0.8
        case .easy:  return 1.0
        }
    }
}

/// Drives one day's session: builds the plan, generates content on demand,
/// records outcomes, and advances the step machine.
@MainActor
@Observable
final class SessionCoordinator {

    // MARK: State

    private(set) var plan: DailyPlan?
    private(set) var lesson: LessonRecord?
    private(set) var quiz: QuizAttempt?
    private(set) var task: TaskSubmission?
    private(set) var warmupItems: [WarmupItem] = []

    /// Live reasoning summary shown while a generation is in flight.
    private(set) var thinking: String = ""
    private(set) var busyMessage: String?
    var errorMessage: String?

    var isBusy: Bool { busyMessage != nil }

    /// Whether to show token accounting inline, per the learner's setting.
    var showsUsage: Bool { learner.showsRequestInspector }

    var providerName: String { learner.preferredProvider.displayName }

    // MARK: Dependencies

    private let env: AppEnvironment
    private let repository: LearningRepository
    private let learner: Learner

    init(env: AppEnvironment, repository: LearningRepository, learner: Learner) {
        self.env = env
        self.repository = repository
        self.learner = learner
    }

    // MARK: - Plan

    /// Load today's plan, creating it on first open of the day.
    func loadToday(now: Date = Date()) {
        if let existing = repository.plan(learnerID: learner.id, day: now) {
            plan = existing
        } else {
            let planned = env.planner().plan(PlannerInput(
                dailyGoalMinutes: learner.dailyGoalMinutes,
                progress: repository.progressMap(for: learner.id),
                now: now
            ))
            let created = DailyPlan(
                learnerID: learner.id,
                day: now,
                reviewConceptIDs: planned.reviewConceptIDs,
                newConceptID: planned.newConceptID,
                quizConceptIDs: planned.quizConceptIDs,
                taskConceptID: planned.taskConceptID,
                estimatedMinutes: planned.estimatedMinutes
            )
            repository.insert(created)
            plan = created
        }

        if plan?.startedAt == nil { plan?.startedAt = now }
        rebuildWarmup()
        lesson = plan?.newConceptID.flatMap { repository.lesson(learnerID: learner.id, conceptID: $0) }
        task = plan?.taskConceptID.flatMap {
            repository.pendingSubmission(learnerID: learner.id, conceptID: $0)
        }
        repository.save()
    }

    private func rebuildWarmup() {
        guard let plan else { warmupItems = []; return }
        warmupItems = plan.reviewConceptIDs.compactMap { conceptID in
            guard let concept = env.curriculum.concept(conceptID) else { return nil }
            // Prefer the takeaways from the lesson this learner actually read;
            // fall back to the syllabus key ideas if it was never generated.
            let stored = repository.lesson(learnerID: learner.id, conceptID: conceptID)
            let reveal = (stored?.keyTakeaways).flatMap { $0.isEmpty ? nil : $0 } ?? concept.keyIdeas
            return WarmupItem(
                conceptID: conceptID,
                title: concept.title,
                trackID: concept.trackID,
                prompt: "Without looking: what is \(concept.title.lowercased()), and when does it matter?",
                reveal: reveal
            )
        }
    }

    // MARK: - Warm-up

    func recordWarmup(conceptID: String, rating: RecallRating) {
        let progress = repository.progress(learnerID: learner.id, conceptID: conceptID)
        // No confidence is recorded here: the learner rates after seeing the
        // answer, which measures recall, not calibration. Calibration comes
        // from the quiz, where confidence is stated before the reveal.
        progress.recordReview(score: rating.score, confidence: nil)
        repository.save()
    }

    func finishWarmup() { complete(.warmup) }

    // MARK: - Lesson

    func loadLesson() async {
        guard let conceptID = plan?.newConceptID,
              let concept = env.curriculum.concept(conceptID) else { return }
        if lesson != nil { return }

        await run("Writing today's lesson") { tutor, mastery, calibration in
            let excerpts = self.env.retriever.excerpts(for: concept, in: self.repository.corpus())
            let result = try await tutor.generateLesson(
                concept: concept,
                trackTitle: self.env.curriculum.trackTitle(concept.trackID),
                learner: self.learner,
                mastery: mastery,
                calibration: calibration,
                excerpts: excerpts,
                onThinking: { [weak self] chunk in
                    Task { @MainActor in self?.thinking += chunk }
                }
            )

            let citations = result.payload.citedSourceURLs.compactMap { url in
                concept.sources.first { $0.url == url }
                    .map { SourceCitation(title: $0.title, url: $0.url, excerpt: nil) }
            }
            let record = LessonRecord(
                learnerID: self.learner.id,
                conceptID: conceptID,
                title: result.payload.title,
                workedExampleMarkdown: result.payload.workedExample,
                bodyMarkdown: result.payload.body,
                keyTakeaways: result.payload.keyTakeaways,
                addressedMisconception: result.payload.addressedMisconception,
                citations: citations,
                modelID: result.modelID,
                provider: result.provider,
                usage: result.usage,
                latencySeconds: result.latencySeconds
            )
            self.repository.insert(record)
            self.lesson = record

            // First contact with a concept moves it out of `available`.
            let progress = self.repository.progress(learnerID: self.learner.id, conceptID: conceptID)
            if progress.firstSeen == nil {
                progress.firstSeen = Date()
                progress.state = .learning
            }
            self.repository.save()
            return ("Lesson: \(concept.title)", result.usage, result.latencySeconds, result.modelID, result.provider)
        }
    }

    func markLessonRead() {
        lesson?.readAt = Date()
        repository.save()
        complete(.lesson)
    }

    // MARK: - Quiz

    func loadQuiz() async {
        guard let plan, !plan.quizConceptIDs.isEmpty, quiz == nil else { return }
        let concepts = plan.quizConceptIDs.compactMap { env.curriculum.concept($0) }
        guard !concepts.isEmpty else { return }

        // Enough items to cover the new concept properly and still interleave.
        let itemCount = min(8, max(4, concepts.count + 2))

        await run("Writing your quiz") { tutor, mastery, calibration in
            var excerpts: [RetrievedExcerpt] = []
            let corpus = self.repository.corpus()
            for concept in concepts.prefix(2) {
                excerpts.append(contentsOf: self.env.retriever.excerpts(for: concept, in: corpus))
            }

            let result = try await tutor.generateQuiz(
                concepts: concepts,
                newConceptID: plan.newConceptID,
                itemCount: itemCount,
                learner: self.learner,
                mastery: mastery,
                calibration: calibration,
                excerpts: excerpts
            )

            let items = result.payload.items.map { generated in
                QuizItemRecord(
                    id: UUID(),
                    conceptID: generated.conceptID,
                    kindRaw: generated.kind,
                    prompt: generated.prompt,
                    options: generated.options,
                    correctIndices: generated.correctIndices,
                    expectedAnswer: generated.expectedAnswer.isEmpty ? nil : generated.expectedAnswer,
                    selectedIndices: [],
                    writtenAnswer: nil,
                    confidenceRaw: ConfidenceLevel.unsure.rawValue,
                    score: 0,
                    explanation: generated.explanation,
                    feedback: nil
                )
            }
            let attempt = QuizAttempt(
                learnerID: self.learner.id,
                conceptIDs: plan.quizConceptIDs,
                items: items,
                usage: result.usage
            )
            self.repository.insert(attempt)
            self.quiz = attempt
            return ("Quiz: \(concepts.count) concepts", result.usage, result.latencySeconds, result.modelID, result.provider)
        }
    }

    /// Record one answer as the learner works through the quiz.
    func answer(itemID: UUID, selected: [Int], written: String?, confidence: ConfidenceLevel) {
        guard let quiz, let index = quiz.items.firstIndex(where: { $0.id == itemID }) else { return }
        var item = quiz.items[index]
        item.selectedIndices = selected
        item.writtenAnswer = written
        item.confidenceRaw = confidence.rawValue
        item.score = Self.localScore(for: item)
        quiz.items[index] = item
        repository.save()
    }

    /// Score everything that can be scored without a model call.
    ///
    /// Multiple-select uses Jaccard overlap so a near-miss earns partial
    /// credit; an all-or-nothing rule there punishes one wrong tick as harshly
    /// as answering at random.
    nonisolated static func localScore(for item: QuizItemRecord) -> Double {
        switch item.kind {
        case .multipleChoice:
            guard let selected = item.selectedIndices.first, item.selectedIndices.count == 1 else { return 0 }
            return item.correctIndices.contains(selected) ? 1 : 0
        case .multipleSelect:
            let correct = Set(item.correctIndices)
            let chosen = Set(item.selectedIndices)
            guard !correct.isEmpty || !chosen.isEmpty else { return 0 }
            let union = correct.union(chosen).count
            guard union > 0 else { return 1 }
            return Double(correct.intersection(chosen).count) / Double(union)
        case .shortAnswer, .critique, .prediction:
            // Graded by the model in `finishQuiz`.
            return 0
        }
    }

    /// Grade free-text answers, then fold every item into concept mastery.
    func finishQuiz() async {
        guard let quiz else { return }

        let freeText = quiz.items.enumerated().compactMap { index, item -> (Int, String, String, String)? in
            switch item.kind {
            case .shortAnswer, .critique, .prediction:
                let answer = item.writtenAnswer?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                guard !answer.isEmpty else { return nil }
                return (index, item.prompt, item.expectedAnswer ?? "", answer)
            default:
                return nil
            }
        }

        if !freeText.isEmpty {
            await run("Marking your answers") { tutor, _, _ in
                let result = try await tutor.gradeShortAnswers(
                    items: freeText.map { (index: $0.0, prompt: $0.1, expected: $0.2, answer: $0.3) },
                    learner: self.learner
                )
                for grade in result.payload.grades where quiz.items.indices.contains(grade.index) {
                    var item = quiz.items[grade.index]
                    item.score = min(max(grade.score, 0), 1)
                    item.feedback = grade.feedback
                    quiz.items[grade.index] = item
                }
                return ("Short-answer grading", result.usage, result.latencySeconds, result.modelID, result.provider)
            }
        }

        // Fold results into per-concept mastery. Items for the same concept are
        // averaged so a concept with three questions isn't weighted triple.
        let byConcept = Dictionary(grouping: quiz.items, by: \.conceptID)
        for (conceptID, items) in byConcept {
            let meanScore = items.map(\.score).reduce(0, +) / Double(items.count)
            let meanConfidence = items.map { $0.confidence.rawValue }.reduce(0, +) / max(1, items.count)
            let progress = repository.progress(learnerID: learner.id, conceptID: conceptID)
            progress.recordReview(
                score: meanScore,
                confidence: ConfidenceLevel(rawValue: meanConfidence) ?? .unsure
            )
        }

        quiz.completedAt = Date()
        repository.save()
        complete(.quiz)
    }

    // MARK: - Task

    func loadTask() async {
        guard let conceptID = plan?.taskConceptID,
              let concept = env.curriculum.concept(conceptID),
              task == nil else { return }

        let mastery = MasteryModel(
            store: env.curriculum,
            progress: repository.progressMap(for: learner.id)
        )
        let scopeTier = mastery.taskScopeTier(for: concept)

        await run("Designing your task") { tutor, overallMastery, calibration in
            let excerpts = self.env.retriever.excerpts(for: concept, in: self.repository.corpus())
            let result = try await tutor.generateTask(
                concept: concept,
                trackTitle: self.env.curriculum.trackTitle(concept.trackID),
                scopeTier: scopeTier,
                learner: self.learner,
                mastery: overallMastery,
                calibration: calibration,
                hasAWSAccount: self.env.credentials.hasAWSCredentials,
                excerpts: excerpts,
                onThinking: { [weak self] chunk in
                    Task { @MainActor in self?.thinking += chunk }
                }
            )

            let submission = TaskSubmission(
                learnerID: self.learner.id,
                conceptID: conceptID,
                kind: SubmissionKind(rawValue: result.payload.kind) ?? .explanation,
                taskTitle: result.payload.title,
                taskBriefMarkdown: result.payload.briefMarkdown,
                rubric: result.payload.rubric.map {
                    RubricCriterion(id: $0.id, title: $0.title, detail: $0.detail, weight: $0.weight)
                },
                scopeTier: scopeTier
            )
            submission.usage = result.usage
            self.repository.insert(submission)
            self.task = submission
            return ("Task: \(concept.title)", result.usage, result.latencySeconds, result.modelID, result.provider)
        }
    }

    func submitTask(_ text: String) async {
        guard let task, let concept = env.curriculum.concept(task.conceptID) else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            errorMessage = "Add your work before submitting."
            return
        }

        task.submittedText = trimmed
        task.submittedAt = Date()
        repository.save()

        await run("Grading your work") { tutor, mastery, calibration in
            let result = try await tutor.grade(
                submission: task,
                concept: concept,
                learner: self.learner,
                mastery: mastery,
                calibration: calibration,
                onThinking: { [weak self] chunk in
                    Task { @MainActor in self?.thinking += chunk }
                }
            )

            task.rubricScores = result.payload.rubricScores.map {
                RubricScore(criterionID: $0.criterionID, score: $0.score, justification: $0.justification)
            }
            task.overallScore = result.payload.overallScore
            task.feedbackMarkdown = result.payload.feedbackMarkdown
            task.strengths = result.payload.strengths
            task.gaps = result.payload.gaps
            task.nextStep = result.payload.nextStep
            task.gradedAt = Date()
            task.usage = task.usage + result.usage

            // A graded task is applied work, so it carries more weight than a
            // quiz item — it is recorded as its own review of the concept.
            let progress = self.repository.progress(learnerID: self.learner.id, conceptID: task.conceptID)
            progress.recordReview(score: result.payload.overallScore, confidence: nil)
            self.repository.save()
            return ("Grading: \(concept.title)", result.usage, result.latencySeconds, result.modelID, result.provider)
        }

        if task.isGraded { complete(.task) }
    }

    // MARK: - Reflection

    var reflectionPrompt: String {
        let concepts = (plan?.quizConceptIDs ?? []).compactMap { env.curriculum.concept($0) }
        return Prompts.reflectionPrompt(concepts: concepts)
    }

    func saveReflection(_ text: String) {
        guard let plan else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            repository.insert(Reflection(
                learnerID: learner.id,
                day: plan.day,
                conceptIDs: plan.quizConceptIDs,
                promptText: reflectionPrompt,
                responseText: trimmed
            ))
        }
        complete(.reflection)
    }

    // MARK: - Step machine

    func complete(_ step: SessionStep) {
        guard let plan else { return }
        var steps = plan.completedSteps
        steps.insert(step)
        plan.completedSteps = steps

        if plan.isComplete && plan.completedAt == nil {
            plan.completedAt = Date()
            let result = StreakTracker.recordCompletion(
                on: plan.day,
                lastCompletedDay: learner.lastCompletedDay,
                currentStreak: learner.currentStreak,
                longestStreak: learner.longestStreak
            )
            learner.currentStreak = result.streak
            learner.longestStreak = result.longest
            learner.lastCompletedDay = result.day
            learner.totalSessionsCompleted += 1
            learner.totalStudyMinutes += plan.estimatedMinutes
        }
        repository.save()
    }

    // MARK: - Generation plumbing

    /// Run one generation with shared busy state, logging, and error mapping.
    ///
    /// The closure returns the metadata to log, so every model call in the app
    /// lands in the request inspector without each call site remembering to.
    private func run(
        _ message: String,
        _ body: @escaping (TutorService, Double, String) async throws
            -> (String, UsageStats, Double, String, ProviderKind)
    ) async {
        busyMessage = message
        thinking = ""
        errorMessage = nil
        defer { busyMessage = nil }

        do {
            let tutor = try env.tutor(for: learner)
            let mastery = MasteryModel(
                store: env.curriculum,
                progress: repository.progressMap(for: learner.id)
            )
            let (purpose, usage, latency, model, provider) = try await body(
                tutor, mastery.overallMastery, mastery.calibrationDescription
            )
            env.log(purpose: purpose, provider: provider, model: model, usage: usage, latency: latency)
        } catch let error as LLMError {
            if case .cancelled = error { return }
            errorMessage = error.errorDescription
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
