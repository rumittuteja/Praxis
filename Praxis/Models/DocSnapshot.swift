import Foundation
import SwiftData

/// Where a piece of source material came from. Kept as a string enum so new
/// sources can be added to the catalog without a schema migration.
enum DocSourceKind: String, Codable, CaseIterable, Sendable {
    /// docs.claude.com / code.claude.com pages.
    case anthropicDocs
    /// Markdown and notebooks from anthropics/courses.
    case courses
    /// anthropics/anthropic-cookbook recipes.
    case cookbook
    /// AWS Bedrock user guide and API reference pages.
    case awsBedrockDocs

    var displayName: String {
        switch self {
        case .anthropicDocs:  return "Anthropic docs"
        case .courses:        return "Anthropic courses"
        case .cookbook:       return "Anthropic cookbook"
        case .awsBedrockDocs: return "AWS Bedrock docs"
        }
    }
}

/// One fetched document in the local corpus. Generation retrieves a handful of
/// these per lesson so the model is grounded in current source text rather
/// than its own recollection of the docs.
@Model
final class DocSnapshot {
    @Attribute(.unique) var url: String
    var sourceRaw: String
    var title: String
    /// Plain text or Markdown. HTML pages are reduced to text before storage.
    var content: String
    /// HTTP validators, so a refresh is usually a cheap 304.
    var etag: String?
    var lastModified: String?
    var fetchedAt: Date
    /// Concept IDs this document is relevant to, from the source catalog.
    var conceptTags: [String]
    /// Rough token estimate (~4 chars/token) used to budget the context we
    /// spend on retrieval before falling back to `count_tokens`.
    var approximateTokens: Int

    var source: DocSourceKind { DocSourceKind(rawValue: sourceRaw) ?? .anthropicDocs }

    /// Corpus entries older than this are refetched on the next sync.
    static let staleAfter: TimeInterval = 60 * 60 * 24 * 14

    var isStale: Bool { Date().timeIntervalSince(fetchedAt) > DocSnapshot.staleAfter }

    init(
        url: String,
        source: DocSourceKind,
        title: String,
        content: String,
        etag: String?,
        lastModified: String?,
        conceptTags: [String]
    ) {
        self.url = url
        self.sourceRaw = source.rawValue
        self.title = title
        self.content = content
        self.etag = etag
        self.lastModified = lastModified
        self.fetchedAt = Date()
        self.conceptTags = conceptTags
        self.approximateTokens = max(1, content.count / 4)
    }
}
