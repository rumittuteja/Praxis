import Foundation

/// Selects the passages from the local corpus that should ground a lesson.
///
/// Retrieval, not stuffing: a docs page can be 40K characters and the whole
/// point of `context-engineering` is that relevance density beats volume. This
/// picks the paragraphs that actually mention the concept and spends a fixed
/// character budget on them.
struct DocsRetriever: Sendable {

    /// Total characters of source text handed to one generation. Roughly
    /// 3K tokens — enough to ground a lesson, small enough to stay cheap.
    var characterBudget = 12_000
    /// Most documents to draw from, so one long page can't crowd out the rest.
    var maxDocuments = 4
    /// Characters taken from any single document.
    var perDocumentBudget = 4_000

    func excerpts(for concept: Concept, in corpus: [DocSnapshot]) -> [RetrievedExcerpt] {
        let terms = Self.terms(for: concept)
        let ranked = corpus
            .map { (doc: $0, score: documentScore($0, concept: concept, terms: terms)) }
            .filter { $0.score > 0 }
            .sorted { $0.score == $1.score ? $0.doc.url < $1.doc.url : $0.score > $1.score }
            .prefix(maxDocuments)

        var out: [RetrievedExcerpt] = []
        var spent = 0

        for candidate in ranked {
            let remaining = characterBudget - spent
            guard remaining > 500 else { break }
            let text = passage(
                from: candidate.doc.content,
                terms: terms,
                budget: min(perDocumentBudget, remaining)
            )
            guard text.count > 120 else { continue }
            out.append(RetrievedExcerpt(title: candidate.doc.title, url: candidate.doc.url, text: text))
            spent += text.count
        }
        return out
    }

    // MARK: Scoring

    /// Search terms for a concept: its own ID tokens, title words, and the
    /// distinctive words from its key ideas.
    static func terms(for concept: Concept) -> [String] {
        var terms = Set<String>()
        for token in concept.id.split(separator: "-") where token.count >= 3 {
            terms.insert(String(token).lowercased())
        }
        for word in tokenize(concept.title) { terms.insert(word) }
        for idea in concept.keyIdeas {
            for word in tokenize(idea) where word.count >= 5 { terms.insert(word) }
        }
        return Array(terms)
    }

    private func documentScore(_ doc: DocSnapshot, concept: Concept, terms: [String]) -> Int {
        // A tag from the syllabus outranks any amount of keyword coincidence.
        // A discovered page is tagged too, but its tag came from a keyword
        // match, so it sits well below a curated source while still beating an
        // untagged document — enough to fill a gap, not enough to displace an
        // editorial choice.
        var score = 0
        if doc.conceptTags.contains(concept.id) {
            score += doc.isDiscovered ? 15 : 50
        }
        let haystack = (doc.title + " " + doc.content).lowercased()
        for term in terms where haystack.contains(term) { score += 1 }
        return score
    }

    // MARK: Passage selection

    /// Take the highest-scoring paragraphs, then re-emit them in document
    /// order so the excerpt still reads as prose rather than as shuffled
    /// fragments.
    private func passage(from content: String, terms: [String], budget: Int) -> String {
        guard content.count > budget else { return content }

        let paragraphs = content
            .components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.count > 40 }

        guard !paragraphs.isEmpty else { return String(content.prefix(budget)) }

        let scored = paragraphs.enumerated().map { index, text -> (index: Int, text: String, score: Int) in
            let lower = text.lowercased()
            let score = terms.reduce(0) { $0 + (lower.contains($1) ? 1 : 0) }
            return (index, text, score)
        }

        var chosen: [(index: Int, text: String)] = []
        var spent = 0
        for candidate in scored.sorted(by: { $0.score == $1.score ? $0.index < $1.index : $0.score > $1.score }) {
            guard candidate.score > 0 else { break }
            guard spent + candidate.text.count <= budget else { continue }
            chosen.append((candidate.index, candidate.text))
            spent += candidate.text.count
        }

        // Nothing matched: fall back to the opening, which on a docs page is
        // the overview and is rarely useless.
        if chosen.isEmpty { return String(content.prefix(budget)) }

        var pieces: [String] = []
        var previousIndex = -2
        for entry in chosen.sorted(by: { $0.index < $1.index }) {
            if entry.index > previousIndex + 1 && previousIndex >= 0 { pieces.append("[…]") }
            pieces.append(entry.text)
            previousIndex = entry.index
        }
        return pieces.joined(separator: "\n\n")
    }

    private static func tokenize(_ text: String) -> [String] {
        text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count >= 4 && !stopWords.contains($0) }
    }

    private static let stopWords: Set<String> = [
        "that", "this", "with", "from", "your", "into", "when", "what", "which",
        "they", "them", "then", "than", "have", "does", "will", "must", "each",
        "were", "been", "also", "only", "more", "most", "some", "such", "very",
        "over", "under", "about", "there", "these", "those", "their", "would",
        "could", "should", "because", "before", "after", "where", "while"
    ]
}
