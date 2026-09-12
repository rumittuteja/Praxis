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

    static let defaultAnthropicModel = "claude-opus-5"
    static let defaultBedrockModel = "anthropic.claude-opus-5"

    /// Cheaper model used for high-volume, low-judgement work (quiz item
    /// generation from an already-written lesson, corpus tagging).
    static let defaultUtilityModel = "claude-haiku-4-5"
    static let defaultUtilityModelBedrock = "anthropic.claude-haiku-4-5"

    static let anthropic: [Entry] = [
        Entry(id: "claude-opus-5", displayName: "Opus 5",
              note: "Best reasoning. Default for lessons and grading."),
        Entry(id: "claude-sonnet-5", displayName: "Sonnet 5",
              note: "Cheaper, still strong. Good for daily use at volume."),
        Entry(id: "claude-haiku-4-5", displayName: "Haiku 4.5",
              note: "Fastest and cheapest. Used for quiz generation.")
    ]

    static let bedrock: [Entry] = [
        Entry(id: "anthropic.claude-opus-5", displayName: "Opus 5 (Bedrock)",
              note: "Note the anthropic. prefix — Bedrock IDs differ from first-party."),
        Entry(id: "anthropic.claude-sonnet-5", displayName: "Sonnet 5 (Bedrock)",
              note: "Cheaper Bedrock option."),
        Entry(id: "anthropic.claude-haiku-4-5", displayName: "Haiku 4.5 (Bedrock)",
              note: "Fastest Bedrock option.")
    ]

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
