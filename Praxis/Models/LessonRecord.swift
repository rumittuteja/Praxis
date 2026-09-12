import Foundation
import SwiftData

/// A citation back to the source material a lesson was grounded in.
struct SourceCitation: Codable, Hashable, Sendable, Identifiable {
    var id: String { url }
    var title: String
    var url: String
    /// Short quoted span the lesson leaned on, for spot-checking the model.
    var excerpt: String?
}

/// Token accounting for one generation. Surfaced in the UI on purpose: a
/// person learning AI engineering should watch their own token spend
/// accumulate rather than read about it abstractly.
struct UsageStats: Codable, Hashable, Sendable {
    var inputTokens: Int
    var outputTokens: Int
    var cacheCreationInputTokens: Int
    var cacheReadInputTokens: Int

    static let zero = UsageStats(
        inputTokens: 0, outputTokens: 0,
        cacheCreationInputTokens: 0, cacheReadInputTokens: 0
    )

    /// Fraction of input tokens served from cache, 0...1.
    var cacheHitRate: Double {
        let total = inputTokens + cacheReadInputTokens
        guard total > 0 else { return 0 }
        return Double(cacheReadInputTokens) / Double(total)
    }

    static func + (lhs: UsageStats, rhs: UsageStats) -> UsageStats {
        UsageStats(
            inputTokens: lhs.inputTokens + rhs.inputTokens,
            outputTokens: lhs.outputTokens + rhs.outputTokens,
            cacheCreationInputTokens: lhs.cacheCreationInputTokens + rhs.cacheCreationInputTokens,
            cacheReadInputTokens: lhs.cacheReadInputTokens + rhs.cacheReadInputTokens
        )
    }
}

/// One generated lesson, cached so reopening it doesn't re-bill a request and
/// so the learner can revisit exactly what they read.
@Model
final class LessonRecord {
    @Attribute(.unique) var id: UUID
    var learnerID: UUID
    var conceptID: String
    var generatedAt: Date

    var title: String
    /// The "here's the thing already solved" example. Worked examples before
    /// independent practice is one of the most robust findings in the
    /// instructional-design literature.
    var workedExampleMarkdown: String
    /// Main explanation.
    var bodyMarkdown: String
    /// The 3–5 things that should survive if everything else is forgotten.
    var keyTakeaways: [String]
    /// Misconception the lesson explicitly named and corrected.
    var addressedMisconception: String?
    var citations: [SourceCitation]

    var modelID: String
    var providerRaw: String
    var usage: UsageStats
    /// Wall-clock seconds the generation took, shown in the request inspector.
    var latencySeconds: Double

    /// Set when the learner marks the lesson read, used for time-on-task.
    var readAt: Date?

    init(
        learnerID: UUID,
        conceptID: String,
        title: String,
        workedExampleMarkdown: String,
        bodyMarkdown: String,
        keyTakeaways: [String],
        addressedMisconception: String?,
        citations: [SourceCitation],
        modelID: String,
        provider: ProviderKind,
        usage: UsageStats,
        latencySeconds: Double
    ) {
        self.id = UUID()
        self.learnerID = learnerID
        self.conceptID = conceptID
        self.generatedAt = Date()
        self.title = title
        self.workedExampleMarkdown = workedExampleMarkdown
        self.bodyMarkdown = bodyMarkdown
        self.keyTakeaways = keyTakeaways
        self.addressedMisconception = addressedMisconception
        self.citations = citations
        self.modelID = modelID
        self.providerRaw = provider.rawValue
        self.usage = usage
        self.latencySeconds = latencySeconds
        self.readAt = nil
    }
}
