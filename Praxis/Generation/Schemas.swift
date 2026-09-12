import Foundation

/// Small builders for the JSON Schemas attached to structured-output tools.
///
/// Every schema here sets `additionalProperties: false` and lists every
/// property as required — both are preconditions for `strict: true`, and
/// strict is what turns "usually valid JSON" into "always valid JSON".
enum Schema {

    static func object(_ properties: [(String, JSONValue)]) -> JSONValue {
        .object([
            "type": .string("object"),
            "properties": .object(Dictionary(uniqueKeysWithValues: properties)),
            "required": .array(properties.map { .string($0.0) }),
            "additionalProperties": .bool(false)
        ])
    }

    static func string(_ description: String) -> JSONValue {
        .object(["type": .string("string"), "description": .string(description)])
    }

    static func stringEnum(_ description: String, _ cases: [String]) -> JSONValue {
        .object([
            "type": .string("string"),
            "description": .string(description),
            "enum": .array(cases.map { .string($0) })
        ])
    }

    static func number(_ description: String, minimum: Double? = nil, maximum: Double? = nil) -> JSONValue {
        var fields: [String: JSONValue] = [
            "type": .string("number"),
            "description": .string(description)
        ]
        if let minimum { fields["minimum"] = .number(minimum) }
        if let maximum { fields["maximum"] = .number(maximum) }
        return .object(fields)
    }

    static func integer(_ description: String) -> JSONValue {
        .object(["type": .string("integer"), "description": .string(description)])
    }

    static func array(_ description: String, of items: JSONValue) -> JSONValue {
        .object([
            "type": .string("array"),
            "description": .string(description),
            "items": items
        ])
    }

    static func stringArray(_ description: String) -> JSONValue {
        array(description, of: .object(["type": .string("string")]))
    }

    static func integerArray(_ description: String) -> JSONValue {
        array(description, of: .object(["type": .string("integer")]))
    }
}

// MARK: - Generated payloads

struct GeneratedLesson: Codable, Sendable {
    var title: String
    var workedExample: String
    var body: String
    var keyTakeaways: [String]
    var addressedMisconception: String
    /// URLs chosen from the supplied source list. Constrained rather than free
    /// text so the model cannot invent a plausible-looking documentation link.
    var citedSourceURLs: [String]
}

struct GeneratedQuizItem: Codable, Sendable {
    var conceptID: String
    var kind: String
    var prompt: String
    var options: [String]
    var correctIndices: [Int]
    var expectedAnswer: String
    var explanation: String
}

struct GeneratedQuiz: Codable, Sendable {
    var items: [GeneratedQuizItem]
}

struct GeneratedRubricCriterion: Codable, Sendable {
    var id: String
    var title: String
    var detail: String
    var weight: Double
}

struct GeneratedTask: Codable, Sendable {
    var title: String
    var kind: String
    var briefMarkdown: String
    var rubric: [GeneratedRubricCriterion]
}

struct GradedCriterion: Codable, Sendable {
    var criterionID: String
    var score: Double
    var justification: String
}

struct GradeResult: Codable, Sendable {
    var rubricScores: [GradedCriterion]
    var overallScore: Double
    var feedbackMarkdown: String
    var strengths: [String]
    var gaps: [String]
    var nextStep: String
}

struct ShortAnswerGrade: Codable, Sendable {
    var index: Int
    var score: Double
    var feedback: String
}

struct ShortAnswerGrades: Codable, Sendable {
    var grades: [ShortAnswerGrade]
}

// MARK: - Tool definitions

enum TutorTools {

    static let lessonToolName = "emit_lesson"
    static let quizToolName = "emit_quiz"
    static let taskToolName = "emit_task"
    static let gradeToolName = "emit_grade"
    static let shortAnswerToolName = "emit_short_answer_grades"

    static let lesson = ToolDefinition(
        name: lessonToolName,
        description: "Return the finished lesson. Call this exactly once, with the complete lesson.",
        inputSchema: Schema.object([
            ("title", Schema.string("Lesson title. Concrete and specific, not the concept name repeated.")),
            ("workedExample", Schema.string(
                "A fully worked example in Markdown, shown BEFORE the explanation. Show the thing being "
                + "done correctly, with the reasoning visible at each step. Use a real code snippet or a "
                + "real request/response where the concept warrants one.")),
            ("body", Schema.string(
                "The explanation in Markdown. Build on the worked example rather than restating it. "
                + "Use ## subheadings, short paragraphs, and fenced code blocks with a language tag.")),
            ("keyTakeaways", Schema.stringArray(
                "3 to 5 things that should survive if everything else is forgotten. One sentence each.")),
            ("addressedMisconception", Schema.string(
                "The one misconception from the supplied list this lesson explicitly named and corrected.")),
            ("citedSourceURLs", Schema.stringArray(
                "URLs from the supplied source list that this lesson drew on. Use only URLs given to you; "
                + "return an empty array rather than inventing one."))
        ]),
        strict: true
    )

