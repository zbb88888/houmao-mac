//
//  TextClusteringTests.swift
//  houmaoTests
//

import Testing
import Foundation
@testable import houmao

struct TextClusteringTests {

    // MARK: - N-grams

    @Test func ngramsSplitCharacters() {
        #expect(TextClustering.ngrams(for: "abcd", n: 3) == ["abc", "bcd"])
    }

    @Test func ngramsNormalizeCaseAndWhitespace() {
        #expect(TextClustering.ngrams(for: "  A  B ", n: 3) == ["a b"])
    }

    @Test func ngramsShorterThanNYieldWholeString() {
        #expect(TextClustering.ngrams(for: "ab", n: 3) == ["ab"])
        #expect(TextClustering.ngrams(for: "", n: 3) == [])
    }

    // MARK: - Cosine

    @Test func cosineIdenticalIsOne() {
        let texts = ["Your order has shipped", "Your order has shipped"]
        let v = TextClustering.tfidfVectors(for: texts, ngram: 3)
        let sim = TextClustering.cosineSimilarity(v[0], v[1])
        #expect(abs(sim - 1.0) < 1e-9)
    }

    @Test func cosineDisjointIsZero() {
        #expect(TextClustering.cosineSimilarity(["abc": 1], ["xyz": 1]) == 0)
        #expect(TextClustering.cosineSimilarity([:], ["abc": 1]) == 0)
    }

    // MARK: - Clustering

    @Test func emptyAndSingleton() {
        #expect(TextClustering.cluster([]).isEmpty)
        #expect(TextClustering.cluster(["only one"]) == [[0]])
    }

    @Test func templatedSubjectsClusterTogether() {
        let subjects = [
            "Your Amazon order #1001 has shipped",
            "Your Amazon order #1002 has shipped",
            "Your Amazon order #1003 has shipped",
            "Meeting notes for Q3 planning",
        ]
        let groups = TextClustering.cluster(subjects, config: .init(ngram: 3, threshold: 0.5))
        // The three shipping notices cluster; the meeting note stays alone.
        #expect(groups.first?.count == 3)
        #expect(groups.first?.contains(0) == true)
        #expect(groups.first?.contains(3) == false)
        #expect(groups.contains([3]))
    }

    @Test func everyIndexAppearsExactlyOnce() {
        let subjects = [
            "Sale ends tonight - 50% off",
            "Sale ends tonight - 40% off",
            "Password reset requested",
            "Weekly newsletter: top stories",
        ]
        let groups = TextClustering.cluster(subjects)
        let flattened = groups.flatMap { $0 }.sorted()
        #expect(flattened == [0, 1, 2, 3])
    }

    @Test func groupsSortedByDescendingSize() {
        let subjects = [
            "Newsletter edition alpha beta gamma",
            "Newsletter edition alpha beta delta",
            "Newsletter edition alpha beta epsilon",
            "Completely unrelated random subject here",
            "Another totally different one entirely",
        ]
        let groups = TextClustering.cluster(subjects, config: .init(ngram: 3, threshold: 0.4))
        // First group is the largest.
        for i in 1..<groups.count {
            #expect(groups[i - 1].count >= groups[i].count)
        }
    }
}
