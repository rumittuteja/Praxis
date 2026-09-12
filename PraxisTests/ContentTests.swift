import Testing
import Foundation
@testable import Praxis

@Suite("Markdown parsing")
struct MarkdownTests {

    @Test("Headings are parsed with their level")
    func headings() {
        let blocks = MarkdownParser.parse("# One\n\n## Two\n\n### Three")
        #expect(blocks.count == 3)
        if case .heading(let level, let text) = blocks[0] {
            #expect(level == 1)
            #expect(text == "One")
        } else { Issue.record("expected a heading") }
        if case .heading(let level, _) = blocks[1] { #expect(level == 2) }
    }

    @Test("Fenced code blocks keep their language and content verbatim")
    func fencedCode() {
        let source = """
        Intro paragraph.

        ```swift
        let x = 1
            let y = 2
        ```

        After.
        """
        let blocks = MarkdownParser.parse(source)
        let code = blocks.compactMap { block -> (String?, String)? in
            if case .code(let language, let body) = block { return (language, body) }
            return nil
        }
        #expect(code.count == 1)
        #expect(code[0].0 == "swift")
        // Indentation inside a fence must survive.
        #expect(code[0].1 == "let x = 1\n    let y = 2")
    }

    @Test("Markdown syntax inside a fence is not interpreted")
    func codeFenceIsOpaque() {
        let blocks = MarkdownParser.parse("```\n# not a heading\n- not a list\n```")
        #expect(blocks.count == 1)
        if case .code(_, let body) = blocks[0] {
            #expect(body.contains("# not a heading"))
        } else { Issue.record("expected a code block") }
    }

    @Test("Bullet and numbered lists are grouped")
    func lists() {
        let blocks = MarkdownParser.parse("- one\n- two\n\n1. first\n2. second")
        let bullets = blocks.compactMap { block -> [String]? in
            if case .bullet(let items) = block { return items }
            return nil
        }
        let numbered = blocks.compactMap { block -> [String]? in
            if case .numbered(let items) = block { return items }
            return nil
        }
        #expect(bullets.first?.count == 2)
        #expect(numbered.first == ["first", "second"])
    }

    @Test("Consecutive lines join into one paragraph")
    func paragraphJoining() {
        let blocks = MarkdownParser.parse("line one\nline two\n\nsecond para")
        let paragraphs = blocks.compactMap { block -> String? in
            if case .paragraph(let text) = block { return text }
            return nil
        }
        #expect(paragraphs == ["line one line two", "second para"])
    }

    @Test("An unterminated code fence still yields its content")
    func unterminatedFence() {
        let blocks = MarkdownParser.parse("text\n\n```swift\nlet x = 1")
        #expect(blocks.contains { if case .code = $0 { return true }; return false })
    }

    @Test("Empty input produces no blocks")
    func empty() {
        #expect(MarkdownParser.parse("").isEmpty)
        #expect(MarkdownParser.parse("\n\n   \n").isEmpty)
    }

    @Test("Malformed inline markdown falls back to the raw text")
    func inlineFallback() {
        let result = MarkdownParser.inline("unclosed **bold and [link](")
        #expect(!String(result.characters).isEmpty)
    }
}

@Suite("Text extraction")
struct TextExtractionTests {

    @Test("Script and style contents are dropped from HTML")
    func stripsNonProse() {
        let html = """
        <html><head><title>Doc Title</title><style>.a{color:red}</style></head>
        <body><script>alert('x')</script><p>Real content here.</p></body></html>
        """
        let text = TextExtraction.fromHTML(html)
        #expect(text.contains("Real content here."))
        #expect(!text.contains("alert"))
        #expect(!text.contains("color:red"))
    }

    @Test("The HTML title is recovered")
    func htmlTitle() {
        #expect(TextExtraction.htmlTitle("<html><title>Prompt caching</title></html>")
            == "Prompt caching")
        #expect(TextExtraction.htmlTitle("<html><body>no title</body></html>") == nil)
    }

    @Test("Entities are decoded")
    func entities() {
        let text = TextExtraction.fromHTML("<p>a &amp; b &lt;tag&gt; &quot;q&quot;</p>")
        #expect(text.contains("a & b"))
        #expect(text.contains("<tag>"))
    }

    @Test("Block elements become line breaks rather than running together")
    func blockStructure() {
        let text = TextExtraction.fromHTML("<p>First</p><p>Second</p>")
        #expect(text.contains("First"))
        #expect(text.contains("Second"))
        #expect(!text.contains("FirstSecond"))
    }

    @Test("Notebook markdown and code cells are extracted, outputs are not")
    func notebook() throws {
        let notebook = """
        {"cells":[
          {"cell_type":"markdown","source":["# Title\\n","Some prose."]},
          {"cell_type":"code","source":["print('hi')"],"outputs":[{"text":"NOISE"}]},
          {"cell_type":"raw","source":["ignored"]}
        ]}
        """
        let text = try #require(TextExtraction.fromNotebook(Data(notebook.utf8)))
        #expect(text.contains("Some prose."))
        #expect(text.contains("print('hi')"))
        #expect(text.contains("```python"))
        #expect(!text.contains("NOISE"))
    }

