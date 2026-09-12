import Foundation
import SwiftData

/// Which API surface the learner's requests go through.
///
/// These are genuinely different products, not two URLs for the same thing —
/// see the `aws-bedrock-vs-platform` concept in the curriculum.
enum ProviderKind: String, Codable, CaseIterable, Sendable {
    /// api.anthropic.com, authenticated with an API key.
    case anthropic
    /// bedrock-runtime.<region>.amazonaws.com, authenticated with SigV4.
    case bedrock

    var displayName: String {
        switch self {
        case .anthropic: return "Anthropic API"
        case .bedrock:   return "Amazon Bedrock"
        }
    }
}

/// A person using the app. Multiple learners share one device; each keeps a
/// completely separate progress graph, review queue, and streak.
@Model
final class Learner {
    @Attribute(.unique) var id: UUID
    var name: String
    var avatarEmoji: String
    var createdAt: Date

    /// Free-text description of what this learner already knows, captured at
    /// onboarding and editable later. Injected into every generation prompt so
    /// lessons start at the right altitude instead of re-explaining tokens.
    var priorKnowledge: String

    // MARK: Cadence

    var dailyGoalMinutes: Int
    var currentStreak: Int
    var longestStreak: Int
    /// Start-of-day for the last day a session was completed.
    var lastCompletedDay: Date?
    var totalSessionsCompleted: Int
    var totalStudyMinutes: Int

    // MARK: Provider preferences

    var preferredProviderRaw: String
    var anthropicModel: String
    var bedrockModel: String
    var bedrockRegion: String

    /// Learners who want to see what the tutor actually sent to the model.
    /// On by default — this app is about AI engineering, so the plumbing is
    /// part of the lesson rather than something to hide.
    var showsRequestInspector: Bool

    var preferredProvider: ProviderKind {
        get { ProviderKind(rawValue: preferredProviderRaw) ?? .anthropic }
        set { preferredProviderRaw = newValue.rawValue }
    }

    init(
        id: UUID = UUID(),
        name: String,
        avatarEmoji: String = "🧠",
        priorKnowledge: String = "",
        dailyGoalMinutes: Int = 20,
        preferredProvider: ProviderKind = .anthropic
    ) {
        self.id = id
        self.name = name
        self.avatarEmoji = avatarEmoji
        self.createdAt = Date()
        self.priorKnowledge = priorKnowledge
        self.dailyGoalMinutes = dailyGoalMinutes
        self.currentStreak = 0
        self.longestStreak = 0
        self.lastCompletedDay = nil
        self.totalSessionsCompleted = 0
        self.totalStudyMinutes = 0
        self.preferredProviderRaw = preferredProvider.rawValue
        self.anthropicModel = ModelCatalog.defaultAnthropicModel
        self.bedrockModel = ModelCatalog.defaultBedrockModel
        self.bedrockRegion = "us-east-1"
        self.showsRequestInspector = true
    }
}
