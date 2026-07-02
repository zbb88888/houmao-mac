import SwiftUI
import AppKit

// MARK: - Block-level Markdown rendering (chat replies)
//
// `Text(AttributedString(markdown:))` only understands *inline* syntax; block
// constructs (headings, lists, fenced code, quotes, tables, thematic breaks)
// collapse into a single paragraph with raw `#` / `-` / ``` markers visible.
// LLM chat replies lean heavily on those block constructs, so the source is
// parsed into block elements and each is rendered with a dedicated SwiftUI view.
// Inline emphasis inside a block is still delegated to `AttributedString`.
//
// The parser is intentionally line-based and dependency-free: it is called on
// every streamed token, so it must be cheap and tolerant of half-finished input
// (an unterminated code fence or table simply renders what has arrived so far).

// MARK: Model

indirect enum MarkdownBlock: Equatable {
    case heading(level: Int, text: String)
    case paragraph(String)
    case codeBlock(language: String?, code: String)
    case quote([MarkdownBlock])
    case list(MarkdownList)
    case table(header: [String], rows: [[String]])
    case thematicBreak
}

struct MarkdownList: Equatable {
    let ordered: Bool
    var items: [MarkdownListItem]
}

struct MarkdownListItem: Equatable {
    var text: String
    var sublist: MarkdownList?
}

// MARK: Parser

enum MarkdownParser {

    static func parse(_ source: String) -> [MarkdownBlock] {
        let lines = source.components(separatedBy: "\n")
        var blocks: [MarkdownBlock] = []
        var paragraph: [String] = []
        var i = 0

        func flushParagraph() {
            let joined = paragraph.joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !joined.isEmpty { blocks.append(.paragraph(joined)) }
            paragraph.removeAll()
        }

        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Fenced code block — collect verbatim until the closing fence (or
            // EOF, so a still-streaming block renders immediately).
            if trimmed.hasPrefix("```") {
                flushParagraph()
                let lang = String(trimmed.dropFirst(3))
                    .trimmingCharacters(in: .whitespaces)
                var code: [String] = []
                i += 1
                while i < lines.count {
                    if lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                        i += 1
                        break
                    }
                    code.append(lines[i])
                    i += 1
                }
                blocks.append(.codeBlock(language: lang.isEmpty ? nil : lang,
                                         code: code.joined(separator: "\n")))
                continue
            }

            // Blank line — paragraph separator.
            if trimmed.isEmpty {
                flushParagraph()
                i += 1
                continue
            }

            // ATX heading.
            if let heading = parseHeading(trimmed) {
                flushParagraph()
                blocks.append(heading)
                i += 1
                continue
            }

            // Thematic break.
            if isThematicBreak(trimmed) {
                flushParagraph()
                blocks.append(.thematicBreak)
                i += 1
                continue
            }

            // Blockquote — gather the contiguous quoted region and parse it
            // recursively so nested blocks keep working.
            if trimmed.hasPrefix(">") {
                flushParagraph()
                var quoted: [String] = []
                while i < lines.count {
                    let t = lines[i].trimmingCharacters(in: .whitespaces)
                    guard t.hasPrefix(">") else { break }
                    var stripped = String(t.dropFirst())
                    if stripped.hasPrefix(" ") { stripped.removeFirst() }
                    quoted.append(stripped)
                    i += 1
                }
                blocks.append(.quote(parse(quoted.joined(separator: "\n"))))
                continue
            }

            // GFM table — a header row followed by a `| --- | --- |` delimiter.
            if line.contains("|"), i + 1 < lines.count, isTableDelimiter(lines[i + 1]) {
                flushParagraph()
                let header = parseTableRow(line)
                i += 2
                var rows: [[String]] = []
                while i < lines.count {
                    let l = lines[i]
                    if l.trimmingCharacters(in: .whitespaces).isEmpty || !l.contains("|") {
                        break
                    }
                    rows.append(parseTableRow(l))
                    i += 1
                }
                blocks.append(.table(header: header, rows: rows))
                continue
            }

            // List (ordered / unordered, with indentation-based nesting).
            if listMarker(line) != nil {
                flushParagraph()
                let (list, next) = parseList(lines, start: i)
                blocks.append(.list(list))
                i = next
                continue
            }

            // Otherwise: accumulate into the current paragraph.
            paragraph.append(trimmed)
            i += 1
        }