    @Test("A non-notebook payload returns nil rather than garbage")
    func notebookRejectsOtherJSON() {
        #expect(TextExtraction.fromNotebook(Data(#"{"not":"a notebook"}"#.utf8)) == nil)
    }

    @Test("Very long documents are truncated to the cap")
    func truncation() {
        let long = String(repeating: "word ", count: 200_000)
        let text = TextExtraction.fromMarkdown(long)
        #expect(text.count <= TextExtraction.maxCharacters + 32)
        #expect(text.hasSuffix("[truncated]"))
    }

    @Test("A Markdown heading supplies a title when there's no HTML one")
    func inferredTitle() {
        #expect(TextExtraction.inferTitle(from: "## Tool use\n\nbody", fallback: "x") == "Tool use")
        #expect(TextExtraction.inferTitle(from: "no heading here", fallback: "Fallback") == "Fallback")
    }
}

@Suite("Docs retrieval")
struct DocsRetrieverTests {

    private func concept(_ id: String, title: String, ideas: [String]) -> Concept {
        Concept(id: id, trackID: "t", title: title, tier: 2, summary: "",
                prerequisites: [], objectives: ["o"], keyIdeas: ideas,
                misconceptions: ["m"], practiceKinds: [.code], sources: [],
                estimatedMinutes: 5, requiresAWSAccount: nil)
    }

    private func snapshot(url: String, title: String, content: String,
                          tags: [String]) -> DocSnapshot {
        DocSnapshot(url: url, source: .anthropicDocs, title: title, content: content,
                    etag: nil, lastModified: nil, conceptTags: tags)
    }

    @Test("An explicitly tagged document outranks a keyword coincidence")
    func tagsOutrankKeywords() {
        let target = concept("api-prompt-caching", title: "Prompt caching",
                             ideas: ["Caching matches on an exact prefix"])
        let tagged = snapshot(url: "https://a", title: "Tagged",
                              content: String(repeating: "unrelated words. ", count: 40),
                              tags: ["api-prompt-caching"])
        let keywordy = snapshot(url: "https://b", title: "Caching prefix caching",
                                content: String(repeating: "caching prefix exact matches. ", count: 40),
                                tags: [])

        let excerpts = DocsRetriever().excerpts(for: target, in: [keywordy, tagged])
        #expect(excerpts.first?.url == "https://a")
    }

    @Test("Irrelevant documents are excluded entirely")
    func filtersIrrelevant() {
        let target = concept("bedrock-streaming", title: "Streaming on Bedrock",
                             ideas: ["AWS event stream framing"])
        let unrelated = snapshot(url: "https://z", title: "Gardening",
                                 content: "Tomatoes prefer full sun and regular watering.",
                                 tags: [])
        #expect(DocsRetriever().excerpts(for: target, in: [unrelated]).isEmpty)
    }

    @Test("Retrieval stays inside its character budget")
    func respectsBudget() {
        let target = concept("api-streaming", title: "Streaming",
                             ideas: ["Server sent events deliver deltas"])
        let docs = (0..<10).map { index in
            snapshot(url: "https://d\(index)", title: "Streaming doc \(index)",
                     content: String(repeating: "streaming events deltas server. ", count: 3_000),
                     tags: ["api-streaming"])
        }
        var retriever = DocsRetriever()
        retriever.characterBudget = 6_000
        retriever.perDocumentBudget = 2_000

        let excerpts = retriever.excerpts(for: target, in: docs)
        let total = excerpts.reduce(0) { $0 + $1.text.count }
        #expect(total <= 6_000)
        #expect(excerpts.count <= retriever.maxDocuments)
    }

    @Test("Search terms come from the id, title, and key ideas")
    func termExtraction() {
        let target = concept("bedrock-invoke-model", title: "Calling InvokeModel",
                             ideas: ["The body carries anthropic_version"])
        let terms = DocsRetriever.terms(for: target)
        #expect(terms.contains("bedrock"))
        #expect(terms.contains("invoke"))
        #expect(terms.contains("model"))
        // Short filler words are not useful search keys.
        #expect(!terms.contains("the"))
    }
}

@Suite("GitHub source matching")
struct DocsSyncMatchingTests {

    @Test("Repository URLs are parsed into owner and repo")
    func parsesRepoURL() throws {
        let parsed = try #require(DocsSyncService.parseRepo("https://github.com/anthropics/courses"))
        #expect(parsed.owner == "anthropics")
        #expect(parsed.repo == "courses")
        #expect(DocsSyncService.parseRepo("https://docs.claude.com/en/api/messages") == nil)
    }

    @Test("Concept ids become search keywords")
    func keywords() {
        let keywords = DocsSyncService.keywords(from: ["prompt-caching", "api-streaming"])
        #expect(keywords.contains("prompt"))
        #expect(keywords.contains("caching"))
        #expect(keywords.contains("streaming"))
        // Two-letter fragments are too noisy to match on.
        #expect(!keywords.contains("ap"))
    }

    @Test("Paths matching more keywords score higher")
    func pathScoring() {
        let keywords: Set<String> = ["prompt", "caching"]
        let good = DocsSyncService.score(path: "prompt_caching/README.md", keywords: keywords)
        let poor = DocsSyncService.score(path: "misc/deep/nested/other.md", keywords: keywords)
        #expect(good > poor)
    }
}
