import Foundation

/// A documentation page found by crawling a published index rather than by
/// being hardcoded in the curriculum.
struct DiscoveredPage: Sendable, Hashable {
    var title: String
    var url: String
    var summary: String
    /// The index section it appeared under, e.g. "Build with Claude Code".
    var section: String
    var kind: DocSourceKind
}

/// Finds documentation pages the syllabus does not know about.
///
/// The curriculum's 49 source URLs were written by hand and go stale two ways:
/// pages move, and — more importantly — pages that did not exist when the
/// syllabus was authored are never fetched at all. A learner studying an API
/// that shipped last month would get a lesson grounded in nothing.
///
/// Both Anthropic documentation sites publish an `llms.txt` index, and AWS
/// publishes a sitemap. Crawling those means the corpus grows as the
/// documentation does, with no app update.
///
/// Discovered pages *supplement* the curated list, they do not replace it. The
/// hand-picked URLs encode an editorial judgement about which page best teaches
/// a concept, and a keyword match is not a substitute for that.
struct SourceDiscovery: Sendable {

    static let anthropicDocsIndex = "https://docs.claude.com/llms.txt"
    static let claudeCodeIndex = "https://code.claude.com/docs/llms.txt"
    static let bedrockSitemap = "https://docs.aws.amazon.com/bedrock/latest/userguide/sitemap.xml"

    /// Ceiling on pages pulled in beyond the curated set. Without it a first
    /// sync would try to fetch 1,700 pages.
    var maxDiscoveredPages = 60
    /// Extra pages fetched per concept.
    var pagesPerConcept = 2

