import Testing
import Foundation
@testable import Praxis

@Suite("Source discovery")
struct SourceDiscoveryTests {

    /// Trimmed from the real https://code.claude.com/docs/llms.txt, so the
    /// parser is tested against the shape it will actually meet.
    private let llmsText = """
    # Claude Code Docs

    > Official documentation for Claude Code.

    ## Getting started

    - [Overview](https://code.claude.com/docs/en/overview.md): Claude Code is an agentic coding tool.
    - [Quickstart](https://code.claude.com/docs/en/quickstart.md): Welcome to Claude Code!

    ## Configuration

    - [Hooks reference](https://code.claude.com/docs/en/hooks.md): Reference for hook events.
    - [Settings](https://code.claude.com/docs/en/settings.md)
    """

    @Test("Link rows are parsed into pages")
    func parsesRows() {
        let pages = SourceDiscovery.parseLLMsText(llmsText, kind: .anthropicDocs)
        #expect(pages.count == 4)
        #expect(pages[0].title == "Overview")
        #expect(pages[0].url == "https://code.claude.com/docs/en/overview.md")
        #expect(pages[0].summary.contains("agentic coding tool"))
    }

    @Test("Section headings are carried onto the pages beneath them")
    func tracksSections() {
        let pages = SourceDiscovery.parseLLMsText(llmsText, kind: .anthropicDocs)
        #expect(pages[0].section == "Getting started")
        #expect(pages[2].section == "Configuration")
    }

    @Test("A row with no description still parses")
    func handlesMissingDescription() {
        let pages = SourceDiscovery.parseLLMsText(llmsText, kind: .anthropicDocs)
        let settings = pages.first { $0.title == "Settings" }
        #expect(settings != nil)
        #expect(settings?.summary.isEmpty == true)
    }

    @Test("Prose and headings are ignored")
    func ignoresNonLinkLines() {
        let pages = SourceDiscovery.parseLLMsText("# Title\n\n> A description.\n\nSome prose.",
                                                  kind: .anthropicDocs)
        #expect(pages.isEmpty)
    }