        flushParagraph()
        return blocks
    }

    // MARK: Block helpers

    private static func parseHeading(_ line: String) -> MarkdownBlock? {
        var level = 0
        var idx = line.startIndex
        while idx < line.endIndex, line[idx] == "#", level < 6 {
            level += 1
            idx = line.index(after: idx)
        }
        guard level > 0, idx < line.endIndex, line[idx] == " " else { return nil }
        let text = String(line[idx...]).trimmingCharacters(in: .whitespaces)
        return .heading(level: level, text: text)
    }

    private static func isThematicBreak(_ line: String) -> Bool {
        let stripped = line.replacingOccurrences(of: " ", with: "")
        guard stripped.count >= 3 else { return false }
        return stripped.allSatisfy { $0 == "-" }
            || stripped.allSatisfy { $0 == "*" }
            || stripped.allSatisfy { $0 == "_" }
    }

    private static func isTableDelimiter(_ line: String) -> Bool {
        let t = line.trimmingCharacters(in: .whitespaces)
        guard t.contains("|"), t.contains("-") else { return false }
        // Every cell must be made of only `-`, `:` and spaces.
        return parseTableRow(line).allSatisfy { cell in
            let c = cell.trimmingCharacters(in: .whitespaces)
            return !c.isEmpty && c.allSatisfy { $0 == "-" || $0 == ":" }
        }
    }

    private static func parseTableRow(_ line: String) -> [String] {
        var t = line.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("|") { t.removeFirst() }
        if t.hasSuffix("|") { t.removeLast() }
        return t.components(separatedBy: "|").map {
            $0.trimmingCharacters(in: .whitespaces)
        }
    }

    // MARK: List parsing

    /// A leading list marker: its indentation width, whether it is ordered, and
    /// the item's inline content. Returns nil for non-list lines.
    private static func listMarker(_ line: String) -> (indent: Int, ordered: Bool, content: String)? {
        var indent = 0
        var idx = line.startIndex
        while idx < line.endIndex, line[idx] == " " || line[idx] == "\t" {
            indent += line[idx] == "\t" ? 4 : 1
            idx = line.index(after: idx)
        }
        let rest = String(line[idx...])
        guard !rest.isEmpty else { return nil }

        // Unordered: `- `, `* `, `+ `.
        if let first = rest.first, first == "-" || first == "*" || first == "+" {
            let after = rest.dropFirst()
            if after.first == " " {
                return (indent, false, String(after.dropFirst()).trimmingCharacters(in: .whitespaces))
            }
            return nil
        }

        // Ordered: `1. ` / `1) `.
        var digits = ""
        var r = rest.startIndex
        while r < rest.endIndex, rest[r].isNumber {
            digits.append(rest[r])
            r = rest.index(after: r)
        }
        guard !digits.isEmpty, r < rest.endIndex, rest[r] == "." || rest[r] == ")" else {
            return nil
        }
        let afterDot = rest.index(after: r)
        guard afterDot < rest.endIndex, rest[afterDot] == " " else { return nil }
        let content = String(rest[rest.index(after: afterDot)...]).trimmingCharacters(in: .whitespaces)
        return (indent, true, content)
    }

    /// Parse a (possibly nested) list starting at `start`. A more-indented run
    /// that follows an item becomes that item's sub-list; a shallower or
    /// non-list line ends the current level.
    private static func parseList(_ lines: [String], start: Int) -> (MarkdownList, Int) {
        guard let head = listMarker(lines[start]) else {
            return (MarkdownList(ordered: false, items: []), start)
        }
        let levelIndent = head.indent
        let ordered = head.ordered
        var items: [MarkdownListItem] = []
        var i = start

        while i < lines.count {
            // Consume a single blank line inside a "loose" list only when the
            // list actually continues afterwards; otherwise the list ends.
            if lines[i].trimmingCharacters(in: .whitespaces).isEmpty {
                if i + 1 < lines.count, let next = listMarker(lines[i + 1]),
                   next.indent >= levelIndent {
                    i += 1
                    continue
                }
                break
            }

            guard let marker = listMarker(lines[i]), marker.indent >= levelIndent else { break }

            var item = MarkdownListItem(text: marker.content, sublist: nil)
            i += 1
            if i < lines.count, let next = listMarker(lines[i]), next.indent > levelIndent {
                let (sub, consumed) = parseList(lines, start: i)
                item.sublist = sub
                i = consumed
            }
            items.append(item)
        }

        return (MarkdownList(ordered: ordered, items: items), i)
    }

    // MARK: Inline

    /// Render inline Markdown (bold / italic / links / inline code) into an
    /// `AttributedString`, forcing inline code runs to a monospaced font with a
    /// subtle background since SwiftUI does not style `.code` runs on its own.
    static func inlineAttributed(_ source: String, size: CGFloat) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace,
            failurePolicy: .returnPartiallyParsedIfPossible
        )
        guard var attr = try? AttributedString(markdown: source, options: options) else {
            return AttributedString(source)
        }
        var codeRanges: [Range<AttributedString.Index>] = []
        for run in attr.runs where run.inlinePresentationIntent?.contains(.code) == true {
            codeRanges.append(run.range)
        }
        for range in codeRanges {
            attr[range].font = .system(size: size, design: .monospaced)
            attr[range].backgroundColor = .secondary.opacity(0.18)
        }
        return attr
    }
}

// MARK: - Views

