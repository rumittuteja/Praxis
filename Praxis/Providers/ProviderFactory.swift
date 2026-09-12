import Foundation
import Observation

/// One recorded model call, for the in-app request inspector.
///
/// Showing learners exactly what went over the wire — model, token counts,
/// cache hits, latency, cost — is a teaching device, not a debug affordance.
/// Prompts and responses stay in memory only; nothing is persisted.
struct RequestLogEntry: Identifiable, Sendable {
    let id = UUID()
    var timestamp = Date()
    var purpose: String
    var provider: ProviderKind
    var endpoint: String
    var model: String
    var usage: UsageStats
    var latencySeconds: Double
    var stopReason: String?
    var errorDescription: String?

    var succeeded: Bool { errorDescription == nil }

    /// Approximate USD cost at first-party list prices. Bedrock is billed
    /// separately by AWS, so the figure is labeled as an estimate in the UI.
    var estimatedCostUSD: Double {
        let (inputPerM, outputPerM) = Self.rates(for: model)
        // Cache reads bill at a small fraction of the input rate; the exact
        // multiplier varies by model, so 0.1 is used as a stated approximation.
        let inputCost = Double(usage.inputTokens) / 1_000_000 * inputPerM
        let cacheReadCost = Double(usage.cacheReadInputTokens) / 1_000_000 * inputPerM * 0.1
        let cacheWriteCost = Double(usage.cacheCreationInputTokens) / 1_000_000 * inputPerM * 1.25
        let outputCost = Double(usage.outputTokens) / 1_000_000 * outputPerM
        return inputCost + cacheReadCost + cacheWriteCost + outputCost
    }

    private static func rates(for model: String) -> (Double, Double) {
        let normalized = model.replacingOccurrences(of: "anthropic.", with: "")
        switch normalized {
        case "claude-opus-5":    return (5.0, 25.0)
        case "claude-sonnet-5":  return (2.0, 10.0)
        case "claude-haiku-4-5": return (1.0, 5.0)
        default:                 return (5.0, 25.0)
        }
    }
}

/// Rolling in-memory log of model calls for the current app run.
@Observable
final class RequestLog {
    private(set) var entries: [RequestLogEntry] = []
    private let limit = 200

    func record(_ entry: RequestLogEntry) {
        entries.insert(entry, at: 0)
        if entries.count > limit { entries.removeLast(entries.count - limit) }
    }

    func clear() { entries.removeAll() }

    var totalUsage: UsageStats {
        entries.reduce(UsageStats.zero) { $0 + $1.usage }
    }

    var totalEstimatedCostUSD: Double {
        entries.reduce(0) { $0 + $1.estimatedCostUSD }
    }
}

/// Builds a live provider from saved credentials and the learner's preference.
struct ProviderFactory: Sendable {

    let credentials: CredentialStore

    init(credentials: CredentialStore = CredentialStore()) {
        self.credentials = credentials
    }

    /// The provider for `kind`, or a typed error explaining what's missing.
    func provider(for kind: ProviderKind, region: String) throws -> any LLMProvider {
        switch kind {
        case .anthropic:
            guard let key = credentials.value(for: .anthropicAPIKey) else {
                throw LLMError.missingCredentials(.anthropic)
            }
            return AnthropicProvider(apiKey: key)

        case .bedrock:
            guard let aws = credentials.awsCredentials() else {
                throw LLMError.missingCredentials(.bedrock)
            }
            guard !region.isEmpty else {
                throw LLMError.invalidConfiguration("Pick an AWS region in Settings.")
            }
            return BedrockProvider(region: region, credentials: aws)
        }
    }

    /// The provider a given learner should use right now, falling back to the
    /// other one if their preferred provider has no credentials. A learner
    /// mid-lesson shouldn't be blocked because they only configured one side.
    func provider(for learner: Learner) throws -> any LLMProvider {
        do {
            return try provider(for: learner.preferredProvider, region: learner.bedrockRegion)
        } catch LLMError.missingCredentials {
            let fallback: ProviderKind = learner.preferredProvider == .anthropic ? .bedrock : .anthropic
            return try provider(for: fallback, region: learner.bedrockRegion)
        }
    }

    /// Model ID for a learner on whichever provider actually resolved.
    func modelID(for learner: Learner, provider: ProviderKind, utility: Bool = false) -> String {
        switch provider {
        case .anthropic:
            return utility ? ModelCatalog.defaultUtilityModel : learner.anthropicModel
        case .bedrock:
            return utility ? ModelCatalog.defaultUtilityModelBedrock : learner.bedrockModel
        }
    }

    var configuredProviders: [ProviderKind] {
        var available: [ProviderKind] = []
        if credentials.hasAnthropicCredentials { available.append(.anthropic) }
        if credentials.hasAWSCredentials { available.append(.bedrock) }
        return available
    }

    var hasAnyCredentials: Bool { !configuredProviders.isEmpty }
}
