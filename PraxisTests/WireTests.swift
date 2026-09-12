import Testing
import Foundation
@testable import Praxis

@Suite("Messages wire format")
struct WireTests {

    private func encoded(_ request: MessagesRequest) throws -> JSONValue {
        let data = try JSONEncoder().encode(request)
        return try JSONDecoder().decode(JSONValue.self, from: data)
    }

    @Test("A first-party request carries the model and no anthropic_version")
    func firstPartyShape() throws {
        let request = MessagesRequest(
            model: "claude-opus-5", maxTokens: 1024,
            messages: [.user("hi")]
        )
        let json = try encoded(request)
        #expect(json["model"]?.stringValue == "claude-opus-5")
        #expect(json["max_tokens"]?.intValue == 1024)
        #expect(json["anthropic_version"] == nil)
    }

    @Test("A Bedrock request drops the model and adds anthropic_version")
    func bedrockShape() throws {
        var request = MessagesRequest(
            model: "anthropic.claude-opus-5", maxTokens: 1024,
            messages: [.user("hi")]
        )
        request.bedrockStyle = true

        let json = try encoded(request)
        // Bedrock takes the model in the URL path, not the body.
        #expect(json["model"] == nil)
        #expect(json["anthropic_version"]?.stringValue == "bedrock-2023-05-31")
        #expect(json["max_tokens"]?.intValue == 1024)
    }

    @Test("Snake-case keys are used throughout")
    func snakeCaseKeys() throws {
        let request = MessagesRequest(
            model: "claude-opus-5", maxTokens: 16,
            messages: [.user("hi")],
            tools: [TutorTools.lesson],
            toolChoice: .auto,
            outputConfig: OutputConfig(effort: "high")
        )
        let json = try encoded(request)
        #expect(json["max_tokens"] != nil)
        #expect(json["tool_choice"] != nil)
        #expect(json["output_config"]?["effort"]?.stringValue == "high")
        #expect(json["tools"]?.arrayValue?.first?["input_schema"] != nil)
    }

    @Test("Adaptive thinking encodes without budget_tokens")
    func thinkingEncoding() throws {
        let request = MessagesRequest(
            model: "claude-opus-5", maxTokens: 16,
            messages: [.user("hi")],
            thinking: .adaptiveVisible
        )
        let json = try encoded(request)
        #expect(json["thinking"]?["type"]?.stringValue == "adaptive")
        #expect(json["thinking"]?["display"]?.stringValue == "summarized")
        // budget_tokens is removed on current models and 400s if sent.
        #expect(json["thinking"]?["budget_tokens"] == nil)
    }

    @Test("Thinking is omitted entirely when nil")
    func thinkingOmitted() throws {
        let request = MessagesRequest(
            model: "claude-haiku-4-5", maxTokens: 16,
            messages: [.user("hi")], thinking: nil
        )
        #expect(try encoded(request)["thinking"] == nil)
    }

    @Test("A cache breakpoint rides on the system block")
    func cacheControlEncoding() throws {
        let request = MessagesRequest(
            model: "claude-opus-5", maxTokens: 16,
            messages: [.user("hi")],
            system: [.text("stable prefix", cacheControl: .oneHour)]
        )
        let json = try encoded(request)
        let block = try #require(json["system"]?.arrayValue?.first)
        #expect(block["cache_control"]?["type"]?.stringValue == "ephemeral")
        #expect(block["cache_control"]?["ttl"]?.stringValue == "1h")
    }

    @Test("Strict tools declare additionalProperties false and a required list")
    func strictToolSchema() throws {
        let json = try encoded(MessagesRequest(
            model: "claude-opus-5", maxTokens: 16,
            messages: [.user("hi")], tools: [TutorTools.grade]
        ))
        let tool = try #require(json["tools"]?.arrayValue?.first)
        #expect(tool["strict"]?.boolValue == true)
        let schema = try #require(tool["input_schema"])
        #expect(schema["additionalProperties"]?.boolValue == false)
        #expect(schema["required"]?.arrayValue?.isEmpty == false)
    }