    @Test("Sitemaps yield only Bedrock user-guide pages")
    func parsesSitemap() {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <urlset>
          <url><loc>https://docs.aws.amazon.com/bedrock/latest/userguide/what-is-bedrock.html</loc></url>
          <url><loc>https://docs.aws.amazon.com/bedrock/latest/userguide/model-access.html</loc></url>
          <url><loc>https://docs.aws.amazon.com/lambda/latest/dg/welcome.html</loc></url>
          <url><loc>https://docs.aws.amazon.com/bedrock/latest/userguide/images/diagram.png</loc></url>
        </urlset>
        """
        let pages = SourceDiscovery.parseSitemap(xml)
        #expect(pages.count == 2, "non-Bedrock and non-HTML entries must be dropped")
        #expect(pages.allSatisfy { $0.kind == .awsBedrockDocs })
    }

    @Test("Titles are derived from URL slugs")
    func titleFromSlug() {
        #expect(SourceDiscovery.titleFromPath(
            "https://docs.aws.amazon.com/bedrock/latest/userguide/model-invocation-logging.html")
            == "Model invocation logging")
    }

    // MARK: Ranking

    private func concept(_ id: String, title: String, ideas: [String], sources: [String] = []) -> Concept {
        Concept(id: id, trackID: "t", title: title, tier: 2, summary: "",
                prerequisites: [], objectives: ["o"], keyIdeas: ideas,
                misconceptions: ["m"], practiceKinds: [.code],
                sources: sources.map { SourceRef(title: "s", url: $0, kind: .anthropicDocs) },
                estimatedMinutes: 5, requiresAWSAccount: nil)
    }

    private var samplePages: [DiscoveredPage] {
        [
            DiscoveredPage(title: "Hooks reference", url: "https://code.claude.com/docs/en/hooks.md",
                           summary: "Reference for Claude Code hook events.",
                           section: "Configuration", kind: .anthropicDocs),
            DiscoveredPage(title: "Gardening", url: "https://example.com/tomatoes.md",
                           summary: "Tomatoes prefer full sun.",
                           section: "Other", kind: .anthropicDocs)
        ]
    }

    @Test("Scoring is carried by id tokens and title words, not key ideas")
    func scoringWeights() {
        let hooks = concept("cc-hooks", title: "Hooks: automation the model can't skip",
                            ideas: ["Hooks are shell commands the harness runs on lifecycle events"])
        let good = DiscoveredPage(title: "Hooks reference",
                                  url: "https://code.claude.com/docs/en/hooks.md",
                                  summary: "Reference for hook events.",
                                  section: "Configuration", kind: .anthropicDocs)
        // Generic words from the key ideas alone must never clear the bar —
        // this is exactly how a flat keyword count matched cc-hooks to
        // "Cloud environment setup".
        let generic = DiscoveredPage(title: "Cloud environment setup",
                                     url: "https://code.claude.com/docs/en/cloud-environments.md",
                                     summary: "Configure events and commands for your environment.",
                                     section: "Configuration", kind: .anthropicDocs)

        #expect(SourceDiscovery.score(good, for: hooks) >= SourceDiscovery.relevanceThreshold)
        #expect(SourceDiscovery.score(generic, for: hooks) < SourceDiscovery.relevanceThreshold)
    }

    @Test("Key-idea matches are capped so they cannot qualify a page alone")
    func ideaWordsAreCapped() {
        let target = concept("zzz-unrelated", title: "Zzz Unrelated",
                             ideas: ["events commands harness lifecycle deterministic guarantee"])
        let page = DiscoveredPage(title: "events commands harness lifecycle deterministic guarantee",
                                  url: "https://example.com/x.md",
                                  summary: "events commands harness lifecycle deterministic guarantee",
                                  section: "events commands", kind: .anthropicDocs)
        #expect(SourceDiscovery.score(page, for: target) <= 3)
    }

    @Test("Relevant pages rank above irrelevant ones, which are dropped entirely")
    func ranksByRelevance() {
        let target = concept("cc-hooks", title: "Hooks: automation the model can't skip",
                             ideas: ["Hooks are shell commands the harness runs on lifecycle events"])
        let ranked = SourceDiscovery.rank(samplePages, for: target, excluding: [], limit: 5)
        #expect(ranked.count == 1)
        #expect(ranked.first?.title == "Hooks reference")
    }

    @Test("Curated URLs are excluded so the hand-picked source always wins")
    func skipsCurated() {
        let target = concept("cc-hooks", title: "Hooks", ideas: ["hooks lifecycle events"])
        let ranked = SourceDiscovery.rank(
            samplePages, for: target,
            excluding: ["https://code.claude.com/docs/en/hooks.md"], limit: 5
        )
        #expect(ranked.isEmpty)
    }

    @Test("The plan is capped so a first sync cannot fetch the whole doc site")
    func planIsCapped() {
        let pages = (0..<200).map { index in
            DiscoveredPage(title: "Prompt caching \(index)",
                           url: "https://docs.claude.com/page-prompt-caching-\(index).md",
                           summary: "prompt caching prefix breakpoints",
                           section: "Build", kind: .anthropicDocs)
        }
        let concepts = (0..<40).map { concept("prompt-caching-\($0)", title: "Prompt caching",
                                              ideas: ["caching prefix breakpoints"]) }
        let store = CurriculumStore(curriculum: Curriculum(
            version: 1, generatedNote: "",
            tracks: [Track(id: "t", title: "T", summary: "", order: 1)],
            concepts: concepts
        ))
        var discovery = SourceDiscovery()
        discovery.maxDiscoveredPages = 12
        #expect(discovery.plan(pages: pages, store: store).count <= 12)
    }
}

@Suite("Markdown source preference")
struct MarkdownVariantTests {

    @Test("Anthropic doc URLs get a .md twin")
    func addsSuffix() {
        #expect(DocsSyncService.markdownVariant(
            of: "https://docs.claude.com/en/docs/build-with-claude/prompt-caching")?.absoluteString
            == "https://docs.claude.com/en/docs/build-with-claude/prompt-caching.md")
        #expect(DocsSyncService.markdownVariant(
            of: "https://code.claude.com/docs/en/hooks")?.absoluteString
            == "https://code.claude.com/docs/en/hooks.md")
    }

    @Test("A trailing slash does not produce a double suffix")
    func handlesTrailingSlash() {
        #expect(DocsSyncService.markdownVariant(
            of: "https://code.claude.com/docs/en/hooks/")?.absoluteString
            == "https://code.claude.com/docs/en/hooks.md")
    }

    @Test("Hosts without markdown twins are left alone")
    func skipsOtherHosts() {
        #expect(DocsSyncService.markdownVariant(of: "https://docs.aws.amazon.com/bedrock/x.html") == nil)
        #expect(DocsSyncService.markdownVariant(of: "https://github.com/anthropics/courses") == nil)
    }

    @Test("A URL that is already .md is not doubled")
    func idempotent() {
        #expect(DocsSyncService.markdownVariant(of: "https://code.claude.com/docs/en/hooks.md") == nil)
    }

    @Test("Bare hosts are skipped")
    func skipsRoot() {
        #expect(DocsSyncService.markdownVariant(of: "https://docs.claude.com/") == nil)
    }
}

@Suite("Front matter")
struct FrontMatterTests {

    private let page = """
    ---
    title: Prompt caching
    url: https://platform.claude.com/docs/en/build-with-claude/prompt-caching
    description: Cache prompt prefixes.
    ---

    # Prompt caching

    Caching matches on an exact prefix.
    """

    @Test("The YAML block is stripped from the body")
    func strips() {
        let text = TextExtraction.fromMarkdown(page)
        #expect(!text.contains("description:"))
        #expect(text.contains("Caching matches on an exact prefix."))
    }

    @Test("The title comes from front matter when present")
    func title() {
        #expect(TextExtraction.frontMatterTitle(page) == "Prompt caching")
        #expect(TextExtraction.frontMatterTitle("# Just a heading\n\nbody") == nil)
    }

    @Test("Markdown without front matter is untouched")
    func passthrough() {
        let plain = "# Heading\n\nBody text that is long enough to survive."
        #expect(TextExtraction.fromMarkdown(plain).contains("Body text"))
        #expect(TextExtraction.fromMarkdown(plain).contains("# Heading"))
    }

    @Test("An unterminated block is left alone rather than eating the document")
    func unterminated() {
        let broken = "---\ntitle: Oops\n\nBody survives."
        #expect(TextExtraction.fromMarkdown(broken).contains("Body survives."))
    }
}

@Suite("Curriculum updates")
struct CurriculumUpdateTests {

    private func store(version: Int, conceptIDs: [String]) -> CurriculumStore {
        CurriculumStore(curriculum: Curriculum(
            version: version, generatedNote: "",
            tracks: [Track(id: "t", title: "T", summary: "", order: 1)],
            concepts: conceptIDs.map {
                Concept(id: $0, trackID: "t", title: $0, tier: 1, summary: "s",
                        prerequisites: [], objectives: ["o"], keyIdeas: ["k"],
                        misconceptions: ["m"], practiceKinds: [.explanation],
                        sources: [], estimatedMinutes: 5, requiresAWSAccount: nil)
            }
        ))
    }

    @Test("A store built from data reports its version")
    func versionRoundTrips() throws {
        let json = """
        {"version": 7, "generatedNote": "", "tracks": [], "concepts": []}
        """
        let decoded = try CurriculumStore(data: Data(json.utf8))
        #expect(decoded.curriculum.version == 7)
    }

    @Test("A store defaults to bundled origin")
    func defaultOrigin() {
        #expect(store(version: 1, conceptIDs: ["a"]).origin == .bundle)
    }

    @Test("A curriculum that removes a concept still validates")
    func removalIsValid() {
        // Progress rows for the removed concept are kept deliberately, so the
        // graph itself must not object to the concept being gone.
        #expect(store(version: 2, conceptIDs: ["a"]).integrityProblems().isEmpty)
    }

    @Test("The planner ignores progress for concepts the syllabus no longer has")
    func plannerSkipsOrphans() {
        // The scenario an update creates: a learner has history on a concept
        // that the new syllabus dropped. It must not consume a warm-up slot.
        let planner = SessionPlanner(store: store(version: 2, conceptIDs: ["still-here"]))
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let overdue = ReviewState(
            repetitions: 3, intervalDays: 6,
            dueDate: now.addingTimeInterval(-10 * 86_400),
            lastReviewed: now.addingTimeInterval(-16 * 86_400),
            masteryScore: 0.8, attempts: 3, state: .review
        )
        let session = planner.plan(PlannerInput(
            dailyGoalMinutes: 60,
            progress: ["still-here": overdue, "deleted-concept": overdue],
            now: now
        ))
        #expect(session.reviewConceptIDs == ["still-here"])
        #expect(!session.quizConceptIDs.contains("deleted-concept"))
        #expect(session.taskConceptID != "deleted-concept")
    }
}

@Suite("Curated versus discovered retrieval")
struct RetrievalPriorityTests {

    private func concept(_ id: String, title: String, ideas: [String]) -> Concept {
        Concept(id: id, trackID: "t", title: title, tier: 2, summary: "",
                prerequisites: [], objectives: ["o"], keyIdeas: ideas,
                misconceptions: ["m"], practiceKinds: [.code], sources: [],
                estimatedMinutes: 5, requiresAWSAccount: nil)
    }

    private func snapshot(url: String, title: String, discovered: Bool) -> DocSnapshot {
        DocSnapshot(url: url, source: .anthropicDocs, title: title,
                    content: String(repeating: "prompt caching prefix breakpoints. ", count: 40),
                    etag: nil, lastModified: nil,
                    conceptTags: ["api-prompt-caching"], isDiscovered: discovered)
    }

    @Test("A curated source outranks a discovered one tagged to the same concept")
    func curatedWins() {
        let target = concept("api-prompt-caching", title: "Prompt caching",
                             ideas: ["Caching matches on an exact prefix"])
        let discovered = snapshot(url: "https://a", title: "Discovered", discovered: true)
        let curated = snapshot(url: "https://b", title: "Curated", discovered: false)

        let excerpts = DocsRetriever().excerpts(for: target, in: [discovered, curated])
        #expect(excerpts.first?.url == "https://b")
    }

    @Test("A discovered page still beats an untagged document")
    func discoveredBeatsUntagged() {
        let target = concept("api-prompt-caching", title: "Prompt caching",
                             ideas: ["Caching matches on an exact prefix"])
        let discovered = snapshot(url: "https://a", title: "Discovered", discovered: true)
        let untagged = DocSnapshot(
            url: "https://c", source: .anthropicDocs, title: "Untagged",
            content: String(repeating: "caching prefix. ", count: 40),
            etag: nil, lastModified: nil, conceptTags: []
        )
        let excerpts = DocsRetriever().excerpts(for: target, in: [untagged, discovered])
        #expect(excerpts.first?.url == "https://a")
    }

    @Test("Snapshots default to curated, so existing data is unaffected")
    func defaultIsCurated() {
        let snapshot = DocSnapshot(url: "https://x", source: .anthropicDocs, title: "T",
                                   content: "body", etag: nil, lastModified: nil, conceptTags: [])
        #expect(snapshot.isDiscovered == false)
    }
}
