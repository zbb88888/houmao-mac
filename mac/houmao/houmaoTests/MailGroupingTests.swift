//
//  MailGroupingTests.swift
//  houmaoTests
//

import Testing
import Foundation
@testable import houmao

struct MailGroupingTests {

    // MARK: - Category derivation

    @Test func categoryFromLabels() {
        #expect(MailCategory.from(labelIds: ["CATEGORY_PROMOTIONS", "UNREAD"]) == .promotions)
        #expect(MailCategory.from(labelIds: ["CATEGORY_SOCIAL"]) == .social)
        #expect(MailCategory.from(labelIds: ["INBOX"]) == .primary)
        #expect(MailCategory.from(labelIds: []) == .primary)
    }

    // MARK: - Grouping

    private func msg(_ id: String, _ subject: String, _ label: String) -> MailMessage {
        MailMessage(id: id, from: "sender@example.com", subject: subject, labelIds: [label])
    }

    @Test func emptyInputYieldsNoClusters() {
        #expect(MailGrouping.group([]).isEmpty)
    }

    @Test func bracketlessMailUsesGmailCategoryAsPrimary() {
        // No brackets / keywords → the Gmail category is the 大类 (大类 split by
        // promotions/updates/…), ordered by MailCategory.allCases.
        let messages = [
            msg("1", "Big summer sale ends soon", "CATEGORY_PROMOTIONS"),
            msg("2", "Your monthly statement is ready", "CATEGORY_UPDATES"),
        ]
        let clusters = MailGrouping.group(messages, config: .init(ngram: 3, threshold: 0.5))
        #expect(clusters.contains { $0.primary == "促销" })
        #expect(clusters.contains { $0.primary == "更新通知" })
        // Promotions comes before updates (MailCategory.allCases order).
        let promoIndex = clusters.firstIndex { $0.primary == "促销" }
        let updatesIndex = clusters.firstIndex { $0.primary == "更新通知" }
        #expect(promoIndex != nil && updatesIndex != nil && promoIndex! < updatesIndex!)
    }

    @Test func clustersWithinSameCategory() {
        let messages = [
            msg("1", "Your Amazon order #1001 has shipped", "CATEGORY_UPDATES"),
            msg("2", "Your Amazon order #1002 has shipped", "CATEGORY_UPDATES"),
            msg("3", "Your Amazon order #1003 has shipped", "CATEGORY_UPDATES"),
            msg("4", "Q3 budget review meeting notes", "CATEGORY_PERSONAL"),
        ]
        let clusters = MailGrouping.group(messages, config: .init(ngram: 3, threshold: 0.5))
        // Largest cluster is the three shipping updates.
        #expect(clusters.first?.count == 3)
        #expect(clusters.first?.category == .updates)
        // The personal note is its own singleton cluster.
        #expect(clusters.contains { $0.category == .personal && $0.count == 1 })
    }

    // MARK: - Two-level tags: () primary, [] secondary

    @Test func loneBracketBecomesPrimary() {
        // No PR/issue/() → a single `[]` classifies on its own (becomes primary).
        let messages = [
            msg("1", "[GitHub] Alpha release notes", "CATEGORY_UPDATES"),
            msg("2", "[Jira] Sprint planning", "CATEGORY_UPDATES"),
        ]
        let clusters = MailGrouping.group(messages, config: .init(ngram: 3, threshold: 0.9))
        #expect(clusters.contains { $0.primary == "github" && $0.secondary == nil })
        #expect(clusters.contains { $0.primary == "jira" && $0.secondary == nil })
    }

    @Test func onlyFirstBracketUsed() {
        // The second bracket is ignored: the primary is the first tag `github`.
        let messages = [
            msg("1", "[GitHub] [Alpha] one", "CATEGORY_UPDATES"),
            msg("2", "[GitHub] [Beta] two", "CATEGORY_UPDATES"),
        ]
        let clusters = MailGrouping.group(messages, config: .init(ngram: 3, threshold: 0.9))
        #expect(clusters.allSatisfy { $0.primary == "github" && $0.secondary == nil })
    }

    @Test func parenPrimaryBracketSecondary() {
        // Both brackets present → `()` is primary (大类), `[]` is secondary (小类).
        let messages = [
            msg("1", "(v2.0) [core] release cut", "CATEGORY_UPDATES"),
            msg("2", "(v2.0) [docs] update guide", "CATEGORY_UPDATES"),
        ]
        let clusters = MailGrouping.group(messages, config: .init(ngram: 3, threshold: 0.9))
        #expect(clusters.contains { $0.primary == "v2.0" && $0.secondary == "core" })
        #expect(clusters.contains { $0.primary == "v2.0" && $0.secondary == "docs" })
    }

    @Test func thirdBracketLevelJoinsSecondary() {
        // A 3rd-level bracket ({}) is appended after the 2nd in the secondary,
        // joined with " › ". Missing higher-priority brackets don't occupy a level.
        #expect(MailGrouping.tags(for: "(alpha) [beta] {gamma} hi") == (primary: "alpha", secondary: "beta › gamma"))
        #expect(MailGrouping.tags(for: "(alpha) {gamma} hi") == (primary: "alpha", secondary: "gamma"))
    }