    @Test("A response with thinking before text still yields the right text")
    func responseParsing() throws {
        let json = """
        {"id":"msg_1","model":"claude-opus-5","role":"assistant","stop_reason":"end_turn",
         "content":[{"type":"thinking","thinking":"reasoning"},{"type":"text","text":"answer"}],
         "usage":{"input_tokens":10,"output_tokens":5,"cache_read_input_tokens":100}}
        """
        let response = try JSONDecoder().decode(MessagesResponse.self, from: Data(json.utf8))
        #expect(response.text == "answer")
        #expect(response.usage?.cacheReadInputTokens == 100)
        #expect(!response.wasRefused)
    }

    @Test("A refusal is a 200 response and must be detected via stop_reason")
    func refusalDetection() throws {
        let json = """
        {"id":"msg_1","stop_reason":"refusal","content":[],
         "stop_details":{"type":"refusal","category":"cyber","explanation":"declined"}}
        """
        let response = try JSONDecoder().decode(MessagesResponse.self, from: Data(json.utf8))
        #expect(response.wasRefused)
        #expect(response.stopDetails?.category == "cyber")
    }

    @Test("Truncation is detectable from stop_reason")
    func truncationDetection() throws {
        let json = #"{"stop_reason":"max_tokens","content":[{"type":"text","text":"cut off"}]}"#
        let response = try JSONDecoder().decode(MessagesResponse.self, from: Data(json.utf8))
        #expect(response.hitTokenCap)
    }

    @Test("Tool calls are found by name, not by position")
    func toolInputLookup() throws {
        let json = """
        {"content":[{"type":"thinking","thinking":"x"},
                    {"type":"tool_use","id":"toolu_1","name":"emit_quiz","input":{"items":[]}}]}
        """
        let response = try JSONDecoder().decode(MessagesResponse.self, from: Data(json.utf8))
        #expect(response.toolInput(named: "emit_quiz") != nil)
        #expect(response.toolInput(named: "emit_lesson") == nil)
    }

    @Test("Unknown content block types decode without throwing")
    func unknownBlockTolerance() throws {
        let json = #"{"content":[{"type":"some_future_block","data":1},{"type":"text","text":"ok"}]}"#
        let response = try JSONDecoder().decode(MessagesResponse.self, from: Data(json.utf8))
        #expect(response.content.count == 2)
        #expect(response.text == "ok")
    }

    @Test("Usage totals add up across calls")
    func usageArithmetic() {
        let a = UsageStats(inputTokens: 10, outputTokens: 5,
                           cacheCreationInputTokens: 1, cacheReadInputTokens: 2)
        let b = UsageStats(inputTokens: 20, outputTokens: 7,
                           cacheCreationInputTokens: 0, cacheReadInputTokens: 8)
        let total = a + b
        #expect(total.inputTokens == 30)
        #expect(total.outputTokens == 12)
        #expect(total.cacheReadInputTokens == 10)
    }

    @Test("Cache hit rate is read tokens over total input")
    func cacheHitRate() {
        let usage = UsageStats(inputTokens: 25, outputTokens: 0,
                               cacheCreationInputTokens: 0, cacheReadInputTokens: 75)
        #expect(abs(usage.cacheHitRate - 0.75) < 0.0001)
        #expect(UsageStats.zero.cacheHitRate == 0)
    }
}

@Suite("Grading reconciliation")
struct GradingTests {

    private let rubric = [
        RubricCriterion(id: "correct", title: "Correctness", detail: "", weight: 0.6),
        RubricCriterion(id: "clarity", title: "Clarity", detail: "", weight: 0.4)
    ]

    private func grade(_ scores: [(String, Double)], overall: Double) -> GradeResult {
        GradeResult(
            rubricScores: scores.map {
                GradedCriterion(criterionID: $0.0, score: $0.1, justification: "")
            },
            overallScore: overall,
            feedbackMarkdown: "", strengths: [], gaps: [], nextStep: ""
        )
    }

