import Foundation

/// Result of one generation, with the accounting attached.
struct GenerationResult<Payload: Sendable>: Sendable {
    var payload: Payload
    var usage: UsageStats
    var latencySeconds: Double
    var modelID: String
    var provider: ProviderKind
}

/// Turns curriculum data plus retrieved source text into lessons, quizzes,
/// tasks, and grades.
///
/// Stateless by design: every method takes what it needs and returns a value.
/// Persistence and logging belong to the caller, which keeps this testable
/// against a stub provider.
struct TutorService: Sendable {

    let provider: any LLMProvider
    let modelID: String
    /// Cheaper model for high-volume, low-judgement generation.
    let utilityModelID: String

    init(provider: any LLMProvider, modelID: String, utilityModelID: String) {
        self.provider = provider
        self.modelID = modelID
        self.utilityModelID = utilityModelID
    }

    // MARK: - Lesson

    /// Generate a lesson, streaming the model's reasoning summary as progress.
    ///
    /// The structured payload can't be shown until the tool call closes, so
    /// rather than a spinner the learner watches the tutor think. It is also a
    /// live demonstration of `thinking.display: "summarized"`, which is on the
    /// syllabus.
    func generateLesson(
        concept: Concept,
        trackTitle: String,
        learner: Learner,
        mastery: Double,
        calibration: String,
        excerpts: [RetrievedExcerpt],
        onThinking: (@Sendable (String) -> Void)? = nil
    ) async throws -> GenerationResult<GeneratedLesson> {
        let request = MessagesRequest(
            model: modelID,
            maxTokens: 16_000,
            messages: [.user(Prompts.lessonRequest(concept))],
            system: systemBlocks([
                Prompts.learnerBrief(learner, mastery: mastery, calibration: calibration),
                Prompts.conceptBrief(concept, trackTitle: trackTitle),
                Prompts.sourcesBlock(excerpts, available: concept.sources)
            ]),
            tools: [TutorTools.lesson],
            toolChoice: .auto,
            thinking: .adaptiveVisible,
            outputConfig: OutputConfig(effort: "high")
        )

        let (response, latency) = try await streamed(request, onThinking: onThinking)
        let lesson: GeneratedLesson = try decode(response, tool: TutorTools.lessonToolName)
        return result(lesson, response: response, latency: latency, model: modelID)
    }

    // MARK: - Quiz

    /// Quiz items are generated from material that already exists, which is
    /// mechanical work — so it runs on the cheap model with thinking off.
    func generateQuiz(
        concepts: [Concept],
        newConceptID: String?,
        itemCount: Int,
        learner: Learner,
        mastery: Double,
        calibration: String,
        excerpts: [RetrievedExcerpt]
    ) async throws -> GenerationResult<GeneratedQuiz> {
        let conceptBriefs = concepts
            .map { Prompts.conceptBrief($0, trackTitle: "") }
            .joined(separator: "\n\n---\n\n")

        let request = MessagesRequest(
            model: utilityModelID,
            maxTokens: 8_000,
            messages: [.user(Prompts.quizRequest(
                concepts: concepts, itemCount: itemCount, newConceptID: newConceptID))],
            system: systemBlocks([
                Prompts.learnerBrief(learner, mastery: mastery, calibration: calibration),
                conceptBriefs,
                Prompts.sourcesBlock(excerpts, available: [])
            ]),
            tools: [TutorTools.quiz],
            toolChoice: .auto,
            // Haiku does not take adaptive thinking, and this task does not
            // need reasoning depth. Omitting the parameter runs without it.
            thinking: nil
        )

        let start = Date()
        let response = try await provider.sendChecked(request)
        var quiz: GeneratedQuiz = try decode(response, tool: TutorTools.quizToolName)
        quiz.items = quiz.items.filter { isCoherent($0) }
        guard !quiz.items.isEmpty else {
            throw LLMError.malformedResponse("The quiz came back with no usable items.")
        }
        return result(quiz, response: response,
                      latency: Date().timeIntervalSince(start), model: utilityModelID)
    }

