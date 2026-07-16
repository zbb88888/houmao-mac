import Foundation

/// A dependency-free Markdown format linter. Pure Foundation so it stays
/// unit-testable and reusable across platforms (no external CLI). It reports a
/// small set of simple, low-false-positive format issues; deeper/structural
/// fixes are delegated to the editor's AI fix button.
enum MarkdownLint {
    struct Issue: Equatable {
        /// 1-based line number.
        let line: Int
        let message: String
    }

    /// Check `text` and return issues ordered by line. Content inside fenced code
    /// blocks is skipped for the line-level rules — its `#`, tabs and trailing
    /// spaces are legitimate code, not Markdown format mistakes.
    static func check(_ text: String) -> [Issue] {
        var issues: [Issue] = []
        var inFence = false
        var fenceStartLine = 0

        for (i, raw) in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).enumerated() {
            let line = String(raw)
            let ln = i + 1
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // R1: fenced code block boundaries toggle "inside code" state.
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                if inFence { inFence = false } else { inFence = true; fenceStartLine = ln }
                continue
            }
            if inFence { continue }

            if headingMissingSpace(line) {                                  // R2
                issues.append(Issue(line: ln, message: "标题 # 后缺少空格（应为「# 标题」）"))
            }
            if listMarkerMissingSpace(line) {                               // R3
                issues.append(Issue(line: ln, message: "列表符号后缺少空格（应为「- 项」/「1. 项」）"))
            }
            if line.contains("\t") {                                        // R4
                issues.append(Issue(line: ln, message: "含硬 Tab（建议改用空格）"))
            }
            if hasTrailingWhitespace(line) {                                // R5
                issues.append(Issue(line: ln, message: "行尾有多余空格"))
            }
            if hasEmptyLink(line) {                                         // R6
                issues.append(Issue(line: ln, message: "空链接或图片（[]() 缺少文字或链接）"))
            }
        }

        // R1: an unterminated fence at end of document.
        if inFence {
            issues.append(Issue(line: fenceStartLine, message: "代码围栏未闭合（``` 数目为奇数）"))
        }
        return issues.sorted { $0.line < $1.line }
    }

    // MARK: - Rules

    /// `#Heading`: 1–6 `#` immediately followed by a non-space, non-`#` char.
    private static func headingMissingSpace(_ line: String) -> Bool {
        guard line.hasPrefix("#") else { return false }
        var hashes = 0
        for c in line { if c == "#" { hashes += 1 } else { break } }
        guard hashes <= 6 else { return false }
        guard let first = line.dropFirst(hashes).first else { return false } // "###" alone is fine
        return first != " " && first != "\t"
    }

    /// `-item` / `+item` / `1.item`. `*` bullets are excluded (too easily confused
    /// with emphasis); `---`/`+++` (thematic rules) and decimals like `1.5` are
    /// excluded to keep false positives down.
    private static func listMarkerMissingSpace(_ line: String) -> Bool {
        let stripped = Substring(line).drop(while: { $0 == " " })
        guard let first = stripped.first else { return false }

        if first == "-" || first == "+" {
            guard let after = stripped.dropFirst().first else { return false }   // "-" alone
            return after != " " && after != "\t" && after != first              // exclude "---"/"+++"
        }
        if first.isNumber {
            let digits = stripped.prefix(while: { $0.isNumber })
            let afterDigits = stripped.dropFirst(digits.count)
            guard afterDigits.first == "." else { return false }
            guard let afterDot = afterDigits.dropFirst().first else { return false } // "1." alone
            return afterDot != " " && afterDot != "\t" && !afterDot.isNumber        // exclude "1.5"
        }
        return false
    }

    private static func hasTrailingWhitespace(_ line: String) -> Bool {
        guard line.last == " " || line.last == "\t" else { return false }
        guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { return false } // ignore whitespace-only lines
        // Exactly two trailing spaces is a Markdown hard line break — allow it;
        // flag a lone space, three or more, or any trailing tab.
        let trailing = line.reversed().prefix(while: { $0 == " " || $0 == "\t" })
        if trailing.count == 2, trailing.allSatisfy({ $0 == " " }) { return false }
        return true
    }

    private static func hasEmptyLink(_ line: String) -> Bool {
        line.contains("[](") || line.contains("]()")
    }
}