    @Test("The overall score is recomputed from the weighted rubric")
    func recomputesWeighted() {
        // The model claimed 0.95, but the rubric says 1.0*0.6 + 0.5*0.4 = 0.8.
        let result = TutorService.reconcileOverall(
            grade([("correct", 1.0), ("clarity", 0.5)], overall: 0.95),
            rubric: rubric
        )
        #expect(abs(result - 0.8) < 0.0001)
    }

    @Test("A grader that contradicts its own breakdown loses")
    func breakdownWins() {
        let inflated = TutorService.reconcileOverall(
            grade([("correct", 0.2), ("clarity", 0.2)], overall: 0.9),
            rubric: rubric
        )
        #expect(abs(inflated - 0.2) < 0.0001)
    }

    @Test("Unknown criterion ids fall back to an unweighted mean")
    func unknownCriteria() {
        let result = TutorService.reconcileOverall(
            grade([("mystery-a", 1.0), ("mystery-b", 0.0)], overall: 0.7),
            rubric: rubric
        )
        #expect(abs(result - 0.5) < 0.0001)
    }

    @Test("An empty breakdown keeps the reported score, clamped")
    func emptyBreakdown() {
        let result = TutorService.reconcileOverall(grade([], overall: 1.4), rubric: rubric)
        #expect(result == 1.0)
    }

    @Test("Scores are clamped into 0...1")
    func clamping() {
        let high = TutorService.reconcileOverall(
            grade([("correct", 5.0), ("clarity", 5.0)], overall: 5.0), rubric: rubric)
        #expect(high == 1.0)
    }
}

@Suite("Quiz scoring")
struct QuizScoringTests {

    private func item(kind: QuizItemKind, options: [String], correct: [Int],
                      selected: [Int]) -> QuizItemRecord {
        QuizItemRecord(
            id: UUID(), conceptID: "c", kindRaw: kind.rawValue, prompt: "p",
            options: options, correctIndices: correct, expectedAnswer: nil,
            selectedIndices: selected, writtenAnswer: nil,
            confidenceRaw: ConfidenceLevel.unsure.rawValue, score: 0,
            explanation: "", feedback: nil
        )
    }

    @Test("Single choice is all or nothing")
    func multipleChoice() {
        let right = item(kind: .multipleChoice, options: ["a", "b"], correct: [1], selected: [1])
        let wrong = item(kind: .multipleChoice, options: ["a", "b"], correct: [1], selected: [0])
        #expect(SessionCoordinator.localScore(for: right) == 1)
        #expect(SessionCoordinator.localScore(for: wrong) == 0)
    }

    @Test("Multiple select awards partial credit by overlap")
    func multipleSelectPartial() {
        let perfect = item(kind: .multipleSelect, options: ["a", "b", "c"],
                           correct: [0, 1], selected: [0, 1])
        let nearMiss = item(kind: .multipleSelect, options: ["a", "b", "c"],
                            correct: [0, 1], selected: [0])
        let overshoot = item(kind: .multipleSelect, options: ["a", "b", "c"],
                             correct: [0, 1], selected: [0, 1, 2])

        #expect(SessionCoordinator.localScore(for: perfect) == 1)
        // One of two correct, nothing wrong: 1 / 2 union.
        #expect(abs(SessionCoordinator.localScore(for: nearMiss) - 0.5) < 0.0001)
        // Both correct plus one wrong: 2 / 3 union.
        #expect(abs(SessionCoordinator.localScore(for: overshoot) - (2.0 / 3.0)) < 0.0001)
    }

    @Test("Free-text items are left for the model to grade")
    func freeTextDeferred() {
        let free = item(kind: .shortAnswer, options: [], correct: [], selected: [])
        #expect(SessionCoordinator.localScore(for: free) == 0)
    }
}
