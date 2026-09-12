import Foundation

/// Reduces fetched documents to plain text suitable for a model's context.
///
/// Deliberately regex-based rather than a real HTML parser: the goal is not
/// fidelity, it's getting the prose out of a docs page without pulling in a
/// dependency or bouncing through `NSAttributedString`, which is slow and
/// wants the main thread.
enum TextExtraction {

    /// Longest excerpt kept per document. Roughly 10K tokens — generous for a
    /// single doc page and well short of anything that would crowd a prompt.
    static let maxCharacters = 40_000

    static func fromHTML(_ html: String) -> String {
        var text = html

        // Drop whole elements whose contents are never prose.
        for tag in ["script", "style", "noscript", "svg", "head", "nav", "footer"] {
            text = replacing(text, pattern: "<\(tag)\\b[^>]*>[\\s\\S]*?</\(tag)>", with: " ")
        }
        // Keep block structure as newlines so paragraphs don't run together.
        text = replacing(text, pattern: "<(br|/p|/div|/li|/h[1-6]|/tr)\\s*/?>", with: "\n")
        text = replacing(text, pattern: "<li\\b[^>]*>", with: "\n- ")
        text = replacing(text, pattern: "<[^>]+>", with: " ")

        text = decodingEntities(text)
        return normalizeWhitespace(text)
    }

    static func fromMarkdown(_ markdown: String) -> String {
        // Markdown is already close to what we want; just bound the size.
        normalizeWhitespace(markdown)
    }

    /// Pull the prose and code out of a Jupyter notebook.
    ///
    /// The cookbook and courses repos are largely notebooks, and their `source`
    /// arrays hold the material worth teaching from. Outputs are dropped: they
    /// are mostly rendered noise and occasionally enormous.
    static func fromNotebook(_ data: Data) -> String? {
        guard let root = try? JSONDecoder().decode(JSONValue.self, from: data),
              let cells = root["cells"]?.arrayValue else { return nil }

        var pieces: [String] = []
        for cell in cells {
            let type = cell["cell_type"]?.stringValue ?? ""
            let source: String
            if let lines = cell["source"]?.arrayValue {
                source = lines.compactMap(\.stringValue).joined()
            } else if let single = cell["source"]?.stringValue {
                source = single
            } else {
                continue
            }
            let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }

            switch type {
            case "markdown": pieces.append(trimmed)
            case "code":     pieces.append("```python\n\(trimmed)\n```")
            default:         continue
            }
        }
        guard !pieces.isEmpty else { return nil }
        return normalizeWhitespace(pieces.joined(separator: "\n\n"))
    }

    /// First Markdown heading, or the HTML <title>, as a display name.
    static func inferTitle(from text: String, fallback: String) -> String {
        for line in text.split(separator: "\n", maxSplits: 40, omittingEmptySubsequences: true) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("#") {
                let title = trimmed.drop(while: { $0 == "#" }).trimmingCharacters(in: .whitespaces)
                if !title.isEmpty { return String(title.prefix(120)) }
            }
        }
        return fallback
    }

    static func htmlTitle(_ html: String) -> String? {
        guard let range = html.range(of: "<title[^>]*>([\\s\\S]*?)</title>",
                                     options: [.regularExpression, .caseInsensitive]) else { return nil }
        let raw = String(html[range])
        let inner = replacing(raw, pattern: "</?title[^>]*>", with: "")
        let cleaned = decodingEntities(inner).trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? nil : String(cleaned.prefix(120))
    }

    // MARK: Helpers

    private static func replacing(_ text: String, pattern: String, with replacement: String) -> String {
        text.replacingOccurrences(
            of: pattern,
            with: replacement,
            options: [.regularExpression, .caseInsensitive]
        )
    }

    private static func decodingEntities(_ text: String) -> String {
        var out = text
        let entities: [(String, String)] = [
            ("&nbsp;", " "), ("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"),
            ("&quot;", "\""), ("&#39;", "'"), ("&apos;", "'"), ("&mdash;", "—"),
            ("&ndash;", "–"), ("&hellip;", "…"), ("&rsquo;", "'"), ("&lsquo;", "'"),
            ("&ldquo;", "\""), ("&rdquo;", "\"")
        ]
        for (entity, character) in entities {
            out = out.replacingOccurrences(of: entity, with: character)
        }
        // Numeric entities.
        out = replacing(out, pattern: "&#x?[0-9A-Fa-f]+;", with: " ")
        return out
    }

    private static func normalizeWhitespace(_ text: String) -> String {
        var out = text.replacingOccurrences(of: "\r\n", with: "\n")
        out = replacing(out, pattern: "[ \\t]+", with: " ")
        out = replacing(out, pattern: "\\n{3,}", with: "\n\n")
        out = out.trimmingCharacters(in: .whitespacesAndNewlines)
        if out.count > maxCharacters {
            let cut = out.index(out.startIndex, offsetBy: maxCharacters)
            out = String(out[..<cut]) + "\n\n[truncated]"
        }
        return out
    }
}