    static let quiz = ToolDefinition(
        name: quizToolName,
        description: "Return the finished quiz. Call this exactly once.",
        inputSchema: Schema.object([
            ("items", Schema.array("The quiz items, in the order they should be asked.", of: Schema.object([
                ("conceptID", Schema.string("Which supplied concept this item tests. Must match an ID given to you.")),
                ("kind", Schema.stringEnum(
                    "Item type.",
                    ["multipleChoice", "multipleSelect", "shortAnswer", "critique", "prediction"])),
                ("prompt", Schema.string("The question. For critique items, include the flawed code or prompt inline.")),
                ("options", Schema.stringArray(
                    "Answer options for multipleChoice and multipleSelect. Empty array for other kinds. "
                    + "Distractors must be plausible and reflect real mistakes, never obviously wrong filler.")),
                ("correctIndices", Schema.integerArray(
                    "Zero-based indices of correct options. Exactly one for multipleChoice. Empty for free-text kinds.")),
                ("expectedAnswer", Schema.string(
                    "For free-text kinds: what a full-credit answer must contain. Empty string for choice kinds.")),
                ("explanation", Schema.string(
                    "Why the correct answer is correct AND why the tempting wrong answer is wrong. Shown after answering."))
            ])))
        ]),
        strict: true
    )

    static let task = ToolDefinition(
        name: taskToolName,
        description: "Return the hands-on task and its rubric. Call this exactly once.",
        inputSchema: Schema.object([
            ("title", Schema.string("Short task title.")),
            ("kind", Schema.stringEnum(
                "What kind of artifact the learner produces.",
                ["prompt", "code", "investigation", "explanation"])),
            ("briefMarkdown", Schema.string(
                "The task brief in Markdown: what to do, what to submit, and any constraints. "
                + "Scope it to the requested scope tier.")),
            ("rubric", Schema.array(
                "3 to 5 grading criteria, shown to the learner before they start.",
                of: Schema.object([
                    ("id", Schema.string("Short stable identifier, lowercase with hyphens.")),
                    ("title", Schema.string("Criterion name.")),
                    ("detail", Schema.string("What full credit on this criterion looks like, concretely.")),
                    ("weight", Schema.number("Relative weight, 0 to 1. Weights should sum to roughly 1.",
                                             minimum: 0, maximum: 1))
                ])))
        ]),
        strict: true
    )

    static let grade = ToolDefinition(
        name: gradeToolName,
        description: "Return the grade for the learner's submission. Call this exactly once.",
        inputSchema: Schema.object([
            ("rubricScores", Schema.array("One entry per rubric criterion, in the order supplied.",
                of: Schema.object([
                    ("criterionID", Schema.string("The criterion id being scored.")),
                    ("score", Schema.number("Score on this criterion, 0 to 1.", minimum: 0, maximum: 1)),
                    ("justification", Schema.string(
                        "Why that score, quoting the submission where relevant. One or two sentences."))
                ]))),
            ("overallScore", Schema.number("Weighted overall score, 0 to 1.", minimum: 0, maximum: 1)),
            ("feedbackMarkdown", Schema.string(
                "Feedback addressed to the learner in Markdown. Lead with what they got right, then the "
                + "single most important thing to fix, with a concrete example of the better version.")),
            ("strengths", Schema.stringArray("1 to 3 specific things done well.")),
            ("gaps", Schema.stringArray("1 to 3 specific gaps, each tied to a rubric criterion.")),
            ("nextStep", Schema.string("The single most useful next action for this learner."))
        ]),
        strict: true
    )

    static let shortAnswer = ToolDefinition(
        name: shortAnswerToolName,
        description: "Return a score for each free-text quiz answer. Call this exactly once.",
        inputSchema: Schema.object([
            ("grades", Schema.array("One entry per item supplied, matching by index.",
                of: Schema.object([
                    ("index", Schema.integer("Zero-based index of the item being graded.")),
                    ("score", Schema.number("Score, 0 to 1. Award partial credit.", minimum: 0, maximum: 1)),
                    ("feedback", Schema.string("One or two sentences addressed to the learner."))
                ])))
        ]),
        strict: true
    )
}