    /// Reject items whose answer key contradicts the item type. A quiz item
    /// with no correct answer is worse than no quiz item, and this costs
    /// nothing to check.
    private func isCoherent(_ item: GeneratedQuizItem) -> Bool {
        guard !item.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        switch QuizItemKind(rawValue: item.kind) ?? .multipleChoice {
        case .multipleChoice:
            return item.options.count >= 2
                && item.correctIndices.count == 1
                && item.correctIndices.allSatisfy { item.options.indices.contains($0) }
        case .multipleSelect:
            return item.options.count >= 2
                && !item.correctIndices.isEmpty
                && item.correctIndices.allSatisfy { item.options.indices.contains($0) }
        case .shortAnswer, .critique, .prediction:
            return !item.expectedAnswer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    // MARK: - Task

    func generateTask(
        concept: Concept,
        trackTitle: String,
        scopeTier: Int,
        learner: Learner,
        mastery: Double,
        calibration: String,
        hasAWSAccount: Bool,
        excerpts: [RetrievedExcerpt],
        onThinking: (@Sendable (String) -> Void)? = nil
    ) async throws -> GenerationResult<GeneratedTask> {
        let request = MessagesRequest(
            model: modelID,
            maxTokens: 8_000,
            messages: [.user(Prompts.taskRequest(
                concept: concept, scopeTier: scopeTier, hasAWSAccount: hasAWSAccount))],
            system: systemBlocks([
                Prompts.learnerBrief(learner, mastery: mastery, calibration: calibration),
                Prompts.conceptBrief(concept, trackTitle: trackTitle),
                Prompts.sourcesBlock(excerpts, available: concept.sources)
            ]),
            tools: [TutorTools.task],
            toolChoice: .auto,
            thinking: .adaptiveVisible,
            outputConfig: OutputConfig(effort: "high")
        )

        let (response, latency) = try await streamed(request, onThinking: onThinking)
        let task: GeneratedTask = try decode(response, tool: TutorTools.taskToolName)
        return result(task, response: response, latency: latency, model: modelID)
    }

    // MARK: - Grading

    func grade(
        submission: TaskSubmission,
        concept: Concept,
        learner: Learner,
        mastery: Double,
        calibration: String,
        onThinking: (@Sendable (String) -> Void)? = nil
    ) async throws -> GenerationResult<GradeResult> {
        let request = MessagesRequest(
            model: modelID,
            maxTokens: 8_000,
            messages: [.user(Prompts.gradeRequest(submission: submission, concept: concept))],
            system: systemBlocks([
                Prompts.learnerBrief(learner, mastery: mastery, calibration: calibration)
            ]),
            tools: [TutorTools.grade],
            toolChoice: .auto,
            thinking: .adaptiveVisible,
            outputConfig: OutputConfig(effort: "high")
        )

        let (response, latency) = try await streamed(request, onThinking: onThinking)
        var grade: GradeResult = try decode(response, tool: TutorTools.gradeToolName)
        grade.overallScore = Self.reconcileOverall(grade, rubric: submission.rubric)
        return result(grade, response: response, latency: latency, model: modelID)
    }

    /// Recompute the overall score from the per-criterion scores.
    ///
    /// The model reports both, and they occasionally disagree. The rubric
    /// breakdown is the one shown to the learner, so it is the one that wins —
    /// a headline score that contradicts its own justification destroys trust
    /// in the grading entirely.
    static func reconcileOverall(_ grade: GradeResult, rubric: [RubricCriterion]) -> Double {
        let weights = Dictionary(rubric.map { ($0.id, max(0, $0.weight)) },
                                 uniquingKeysWith: { first, _ in first })
        let totalWeight = grade.rubricScores.reduce(0.0) { $0 + (weights[$1.criterionID] ?? 0) }
        guard totalWeight > 0 else {
            guard !grade.rubricScores.isEmpty else { return min(max(grade.overallScore, 0), 1) }
            // No usable weights: fall back to an unweighted mean.
            let mean = grade.rubricScores.reduce(0.0) { $0 + $1.score } / Double(grade.rubricScores.count)
            return min(max(mean, 0), 1)
        }
        let weighted = grade.rubricScores.reduce(0.0) {
            $0 + $1.score * (weights[$1.criterionID] ?? 0)
        }
        return min(max(weighted / totalWeight, 0), 1)
    }

    func gradeShortAnswers(
        items: [(index: Int, prompt: String, expected: String, answer: String)],
        learner: Learner
    ) async throws -> GenerationResult<ShortAnswerGrades> {
        let request = MessagesRequest(
            model: utilityModelID,
            maxTokens: 4_000,
            messages: [.user(Prompts.shortAnswerRequest(items: items))],
            system: systemBlocks([]),
            tools: [TutorTools.shortAnswer],
            toolChoice: .auto,
            thinking: nil
        )

        let start = Date()
        let response = try await provider.sendChecked(request)
        let grades: ShortAnswerGrades = try decode(response, tool: TutorTools.shortAnswerToolName)
        return result(grades, response: response,
                      latency: Date().timeIntervalSince(start), model: utilityModelID)
    }

    // MARK: - Plumbing

    /// System array with the stable core first under a one-hour cache
    /// breakpoint, then the per-request sections. Order is what makes the
    /// cache work; see `api-prompt-caching` in the curriculum.
    private func systemBlocks(_ variableSections: [String]) -> [ContentBlock] {
        var blocks: [ContentBlock] = [
            .text(Prompts.tutorCore, cacheControl: .oneHour)
        ]
        let joined = variableSections
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .joined(separator: "\n\n")
        if !joined.isEmpty { blocks.append(.text(joined, cacheControl: nil)) }
        return blocks
    }

    private func streamed(
        _ request: MessagesRequest,
        onThinking: (@Sendable (String) -> Void)?
    ) async throws -> (MessagesResponse, Double) {
        let start = Date()
        var final: MessagesResponse?

        for try await event in provider.stream(request) {
            switch event {
            case .thinkingDelta(let chunk):
                onThinking?(chunk)
            case .textDelta:
                // The payload comes back through the tool call, so any prose
                // here is incidental and not shown.
                break
            case .completed(let response):
                final = response
            }
        }

        guard let response = final else {
            throw LLMError.malformedResponse("The stream ended without a complete response.")
        }
        if response.wasRefused {
            throw LLMError.refused(
                category: response.stopDetails?.category,
                explanation: response.stopDetails?.explanation
            )
        }
        if response.hitTokenCap { throw LLMError.truncated }
        return (response, Date().timeIntervalSince(start))
    }

    private func decode<T: Decodable>(_ response: MessagesResponse, tool: String) throws -> T {
        guard let input = response.toolInput(named: tool) else {
            // The model answered in prose instead of calling the tool. Surface
            // the beginning of what it said — that's usually a refusal-ish
            // explanation and far more useful than "decoding failed".
            let prose = response.text.trimmingCharacters(in: .whitespacesAndNewlines)
            throw LLMError.malformedResponse(
                prose.isEmpty
                    ? "The model did not call \(tool)."
                    : "The model replied without calling \(tool): \(String(prose.prefix(200)))"
            )
        }
        do {
            return try input.decode(as: T.self)
        } catch {
            throw LLMError.malformedResponse("\(tool) returned an unexpected shape: \(error)")
        }
    }

    private func result<T: Sendable>(
        _ payload: T, response: MessagesResponse, latency: Double, model: String
    ) -> GenerationResult<T> {
        GenerationResult(
            payload: payload,
            usage: response.usage?.asStats ?? .zero,
            latencySeconds: latency,
            modelID: response.model ?? model,
            provider: provider.kind
        )
    }
}
