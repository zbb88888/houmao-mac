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

    @Test func lowPriorityCategories() {
        #expect(MailCategory.promotions.isLowPriority)
        #expect(MailCategory.updates.isLowPriority)
        #expect(MailCategory.forums.isLowPriority)
        #expect(!MailCategory.personal.isLowPriority)
        #expect(!MailCategory.social.isLowPriority)
        #expect(!MailCategory.primary.isLowPriority)
    }

    // MARK: - Grouping

    private func msg(_ id: String, _ subject: String, _ label: String) -> MailMessage {
        MailMessage(id: id, from: "sender@example.com", subject: subject, labelIds: [label])
    }

    @Test func emptyInputYieldsNoClusters() {
        #expect(MailGrouping.group([]).isEmpty)
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

    @Test func differentCategoriesNeverMerge() {
        let messages = [
            msg("1", "Weekly deals just for you", "CATEGORY_PROMOTIONS"),
            msg("2", "Weekly deals just for you", "CATEGORY_UPDATES"),
        ]
        let clusters = MailGrouping.group(messages)
        // Identical subjects but different categories → two clusters.
        #expect(clusters.count == 2)
    }

    @Test func categoriesOrderedByPriority() {
        let messages = [
            msg("1", "Personal note", "CATEGORY_PERSONAL"),
            msg("2", "Big sale today", "CATEGORY_PROMOTIONS"),
        ]
        let clusters = MailGrouping.group(messages)
        // Promotions comes before personal in MailCategory.allCases order.
        #expect(clusters.first?.category == .promotions)
    }

    @Test func preselectionFollowsCategory() {
        let promo = MailCluster(category: .promotions, messages: [msg("1", "x", "CATEGORY_PROMOTIONS")])
        let personal = MailCluster(category: .personal, messages: [msg("2", "y", "CATEGORY_PERSONAL")])
        #expect(promo.isPreselected)
        #expect(!personal.isPreselected)
    }
}
