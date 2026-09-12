import Foundation

/// A pointer to source material a concept is grounded in. Docs sync uses these
/// URLs to build the retrieval corpus, and lessons cite them back.
struct SourceRef: Codable, Hashable, Sendable, Identifiable {
    var id: String { url }
    var title: String
    var url: String
    /// Which fetcher handles this URL.
    var kind: DocSourceKind
}

/// One curriculum track — a coherent strand of related concepts.
struct Track: Codable, Hashable, Sendable, Identifiable {
    var id: String
    var title: String
    var summary: String
    /// Display order on the progress map.
    var order: Int
}

/// A single teachable idea: the unit of scheduling, quizzing, and mastery.
///
/// Concepts are deliberately small. "Prompt caching" is a concept; "the Claude
/// API" is not. Small units make spaced repetition meaningful and let the
/// prerequisite graph express real dependencies.
struct Concept: Codable, Hashable, Sendable, Identifiable {
    var id: String
    var trackID: String
    var title: String
    /// 1 = foundational, 5 = expert. Drives task scope: tier 1 tasks are
    /// guided step-by-step, tier 5 tasks state a goal and a constraint.
    var tier: Int
    /// One or two sentences for the card front and the map.
    var summary: String
    /// Concept IDs that must be at least `.review` before this unlocks.
    var prerequisites: [String]
    /// What the learner should be able to *do* afterwards. Written as
    /// observable behaviours, since these become the grading rubric.
    var objectives: [String]
    /// The load-bearing facts. Passed to the generator so lessons can't drift
    /// off-topic or invent a different curriculum.
    var keyIdeas: [String]
    /// Errors people reliably make here. Naming and refuting a misconception
    /// explicitly beats presenting the correct version alone.
    var misconceptions: [String]
    /// Which task kinds suit this concept.
    var practiceKinds: [SubmissionKind]
    var sources: [SourceRef]
    var estimatedMinutes: Int

    /// Concepts flagged as requiring credentials the learner may not have
    /// (an AWS account, for instance) are still taught, but their hands-on
    /// task falls back to an explanation task.
    var requiresAWSAccount: Bool?
}

/// The whole syllabus as loaded from `curriculum.json`.
struct Curriculum: Codable, Sendable {
    var version: Int
    var generatedNote: String
    var tracks: [Track]
    var concepts: [Concept]
}