struct MarkdownView: View {
    let text: String
    var baseFontSize: CGFloat = 14

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(MarkdownParser.parse(text).enumerated()), id: \.offset) { _, block in
                MarkdownBlockView(block: block, baseFontSize: baseFontSize)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
    }
}

private struct MarkdownBlockView: View {
    let block: MarkdownBlock
    let baseFontSize: CGFloat

    var body: some View {
        switch block {
        case let .heading(level, text):
            Text(MarkdownParser.inlineAttributed(text, size: headingSize(level)))
                .font(.system(size: headingSize(level), weight: .semibold))
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, level <= 2 ? 2 : 0)

        case let .paragraph(text):
            Text(MarkdownParser.inlineAttributed(text, size: baseFontSize))
                .font(.system(size: baseFontSize))
                .fixedSize(horizontal: false, vertical: true)

        case let .codeBlock(language, code):
            MarkdownCodeBlockView(language: language, code: code, baseFontSize: baseFontSize)

        case let .quote(blocks):
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.secondary.opacity(0.4))
                    .frame(width: 3)
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(blocks.enumerated()), id: \.offset) { _, inner in
                        MarkdownBlockView(block: inner, baseFontSize: baseFontSize)
                    }
                }
                .foregroundColor(.secondary)
            }
            .fixedSize(horizontal: false, vertical: true)

        case let .list(list):
            MarkdownListView(list: list, baseFontSize: baseFontSize)

        case let .table(header, rows):
            MarkdownTableView(header: header, rows: rows, baseFontSize: baseFontSize)

        case .thematicBreak:
            Divider().padding(.vertical, 2)
        }
    }

    private func headingSize(_ level: Int) -> CGFloat {
        switch level {
        case 1: return baseFontSize + 7
        case 2: return baseFontSize + 4
        case 3: return baseFontSize + 2
        default: return baseFontSize + 1
        }
    }
}

private struct MarkdownListView: View {
    let list: MarkdownList
    let baseFontSize: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(list.items.enumerated()), id: \.offset) { index, item in
                VStack(alignment: .leading, spacing: 4) {
                    if !item.text.isEmpty {
                        HStack(alignment: .top, spacing: 6) {
                            Text(marker(at: index))
                                .font(.system(size: baseFontSize))
                                .foregroundColor(.secondary)
                                .frame(minWidth: list.ordered ? 20 : 12, alignment: .trailing)
                            Text(MarkdownParser.inlineAttributed(item.text, size: baseFontSize))
                                .font(.system(size: baseFontSize))
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    if let sublist = item.sublist {
                        MarkdownListView(list: sublist, baseFontSize: baseFontSize)
                            .padding(.leading, 18)
                    }
                }
            }
        }
    }

    private func marker(at index: Int) -> String {
        list.ordered ? "\(index + 1)." : "•"
    }
}

private struct MarkdownTableView: View {
    let header: [String]
    let rows: [[String]]
    let baseFontSize: CGFloat

    private var columnCount: Int {
        max(header.count, rows.map(\.count).max() ?? 0)
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
                GridRow {
                    ForEach(0..<columnCount, id: \.self) { col in
                        Text(MarkdownParser.inlineAttributed(cell(header, col), size: baseFontSize))
                            .font(.system(size: baseFontSize, weight: .semibold))
                    }
                }
                Divider()
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    GridRow {
                        ForEach(0..<columnCount, id: \.self) { col in
                            Text(MarkdownParser.inlineAttributed(cell(row, col), size: baseFontSize))
                                .font(.system(size: baseFontSize))
                        }
                    }
                }
            }
            .padding(10)
        }
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.secondary.opacity(0.25), lineWidth: 1)
        )
    }

    private func cell(_ row: [String], _ col: Int) -> String {
        col < row.count ? row[col] : ""
    }
}

private struct MarkdownCodeBlockView: View {
    let language: String?
    let code: String
    let baseFontSize: CGFloat

    @Environment(\.colorScheme) private var scheme
    @State private var hovering = false
    @State private var copied = false

    private var background: Color {
        scheme == .dark ? Color.white.opacity(0.06) : Color.black.opacity(0.05)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text((language ?? "code").uppercased())
                    .font(.system(size: baseFontSize - 3, weight: .medium, design: .monospaced))
                    .foregroundColor(.secondary)
                Spacer()
                if hovering || copied {
                    Button(action: copy) {
                        Label(copied ? "Copied" : "Copy",
                              systemImage: copied ? "checkmark" : "doc.on.doc")
                            .font(.system(size: baseFontSize - 3, weight: .medium))
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Copy code")
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)

            Divider().opacity(0.5)

            ScrollView(.horizontal, showsIndicators: false) {
                Text(code)
                    .font(.system(size: baseFontSize - 1, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
            }
        }
        .background(background)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .onHover { hovering = $0 }
    }

    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(code, forType: .string)
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false }
    }
}
