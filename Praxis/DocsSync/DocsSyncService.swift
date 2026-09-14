import Foundation

/// A document fetched from the network, ready to persist.
struct FetchedDocument: Sendable {
    var url: String
    var source: DocSourceKind
    var title: String
    var content: String
    var etag: String?
    var lastModified: String?
    var conceptTags: [String]
    var isDiscovered: Bool = false
}

/// Outcome of one sync run, shown in Settings.
struct SyncReport: Sendable {
    var fetched: Int = 0
    var unchanged: Int = 0
    var failed: Int = 0
    var skipped: Int = 0
    /// Pages found in the published documentation indexes this run.
    var discovered: Int = 0
    var messages: [String] = []
    var finishedAt = Date()

    var attempted: Int { fetched + unchanged + failed }
}

/// Builds the local corpus that grounds generated lessons.
///
/// There is no curriculum API to call — the material lives across Anthropic's
/// docs, the courses and cookbook repositories, and AWS's Bedrock guide. This
/// fetches those, extracts text, and tags each document with the concepts it
/// serves. Conditional requests mean a refresh is mostly cheap 304s.
struct DocsSyncService: Sendable {

    let credentials: CredentialStore

    private static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 45
        // We do our own validator handling, so don't let URLCache answer first.
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: config)
    }()

    init(credentials: CredentialStore = CredentialStore()) {
        self.credentials = credentials
    }

    // MARK: - Planning

    /// Every distinct source URL in the curriculum, with the concepts it serves.
    static func sourcePlan(for store: CurriculumStore) -> [(ref: SourceRef, conceptIDs: [String])] {
        var tags: [String: [String]] = [:]
        var refs: [String: SourceRef] = [:]
        for concept in store.allConcepts {
            for source in concept.sources {
                refs[source.url] = source
                tags[source.url, default: []].append(concept.id)
            }
        }
        return refs.values
            .sorted { $0.url < $1.url }
            .map { (ref: $0, conceptIDs: tags[$0.url] ?? []) }
    }

    // MARK: - Fetching

    /// Fetch one source. Returns nil when the server says nothing changed.
    ///
    /// - Parameter existing: validators from the stored snapshot, if any.
    func fetch(
        _ ref: SourceRef,
        conceptIDs: [String],
        existing: (etag: String?, lastModified: String?)?
    ) async throws -> FetchedDocument? {
        switch ref.kind {
        case .anthropicDocs, .awsBedrockDocs:
            return try await fetchWebPage(ref, conceptIDs: conceptIDs, existing: existing)
        case .courses, .cookbook:
            return try await fetchRepositoryDigest(ref, conceptIDs: conceptIDs)
        }
    }

    /// Hosts that serve a clean Markdown twin at `<page>.md`.
    ///
    /// Worth preferring: the Markdown is the same content without navigation,
    /// scripts or markup, so the model gets better text and `TextExtraction`
    /// does not have to guess which parts of a page were prose.
    private static let markdownHosts: Set<String> = [
        "docs.claude.com", "code.claude.com", "platform.claude.com"
    ]

    /// The `.md` twin of a documentation URL, when the host publishes one.
    static func markdownVariant(of urlString: String) -> URL? {
        guard let url = URL(string: urlString),
              let host = url.host,
              markdownHosts.contains(host),
              !url.path.hasSuffix(".md"),
              !url.path.isEmpty, url.path != "/"
        else { return nil }
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.path = url.path.hasSuffix("/")
            ? String(url.path.dropLast()) + ".md"
            : url.path + ".md"
        return components?.url
    }

    private func fetchWebPage(
        _ ref: SourceRef,
        conceptIDs: [String],
        existing: (etag: String?, lastModified: String?)?
    ) async throws -> FetchedDocument? {
        // Try the Markdown twin first; fall back to the HTML page if the host
        // does not have one for this path.
        if let markdown = Self.markdownVariant(of: ref.url),
           let document = try? await fetchOne(
               url: markdown, canonicalURL: ref.url, ref: ref,
               conceptIDs: conceptIDs, existing: existing
           ) {
            return document
        }
        guard let url = URL(string: ref.url) else { return nil }
        return try await fetchOne(
            url: url, canonicalURL: ref.url, ref: ref,
            conceptIDs: conceptIDs, existing: existing
        )
    }

    /// Fetch one URL and turn it into a document.
    ///
    /// `canonicalURL` is what gets stored and cited, so a page fetched via its
    /// `.md` twin is still attributed to the human-readable page.
    private func fetchOne(
        url: URL,
        canonicalURL: String,
        ref: SourceRef,
        conceptIDs: [String],
        existing: (etag: String?, lastModified: String?)?
    ) async throws -> FetchedDocument? {
        var request = URLRequest(url: url)
        request.setValue("text/markdown,text/html,text/plain", forHTTPHeaderField: "Accept")
        if let etag = existing?.etag { request.setValue(etag, forHTTPHeaderField: "If-None-Match") }
        if let modified = existing?.lastModified {
            request.setValue(modified, forHTTPHeaderField: "If-Modified-Since")
        }

        let (data, response) = try await Self.session.data(for: request)
        guard let http = response as? HTTPURLResponse else { return nil }
        if http.statusCode == 304 { return nil }
        guard (200..<300).contains(http.statusCode) else {
            throw LLMError.http(status: http.statusCode, body: "Could not fetch \(ref.url)")
        }
        guard let body = String(data: data, encoding: .utf8) else {
            throw LLMError.malformedResponse("\(ref.url) was not UTF-8 text.")
        }

        let contentType = http.value(forHTTPHeaderField: "Content-Type")?.lowercased() ?? ""
        let text = contentType.contains("html")
            ? TextExtraction.fromHTML(body)
            : TextExtraction.fromMarkdown(body)

        guard text.count > 200 else {
            throw LLMError.malformedResponse("\(canonicalURL) yielded almost no text.")
        }

        let title = TextExtraction.frontMatterTitle(body)
            ?? TextExtraction.htmlTitle(body)
            ?? TextExtraction.inferTitle(from: text, fallback: ref.title)

        return FetchedDocument(
            url: canonicalURL,
            source: ref.kind,
            title: title,
            content: text,
            etag: http.value(forHTTPHeaderField: "Etag"),
            lastModified: http.value(forHTTPHeaderField: "Last-Modified"),
            conceptTags: conceptIDs
        )
    }

    /// Fetch a page found by `SourceDiscovery`. Same path as a curated source;
    /// the only difference is where the URL came from.
    func fetch(
        discovered page: DiscoveredPage,
        conceptIDs: [String],
        existing: (etag: String?, lastModified: String?)?
    ) async throws -> FetchedDocument? {
        var document = try await fetch(
            SourceRef(title: page.title, url: page.url, kind: page.kind),
            conceptIDs: conceptIDs,
            existing: existing
        )
        document?.isDiscovered = true
        return document
    }

    // MARK: - GitHub repositories

    /// A repo source is a whole repository, so it can't be fetched as one page.
    /// Instead: list the tree, pick the files whose paths best match the
    /// concepts this source serves, and stitch those into one digest document.
    private func fetchRepositoryDigest(_ ref: SourceRef, conceptIDs: [String]) async throws -> FetchedDocument? {
        guard let (owner, repo) = Self.parseRepo(ref.url) else { return nil }

        let paths = try await repositoryFilePaths(owner: owner, repo: repo)
        guard !paths.isEmpty else {
            throw LLMError.malformedResponse("No documents found in \(owner)/\(repo).")
        }

        let keywords = Self.keywords(from: conceptIDs)
        let ranked = paths
            .map { (path: $0, score: Self.score(path: $0, keywords: keywords)) }
            .filter { $0.score > 0 }
            .sorted { $0.score == $1.score ? $0.path < $1.path : $0.score > $1.score }
            .prefix(4)

        var sections: [String] = []
        for candidate in ranked {
            guard let text = try? await rawFile(owner: owner, repo: repo, path: candidate.path),
                  !text.isEmpty else { continue }
            sections.append("### \(candidate.path)\n\n\(text)")
        }
        guard !sections.isEmpty else {
            throw LLMError.malformedResponse("Nothing relevant found in \(owner)/\(repo).")
        }

        return FetchedDocument(
            url: ref.url,
            source: ref.kind,
            title: "\(owner)/\(repo)",
            content: TextExtraction.fromMarkdown(sections.joined(separator: "\n\n---\n\n")),
            etag: nil,
            lastModified: nil,
            conceptTags: conceptIDs
        )
    }

    private func repositoryFilePaths(owner: String, repo: String) async throws -> [String] {
        let endpoint = "https://api.github.com/repos/\(owner)/\(repo)/git/trees/HEAD?recursive=1"
        guard let url = URL(string: endpoint) else { return [] }

        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        // Anonymous GitHub allows 60 requests/hour. A token raises that
        // substantially; the app works without one.
        if let token = credentials.value(for: .githubToken) {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        let (data, response) = try await Self.session.data(for: request)
        guard let http = response as? HTTPURLResponse else { return [] }
        guard (200..<300).contains(http.statusCode) else {
            if http.statusCode == 403 || http.statusCode == 429 {
                throw LLMError.rateLimited(retryAfter: nil)
            }
            throw LLMError.http(status: http.statusCode, body: "GitHub tree for \(owner)/\(repo)")
        }

        guard let root = try? JSONDecoder().decode(JSONValue.self, from: data),
              let tree = root["tree"]?.arrayValue else { return [] }

        return tree.compactMap { node -> String? in
            guard node["type"]?.stringValue == "blob",
                  let path = node["path"]?.stringValue else { return nil }
            let lower = path.lowercased()
            guard lower.hasSuffix(".md") || lower.hasSuffix(".ipynb") else { return nil }
            return path
        }
    }

    private func rawFile(owner: String, repo: String, path: String) async throws -> String? {
        let encoded = path
            .split(separator: "/")
            .map { $0.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? String($0) }
            .joined(separator: "/")
        guard let url = URL(string: "https://raw.githubusercontent.com/\(owner)/\(repo)/HEAD/\(encoded)") else {
            return nil
        }

        let (data, response) = try await Self.session.data(from: url)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            return nil
        }
        if path.lowercased().hasSuffix(".ipynb") {
            return TextExtraction.fromNotebook(data)
        }
        return String(data: data, encoding: .utf8).map(TextExtraction.fromMarkdown)
    }

    // MARK: - Matching

    static func parseRepo(_ urlString: String) -> (owner: String, repo: String)? {
        guard let url = URL(string: urlString), url.host?.contains("github.com") == true else { return nil }
        let parts = url.path.split(separator: "/").map(String.init)
        guard parts.count >= 2 else { return nil }
        return (parts[0], parts[1].replacingOccurrences(of: ".git", with: ""))
    }

    /// Concept IDs are hyphenated and descriptive ("bedrock-invoke-model"), so
    /// their tokens make serviceable search keys against repository paths.
    static func keywords(from conceptIDs: [String]) -> Set<String> {
        var out = Set<String>()
        for id in conceptIDs {
            for token in id.split(separator: "-") where token.count >= 3 {
                out.insert(String(token).lowercased())
            }
        }
        return out
    }

    static func score(path: String, keywords: Set<String>) -> Int {
        let lower = path.lowercased()
        var score = keywords.reduce(0) { $0 + (lower.contains($1) ? 2 : 0) }
        // Prefer curated top-level material over deeply nested extras.
        if lower.split(separator: "/").count <= 2 { score += 1 }
        if lower.hasSuffix("readme.md") { score += 1 }
        return score
    }
}