    @Test func unformattedSubjectsClusterByNeighbour() {
        // No brackets → "unformatted" mail → handled by the near-neighbour pass.
        let messages = [
            msg("1", "Your Amazon order #1001 has shipped", "CATEGORY_UPDATES"),
            msg("2", "Your Amazon order #1002 has shipped", "CATEGORY_UPDATES"),
            msg("3", "Your Amazon order #1003 has shipped", "CATEGORY_UPDATES"),
        ]
        let clusters = MailGrouping.group(messages, config: .init(ngram: 3, threshold: 0.5))
        #expect(clusters.count == 1)
        #expect(clusters.first?.count == 3)
    }

    @Test func firstBracketTagParsing() {
        #expect(MailGrouping.firstBracketTag("[GitHub] hello") == "github")
        #expect(MailGrouping.firstBracketTag("re: [ACME] update") == "acme")
        #expect(MailGrouping.firstBracketTag("[  Spaced  ] x") == "spaced")
        #expect(MailGrouping.firstBracketTag("no brackets here") == nil)
        #expect(MailGrouping.firstBracketTag("[] empty") == nil)
    }

    // MARK: - Built-in PR / issue tag

    @Test func builtinTagDetection() {
        // Standalone "PR" token (the abbreviation), e.g. GitHub's `(PR #46257)`.
        #expect(MailGrouping.builtinTag("Re: [cilium/cilium] fix leak (PR #46257)") == "PR")
        // The "pull request" phrase (case-insensitive).
        #expect(MailGrouping.builtinTag("Your pull request was merged") == "PR")
        // "issue" / "issues" token.
        #expect(MailGrouping.builtinTag("[owner/repo] Crash on launch (Issue #12)") == "issue")
        #expect(MailGrouping.builtinTag("Re: open issues digest") == "issue")
        // PR wins when both appear.
        #expect(MailGrouping.builtinTag("pull request closes the issue") == "PR")
        // No false positives from substrings like PRICE.
        #expect(MailGrouping.builtinTag("PRICE drop on your wishlist") == nil)
        #expect(MailGrouping.builtinTag("Weekly newsletter") == nil)
    }

    @Test func prMailsGroupUnderBuiltinTag() {
        let messages = [
            msg("1", "Re: [cilium/cilium] fix leak (PR #46257)", "CATEGORY_UPDATES"),
            msg("2", "[owner/repo] Add feature (PR #5)", "CATEGORY_PERSONAL"),
            msg("3", "[owner/repo] Crash (Issue #9)", "CATEGORY_UPDATES"),
        ]
        let clusters = MailGrouping.group(messages, config: .init(ngram: 3, threshold: 0.9))
        // PR mails (across different categories) carry the built-in "PR" primary,
        // with the `[]` repo as the secondary (小类).
        #expect(clusters.contains { $0.primary == "PR" && $0.secondary == "cilium/cilium" })
        #expect(clusters.contains { $0.primary == "PR" && $0.secondary == "owner/repo" })
        #expect(clusters.contains { $0.primary == "issue" && $0.secondary == "owner/repo" })
        // The "PR" section comes before "issue" (builtinTagOrder).
        let prIndex = clusters.firstIndex { $0.primary == "PR" }
        let issueIndex = clusters.firstIndex { $0.primary == "issue" }
        #expect(prIndex != nil && issueIndex != nil && prIndex! < issueIndex!)
    }

    @Test func lastParenTagNormalizesAndStripsRefs() {
        #expect(MailGrouping.lastParenTag("Fix bug (PR #46257)") == "pr")
        #expect(MailGrouping.lastParenTag("Release (v2.0)") == "v2.0")
        #expect(MailGrouping.lastParenTag("Note (#123)") == nil)
        #expect(MailGrouping.lastParenTag("no parens") == nil)
        // Right-to-left: the last () wins (GitHub's (PR #…) sits at the far right).
        #expect(MailGrouping.lastParenTag("(chore) refactor (PR #7)") == "pr")
    }

    @Test func primaryTagPriority() {
        // Custom tag wins over everything.
        let custom = [MailTag(name: "Boss", keyword: "quarterly")]
        #expect(MailGrouping.primaryTag("quarterly review (PR #1)", customTags: custom) == "Boss")
        // Then PR/issue title match.
        #expect(MailGrouping.primaryTag("[repo] fix (PR #9)") == "PR")
        // Then () content.
        #expect(MailGrouping.primaryTag("Release (v2.0)") == "v2.0")
        // Else 未分类.
        #expect(MailGrouping.primaryTag("weekly newsletter") == MailGrouping.unclassified)
    }

    // MARK: - Mail AI routing (GitHub PR/issue detection)

    @MainActor @Test func detectsPRAndIssueURLs() {
        let pr = MailViewModel.firstGitHubURL(in: "See https://github.com/zbb88888/houmao-mac/pull/42 for details")
        #expect(pr?.mode == "pr")
        #expect(pr?.url == "https://github.com/zbb88888/houmao-mac/pull/42")

        let issue = MailViewModel.firstGitHubURL(in: "Opened https://github.com/acme/app/issues/7 today")
        #expect(issue?.mode == "issue")
        #expect(issue?.url == "https://github.com/acme/app/issues/7")

        #expect(MailViewModel.firstGitHubURL(in: "a plain newsletter with no links") == nil)
        #expect(MailViewModel.firstGitHubURL(in: "https://github.com/acme/app/releases/tag/v1") == nil)
    }
}
