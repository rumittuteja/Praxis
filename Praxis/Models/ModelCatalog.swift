import Foundation

/// Model IDs the app offers, per provider.
///
/// Bedrock model IDs carry an `anthropic.` prefix; first-party IDs do not.
/// That difference is a frequent source of confusion, so it is encoded here in
/// one place and taught explicitly in the `aws-bedrock-model-ids` concept.
enum ModelCatalog {

    struct Entry: Identifiable, Hashable, Sendable {
        var id: String
        var displayName: String
        /// Rough guidance shown next to the picker.
        var note: String
    }

    static let defaultAnthropicModel = "claude-opus-5-5"
    static let defaultBedrockModel = "anthropic.claude-opus-5-5"

    /// Cheaper model used for high-volume, low-judgement work (quiz item
    /// generation from an already-written lesson, corpus tagging).
    static let defaultUtilityModel = "claude-haiku-4-5"
    static let defaultUtilityModelBedrock = "anthropic.claude-haiku-4-5"

    // Model names are product names and stay untranslated; the notes are
    // guidance for the learner and are localized.
    static let anthropic: [Entry] = [
        Entry(id: "claude-opus-5-5", displayName: "Opus 5.5",
              note: String(localized: "Fastest strong model, and the default. Finishes the same work in fewer tokens than Opus 5.",
                           comment: "Guidance next to a model in the picker")),
        Entry(id: "claude-opus-5", displayName: "Opus 5",
              note: String(localized: "Best reasoning. The default for lessons and grading.",
                           comment: "Guidance next to a model in the picker")),
        Entry(id: "claude-sonnet-5", displayName: "Sonnet 5",
              note: String(localized: "Cheaper, still strong. Good for daily use at volume.",
                           comment: "Guidance next to a model in the picker")),
        Entry(id: "claude-haiku-4-5", displayName: "Haiku 4.5",
              note: String(localized: "Fastest and cheapest. Already used for quiz generation.",
                           comment: "Guidance next to a model in the picker"))
    ]

    static let bedrock: [Entry] = [
        Entry(id: "anthropic.claude-opus-5-5", displayName: "Opus 5.5 (Bedrock)",
              note: String(localized: "Fastest strong model, and the default.",
                           comment: "Guidance next to a Bedrock model")),
        Entry(id: "anthropic.claude-opus-5", displayName: "Opus 5 (Bedrock)",
              note: String(localized: "Note the anthropic. prefix — Bedrock model IDs differ from first-party ones.",
                           comment: "Guidance next to a Bedrock model. Keep 'anthropic.' verbatim.")),
        Entry(id: "anthropic.claude-sonnet-5", displayName: "Sonnet 5 (Bedrock)",
              note: String(localized: "Cheaper Bedrock option.",
                           comment: "Guidance next to a Bedrock model")),
        Entry(id: "anthropic.claude-haiku-4-5", displayName: "Haiku 4.5 (Bedrock)",
              note: String(localized: "Fastest Bedrock option.",
                           comment: "Guidance next to a Bedrock model"))
    ]

    /// The effort level to send for a given model.
    ///
    /// Effort level names do **not** mean the same amount of thinking across
    /// models. Opus 5.5 defaults to `medium` and matches or beats Opus 5 at
    /// `high` on this kind of work, so sending `high` to 5.5 buys longer turns
    /// and more output tokens for no gain. Opus 5 defaults to `high` and needs
    /// it. Carrying one value across a model change is the mistake this
    /// function exists to prevent — see the `model-migration` concept.
    static func recommendedEffort(for modelID: String) -> String {
        let normalized = modelID.replacingOccurrences(of: "anthropic.", with: "")
        switch normalized {
        case "claude-opus-5-5": return "medium"
        case "claude-haiku-4-5": return "medium"
        default:                 return "high"
        }
    }

    static func note(for modelID: String, provider: ProviderKind) -> String? {
        entries(for: provider).first { $0.id == modelID }?.note
    }

    static func entries(for provider: ProviderKind) -> [Entry] {
        switch provider {
        case .anthropic: return anthropic
        case .bedrock:   return bedrock
        }
    }

    /// AWS regions where Claude models are commonly available on Bedrock.
    /// Availability genuinely varies by region and changes over time — the
    /// app surfaces the API's own error rather than pretending to know.
    static let bedrockRegions = [
        "us-east-1", "us-east-2", "us-west-2",
        "eu-central-1", "eu-west-1", "eu-west-3",
        "ap-south-1", "ap-southeast-1", "ap-southeast-2", "ap-northeast-1"
    ]
}