    private static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 45
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: config)
    }()

    // MARK: Fetching indexes

    /// Pull every index. Failures are per-index, so one unreachable site does
    /// not lose the others.
    func discoverAll() async -> [DiscoveredPage] {
        var pages: [DiscoveredPage] = []
        for (urlString, kind) in [
            (Self.anthropicDocsIndex, DocSourceKind.anthropicDocs),
            (Self.claudeCodeIndex, DocSourceKind.anthropicDocs)
        ] {
            if let text = await fetchText(urlString) {
                pages.append(contentsOf: Self.parseLLMsText(text, kind: kind))
            }
        }
        if let xml = await fetchText(Self.bedrockSitemap) {
            pages.append(contentsOf: Self.parseSitemap(xml))
        }
        // The two Anthropic indexes overlap; de-duplicate on URL.
        var seen = Set<String>()
        return pages.filter { seen.insert($0.url).inserted }
    }

    private func fetchText(_ urlString: String) async -> String? {
        guard let url = URL(string: urlString) else { return nil }
        var request = URLRequest(url: url)
        request.setValue("text/plain, text/markdown, application/xml", forHTTPHeaderField: "Accept")
        guard let (data, response) = try? await Self.session.data(for: request),
              let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    // MARK: Parsing

    /// Parse an `llms.txt` index.
    ///
    /// Format is Markdown: `## Section` headings, then rows shaped
    /// `- [Title](https://…/page.md): description`. Parsed by hand rather than
    /// with a regex — the shape is simple and a scanner is easier to reason
    /// about when a line is malformed.
    static func parseLLMsText(_ text: String, kind: DocSourceKind) -> [DiscoveredPage] {
        var pages: [DiscoveredPage] = []
        var section = ""

        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)

            if line.hasPrefix("## ") {
                section = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                continue
            }
            guard line.hasPrefix("- ["), let titleEnd = line.range(of: "](") else { continue }

            let title = String(line[line.index(line.startIndex, offsetBy: 3)..<titleEnd.lowerBound])
            let afterBracket = line[titleEnd.upperBound...]
            guard let urlEnd = afterBracket.firstIndex(of: ")") else { continue }

            let url = String(afterBracket[..<urlEnd]).trimmingCharacters(in: .whitespaces)
            guard url.hasPrefix("https://") else { continue }

            var summary = String(afterBracket[afterBracket.index(after: urlEnd)...])
                .trimmingCharacters(in: .whitespaces)
            if summary.hasPrefix(":") { summary = String(summary.dropFirst()).trimmingCharacters(in: .whitespaces) }
            // Index descriptions sometimes run into the next entry's heading;
            // only the first sentence is reliable.
            if summary.hasPrefix("#") || summary.hasPrefix("-") { summary = "" }

            pages.append(DiscoveredPage(
                title: title, url: url, summary: String(summary.prefix(300)),
                section: section, kind: kind
            ))
        }
        return pages
    }

    /// Pull `<loc>` entries out of a sitemap, keeping only Bedrock user-guide
    /// pages — the sitemap covers far more of the AWS docs than we want.
    static func parseSitemap(_ xml: String) -> [DiscoveredPage] {
        var pages: [DiscoveredPage] = []
        var remainder = Substring(xml)

        while let open = remainder.range(of: "<loc>"),
              let close = remainder.range(of: "</loc>", range: open.upperBound..<remainder.endIndex) {
            let url = String(remainder[open.upperBound..<close.lowerBound])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            remainder = remainder[close.upperBound...]

            guard url.contains("/bedrock/"), url.hasSuffix(".html") else { continue }
            pages.append(DiscoveredPage(
                title: Self.titleFromPath(url), url: url, summary: "",
                section: "Bedrock user guide", kind: .awsBedrockDocs
            ))
        }
        return pages
    }

    /// "…/model-invocation-logging.html" -> "Model invocation logging".
    static func titleFromPath(_ url: String) -> String {
        let slug = url
            .split(separator: "/").last
            .map { $0.replacingOccurrences(of: ".html", with: "") } ?? url
        let words = slug.replacingOccurrences(of: "-", with: " ")
                        .replacingOccurrences(of: "_", with: " ")
        return words.prefix(1).uppercased() + words.dropFirst()
    }

    // MARK: Ranking

    /// Minimum score for a page to be worth fetching.
    ///
    /// Tuned against the real indexes (831 pages) rather than guessed. Lower
    /// values pull in near-misses — a flat keyword count matched `cc-hooks` to
    /// "Cloud environment setup" — and a wrong page is worse than no page,
    /// because it displaces good context in a fixed retrieval budget while a
    /// curated source for that concept already exists. At this threshold about
    /// three quarters of concepts gain a page and the matches are defensible.
    static let relevanceThreshold = 12

    /// Score one page against one concept.
    ///
    /// The weighting matters more than the arithmetic: a concept's **id tokens
    /// and title words** are specific, so they carry the score; words lifted
    /// from its key ideas are generic ("events", "environment", "request") and
    /// only break ties, capped so a page cannot qualify on them alone.
    static func score(_ page: DiscoveredPage, for concept: Concept) -> Int {
        let idTokens = Set(concept.id.split(separator: "-").filter { $0.count >= 3 }.map(String.init))
        let titleWords = significantWords(in: concept.title, minimumLength: 4)
        let ideaWords = concept.keyIdeas.reduce(into: Set<String>()) {
            $0.formUnion(significantWords(in: $1, minimumLength: 6))
        }

        let slug = page.url.lowercased()
        let title = page.title.lowercased()
        let context = "\(page.summary) \(page.section)".lowercased()

        var total = 0
        total += 5 * idTokens.filter { slug.contains($0) }.count
        total += 4 * idTokens.filter { title.contains($0) }.count
        total += 3 * titleWords.filter { title.contains($0) }.count
        total += 2 * titleWords.filter { slug.contains($0) }.count
        total += min(3, ideaWords.filter { title.contains($0) || context.contains($0) }.count)
        return total
    }

    static func significantWords(in text: String, minimumLength: Int) -> Set<String> {
        Set(
            text.lowercased()
                .components(separatedBy: CharacterSet.alphanumerics.inverted)
                .filter { $0.count >= minimumLength && !stopWords.contains($0) }
        )
    }

    private static let stopWords: Set<String> = [
        "that", "this", "with", "from", "your", "into", "when", "what", "which",
        "they", "them", "then", "than", "have", "does", "will", "must", "each",
        "were", "been", "also", "only", "more", "most", "some", "such", "very",
        "over", "under", "about", "there", "these", "those", "their", "would",
        "could", "should", "because", "before", "after", "where", "while",
        "using", "used"
    ]

    /// The discovered pages most relevant to a concept.
    ///
    /// URLs already curated by the syllabus are excluded: a hand-picked source
    /// encodes an editorial judgement that a keyword match cannot improve on.
    static func rank(
        _ pages: [DiscoveredPage],
        for concept: Concept,
        excluding curated: Set<String>,
        limit: Int
    ) -> [DiscoveredPage] {
        pages
            .filter { !curated.contains($0.url) }
            .map { (page: $0, score: score($0, for: concept)) }
            .filter { $0.score >= relevanceThreshold }
            .sorted { $0.score == $1.score ? $0.page.url < $1.page.url : $0.score > $1.score }
            .prefix(limit)
            .map(\.page)
    }

    /// Build the extra fetch list for a whole curriculum, capped.
    func plan(
        pages: [DiscoveredPage],
        store: CurriculumStore
    ) -> [(page: DiscoveredPage, conceptIDs: [String])] {
        let curated = Set(store.allConcepts.flatMap { $0.sources.map(\.url) })
        var byURL: [String: (page: DiscoveredPage, conceptIDs: [String])] = [:]

        // Lower tiers first: foundational concepts benefit most from grounding,
        // and the cap should not be spent entirely on expert-tier pages.
        for concept in store.allConcepts.sorted(by: { $0.tier < $1.tier }) {
            for page in Self.rank(pages, for: concept, excluding: curated, limit: pagesPerConcept) {
                if var existing = byURL[page.url] {
                    existing.conceptIDs.append(concept.id)
                    byURL[page.url] = existing
                } else if byURL.count < maxDiscoveredPages {
                    byURL[page.url] = (page, [concept.id])
                }
            }
        }
        return byURL.values.sorted { $0.page.url < $1.page.url }
    }
}
