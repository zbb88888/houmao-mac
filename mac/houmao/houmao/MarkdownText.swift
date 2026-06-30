import SwiftUI

// MARK: - Block-level Markdown rendering (zero dependency)
//
// `Text(AttributedString(markdown:))` only understands *inline* syntax; with
// `.inlineOnlyPreservingWhitespace` it collapses headings / lists / fenced code
// blocks / quotes into a single paragraph, leaving the raw `#`, `-`, ``` markers
// visible. LLM chat replies lean heavily on those block constructs, so we parse
// the source into block elements and render each with an appropriate SwiftUI
// view. Inline emphasis inside a block is still delegated to AttributedString.

struct MarkdownText: View {
    let text: String
    var textColor: Color = .primary
    var baseFontSize: CGFloat = 14

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            let blocks = MarkdownBlock.parse(text)
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                blockView(block)
            }
        }
    }

    @ViewBuilder
    private func blockView(_ block: MarkdownBlock) -> some View {
        switch block {
        case .heading(let level, let content):
            Text(inline(content))
                .font(.system(size: headingSize(level), weight: .semibold))
                .foregroundColor(textColor)
                .fixedSize(horizontal: false, vertical: true)

        case .paragraph(let content):
            Text(inline(content))
                .font(.system(size: baseFontSize))
                .foregroundColor(textColor)
                .fixedSize(horizontal: false, vertical: true)

        case .bulleted(let items):
            VStack(alignment: .leading, spacing: 3) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .top, spacing: 6) {
                        Text("•")
                            .font(.system(size: baseFontSize))
                            .foregroundColor(textColor.opacity(0.8))
                        Text(inline(item))
                            .font(.system(size: baseFontSize))
                            .foregroundColor(textColor)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }

        case .numbered(let items):
            VStack(alignment: .leading, spacing: 3) {
                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                    HStack(alignment: .top, spacing: 6) {
                        Text("\(index + 1).")
                            .font(.system(size: baseFontSize, weight: .medium))
                            .foregroundColor(textColor.opacity(0.8))
                        Text(inline(item))
                            .font(.system(size: baseFontSize))
                            .foregroundColor(textColor)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }

        case .quote(let content):
            HStack(alignment: .top, spacing: 8) {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(Color.secondary.opacity(0.4))
                    .frame(width: 3)
                Text(inline(content))
                    .font(.system(size: baseFontSize))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

        case .code(let code, _):
            Text(code)
                .font(.system(size: baseFontSize - 1.5, design: .monospaced))
                .foregroundColor(textColor)
                .textSelection(.enabled)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.secondary.opacity(0.14))
                )
        }
    }

    private func headingSize(_ level: Int) -> CGFloat {
        switch level {
        case 1: return baseFontSize + 6
        case 2: return baseFontSize + 4
        case 3: return baseFontSize + 2
        default: return baseFontSize + 1
        }
    }

    private func inline(_ source: String) -> AttributedString {
        (try? AttributedString(
            markdown: source,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(source)
    }
}

// MARK: - Block parser

enum MarkdownBlock {
    case heading(level: Int, text: String)
    case paragraph(String)
    case bulleted([String])
    case numbered([String])
    case quote(String)
    case code(String, language: String?)

    /// Split raw Markdown into block elements. Intentionally small: covers the
    /// constructs LLM replies actually emit (headings, fenced code, bullet /
    /// ordered lists, blockquotes, paragraphs). Unterminated fenced blocks
    /// (mid-stream) consume to end-of-text, which is the desired streaming UX.
    static func parse(_ source: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        let lines = source.components(separatedBy: "\n")
        var i = 0

        var paragraphBuffer: [String] = []
        func flushParagraph() {
            guard !paragraphBuffer.isEmpty else { return }
            let joined = paragraphBuffer.joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !joined.isEmpty { blocks.append(.paragraph(joined)) }
            paragraphBuffer.removeAll()
        }

        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Fenced code block.
            if trimmed.hasPrefix("```") {
                flushParagraph()
                let lang = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                var codeLines: [String] = []
                i += 1
                while i < lines.count,
                      !lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                    codeLines.append(lines[i])
                    i += 1
                }
                i += 1 // skip the closing fence (no-op at EOF)
                blocks.append(.code(codeLines.joined(separator: "\n"),
                                    language: lang.isEmpty ? nil : lang))
                continue
            }

            // ATX heading.
            if let level = headingLevel(trimmed) {
                flushParagraph()
                let content = String(trimmed.dropFirst(level)).trimmingCharacters(in: .whitespaces)
                blocks.append(.heading(level: level, text: content))
                i += 1
                continue
            }

            // Blockquote (consecutive `>` lines).
            if trimmed.hasPrefix(">") {
                flushParagraph()
                var quoteLines: [String] = []
                while i < lines.count,
                      lines[i].trimmingCharacters(in: .whitespaces).hasPrefix(">") {
                    let t = lines[i].trimmingCharacters(in: .whitespaces)
                    quoteLines.append(String(t.dropFirst()).trimmingCharacters(in: .whitespaces))
                    i += 1
                }
                blocks.append(.quote(quoteLines.joined(separator: "\n")))
                continue
            }

            // Unordered list.
            if isBullet(trimmed) {
                flushParagraph()
                var items: [String] = []
                while i < lines.count, isBullet(lines[i].trimmingCharacters(in: .whitespaces)) {
                    let t = lines[i].trimmingCharacters(in: .whitespaces)
                    items.append(String(t.dropFirst(2)).trimmingCharacters(in: .whitespaces))
                    i += 1
                }
                blocks.append(.bulleted(items))
                continue
            }

            // Ordered list.
            if isNumbered(trimmed) {
                flushParagraph()
                var items: [String] = []
                while i < lines.count, isNumbered(lines[i].trimmingCharacters(in: .whitespaces)) {
                    let t = lines[i].trimmingCharacters(in: .whitespaces)
                    if let dot = t.firstIndex(of: ".") {
                        items.append(String(t[t.index(after: dot)...]).trimmingCharacters(in: .whitespaces))
                    }
                    i += 1
                }
                blocks.append(.numbered(items))
                continue
            }

            // Blank line separates paragraphs.
            if trimmed.isEmpty {
                flushParagraph()
                i += 1
                continue
            }

            // Plain paragraph text (preserve original line for inline parsing).
            paragraphBuffer.append(line)
            i += 1
        }
        flushParagraph()
        return blocks
    }

    private static func headingLevel(_ s: String) -> Int? {
        guard s.hasPrefix("#") else { return nil }
        let hashes = s.prefix(while: { $0 == "#" }).count
        guard hashes <= 6, s.count > hashes else { return nil }
        let afterHash = s[s.index(s.startIndex, offsetBy: hashes)]
        return afterHash == " " ? hashes : nil
    }

    private static func isBullet(_ s: String) -> Bool {
        s.hasPrefix("- ") || s.hasPrefix("* ") || s.hasPrefix("+ ")
    }

    private static func isNumbered(_ s: String) -> Bool {
        guard let dot = s.firstIndex(of: ".") else { return false }
        let numPart = s[s.startIndex..<dot]
        guard !numPart.isEmpty, numPart.allSatisfy(\.isNumber) else { return false }
        let afterDot = s.index(after: dot)
        return afterDot < s.endIndex && s[afterDot] == " "
    }
}
