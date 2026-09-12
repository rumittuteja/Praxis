import SwiftUI

/// A block of parsed Markdown.
enum MarkdownBlock: Identifiable, Hashable {
    case heading(level: Int, text: String)
    case paragraph(String)
    case bullet(items: [String])
    case numbered(items: [String])
    case code(language: String?, body: String)
    case quote(String)
    case rule

    var id: String {
        switch self {
        case .heading(let level, let text): return "h\(level):\(text)"
        case .paragraph(let text):          return "p:\(text.prefix(64))"
        case .bullet(let items):            return "ul:\(items.joined().prefix(64))"
        case .numbered(let items):          return "ol:\(items.joined().prefix(64))"
        case .code(_, let body):            return "code:\(body.prefix(64))"
        case .quote(let text):              return "q:\(text.prefix(64))"
        case .rule:                         return "hr:\(UUID().uuidString)"
        }
    }
}

/// Block-level Markdown parser.
///
/// `AttributedString(markdown:)` handles inline emphasis and links but flattens
/// everything into one paragraph — no headings, no fenced code, no lists. Since
/// generated lessons lean on all three, blocks are parsed here and inline
/// formatting is left to `AttributedString` within each block.
enum MarkdownParser {

    static func parse(_ source: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        var paragraph: [String] = []
        var listItems: [String] = []
        var listIsNumbered = false
        var codeLines: [String] = []
        var codeLanguage: String?
        var inCode = false

        func flushParagraph() {
            let text = paragraph.joined(separator: " ").trimmingCharacters(in: .whitespaces)
            if !text.isEmpty { blocks.append(.paragraph(text)) }
            paragraph.removeAll()
        }
        func flushList() {
            if !listItems.isEmpty {
                blocks.append(listIsNumbered ? .numbered(items: listItems) : .bullet(items: listItems))
                listItems.removeAll()
            }
        }
        func flushAll() { flushParagraph(); flushList() }

        for rawLine in source.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: CharacterSet(charactersIn: " \t"))

            // Fenced code: everything inside is preserved verbatim.
            if line.hasPrefix("```") {
                if inCode {
                    blocks.append(.code(language: codeLanguage, body: codeLines.joined(separator: "\n")))
                    codeLines.removeAll()
                    codeLanguage = nil
                    inCode = false
                } else {
                    flushAll()
                    let tag = line.dropFirst(3).trimmingCharacters(in: .whitespaces)
                    codeLanguage = tag.isEmpty ? nil : tag
                    inCode = true
                }
                continue
            }
            if inCode { codeLines.append(rawLine); continue }

            if line.isEmpty { flushAll(); continue }

            if line.hasPrefix("#") {
                flushAll()
                let hashes = line.prefix(while: { $0 == "#" }).count
                let text = line.dropFirst(hashes).trimmingCharacters(in: .whitespaces)
                blocks.append(.heading(level: min(hashes, 4), text: text))
                continue
            }

            if line == "---" || line == "***" || line == "___" {
                flushAll()
                blocks.append(.rule)
                continue
            }

            if line.hasPrefix("> ") || line == ">" {
                flushAll()
                blocks.append(.quote(String(line.dropFirst(line.hasPrefix("> ") ? 2 : 1))))
                continue
            }

            if line.hasPrefix("- ") || line.hasPrefix("* ") {
                flushParagraph()
                if listIsNumbered { flushList(); listIsNumbered = false }
                listItems.append(String(line.dropFirst(2)))
                continue
            }

            if let match = line.range(of: "^\\d+[.)] ", options: .regularExpression) {
                flushParagraph()
                if !listIsNumbered { flushList(); listIsNumbered = true }
                listItems.append(String(line[match.upperBound...]))
                continue
            }

            flushList()
            paragraph.append(line)
        }

        if inCode && !codeLines.isEmpty {
            // Unterminated fence — keep the content rather than dropping it.
            blocks.append(.code(language: codeLanguage, body: codeLines.joined(separator: "\n")))
        }
        flushAll()
        return blocks
    }

    /// Inline formatting only. Falls back to the raw string if the markdown is
    /// malformed, which is better than rendering nothing.
    static func inline(_ text: String) -> AttributedString {
        (try? AttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(text)
    }
}

/// Renders Markdown with the app's type scale.
struct MarkdownView: View {
    @Environment(\.colorScheme) private var scheme
    let markdown: String
    var baseSize: CGFloat = 16

    private var blocks: [MarkdownBlock] { MarkdownParser.parse(markdown) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(blocks) { block in
                switch block {
                case .heading(let level, let text):
                    Text(MarkdownParser.inline(text))
                        .font(headingFont(level))
                        .foregroundStyle(Palette.ink(scheme))
                        .padding(.top, level <= 2 ? 6 : 2)
                        .fixedSize(horizontal: false, vertical: true)

                case .paragraph(let text):
                    Text(MarkdownParser.inline(text))
                        .font(Typeface.body(baseSize))
                        .foregroundStyle(Palette.ink(scheme))
                        .lineSpacing(Metrics.proseLineSpacing)
                        .fixedSize(horizontal: false, vertical: true)

                case .bullet(let items):
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                            listRow(marker: "•", text: item)
                        }
                    }

                case .numbered(let items):
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                            listRow(marker: "\(index + 1).", text: item)
                        }
                    }

                case .code(let language, let body):
                    CodeBlock(code: body, language: language)

                case .quote(let text):
                    HStack(alignment: .top, spacing: 10) {
                        Rectangle()
                            .fill(Palette.accent)
                            .frame(width: 3)
                        Text(MarkdownParser.inline(text))
                            .font(Typeface.body(baseSize))
                            .foregroundStyle(Palette.inkSecondary(scheme))
                            .lineSpacing(Metrics.proseLineSpacing)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .fixedSize(horizontal: false, vertical: true)

                case .rule:
                    Rectangle()
                        .fill(Palette.hairline(scheme))
                        .frame(height: 1)
                        .padding(.vertical, 2)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
    }

    private func listRow(marker: String, text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(marker)
                .font(Typeface.body(baseSize))
                .foregroundStyle(Palette.inkTertiary(scheme))
                .frame(minWidth: 16, alignment: .trailing)
            Text(MarkdownParser.inline(text))
                .font(Typeface.body(baseSize))
                .foregroundStyle(Palette.ink(scheme))
                .lineSpacing(Metrics.proseLineSpacing - 2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func headingFont(_ level: Int) -> Font {
        switch level {
        case 1:  return Typeface.display(baseSize + 8)
        case 2:  return Typeface.semibold(baseSize + 3)
        case 3:  return Typeface.semibold(baseSize + 1)
        default: return Typeface.semibold(baseSize)
        }
    }
}
