import Foundation

/// Pure, business-agnostic text clustering (ADR-9).
///
/// Groups near-duplicate / templated short texts (e.g. email subjects) using
/// **character n-gram TF-IDF vectors + cosine similarity**, then merges any
/// pair above a similarity threshold via Union-Find (transitive closure).
///
/// This module knows nothing about Mail/Chat: it only consumes `[String]` and
/// returns cluster indices, so it is independently unit-testable and reusable.
/// Complexity is O(n²) on the pairwise comparison — fine after the caller has
/// limited the batch to N items; add LSH pre-filtering only if N grows large.
enum TextClustering {

    /// Tuning knobs for clustering.
    struct Config: Sendable {
        /// Character n-gram size. 3 is robust for short / mixed-language titles.
        var ngram: Int
        /// Minimum cosine similarity (0...1) for two items to join a cluster.
        var threshold: Double

        init(ngram: Int = 3, threshold: Double = 0.5) {
            self.ngram = max(1, ngram)
            self.threshold = min(max(threshold, 0), 1)
        }
    }

    /// A sparse TF-IDF vector keyed by n-gram term.
    typealias Vector = [String: Double]

    // MARK: - Public API

    /// Cluster `texts` and return groups of original indices.
    ///
    /// - Every input index appears in exactly one returned group.
    /// - Items that match nothing form singleton groups (treated as noise).
    /// - Groups are sorted by descending size, then by smallest member index,
    ///   so output is deterministic.
    static func cluster(_ texts: [String], config: Config = Config()) -> [[Int]] {
        guard !texts.isEmpty else { return [] }
        guard texts.count > 1 else { return [[0]] }

        let vectors = tfidfVectors(for: texts, ngram: config.ngram)
        var uf = UnionFind(count: texts.count)

        for i in 0..<texts.count {
            for j in (i + 1)..<texts.count {
                if cosineSimilarity(vectors[i], vectors[j]) >= config.threshold {
                    uf.union(i, j)
                }
            }
        }

        // Collect members per root, preserving first-seen order.
        var groupsByRoot: [Int: [Int]] = [:]
        var rootOrder: [Int] = []
        for index in 0..<texts.count {
            let root = uf.find(index)
            if groupsByRoot[root] == nil { rootOrder.append(root) }
            groupsByRoot[root, default: []].append(index)
        }

        let groups = rootOrder.compactMap { groupsByRoot[$0] }
        return groups.sorted { lhs, rhs in
            if lhs.count != rhs.count { return lhs.count > rhs.count }
            return (lhs.first ?? 0) < (rhs.first ?? 0)
        }
    }

    // MARK: - Vectorization

    /// Build char n-gram TF-IDF vectors for every text.
    static func tfidfVectors(for texts: [String], ngram: Int) -> [Vector] {
        let n = max(1, ngram)
        let termFrequencies = texts.map { termFrequency(ngrams(for: $0, n: n)) }

        // Document frequency per term.
        var documentFrequency: [String: Int] = [:]
        for tf in termFrequencies {
            for term in tf.keys {
                documentFrequency[term, default: 0] += 1
            }
        }

        let total = Double(texts.count)
        return termFrequencies.map { tf in
            var vector: Vector = [:]
            for (term, freq) in tf {
                let df = Double(documentFrequency[term] ?? 1)
                // Smoothed IDF, always > 0 so shared terms still contribute.
                let idf = log((total + 1) / (df + 1)) + 1
                vector[term] = freq * idf
            }
            return vector
        }
    }

    /// Cosine similarity of two sparse vectors (0 if either is empty).
    static func cosineSimilarity(_ a: Vector, _ b: Vector) -> Double {
        guard !a.isEmpty, !b.isEmpty else { return 0 }

        // Iterate the smaller vector for the dot product.
        let (small, large) = a.count <= b.count ? (a, b) : (b, a)
        var dot = 0.0
        for (term, weight) in small {
            if let other = large[term] { dot += weight * other }
        }
        guard dot > 0 else { return 0 }

        let magA = sqrt(a.values.reduce(0) { $0 + $1 * $1 })
        let magB = sqrt(b.values.reduce(0) { $0 + $1 * $1 })
        guard magA > 0, magB > 0 else { return 0 }
        return dot / (magA * magB)
    }

    // MARK: - N-grams

    /// Normalize then extract character n-grams.
    ///
    /// Text is lowercased and whitespace-collapsed. Texts shorter than `n`
    /// yield a single gram (the whole normalized string) so they still match.
    static func ngrams(for text: String, n: Int) -> [String] {
        let normalized = normalize(text)
        guard !normalized.isEmpty else { return [] }

        let chars = Array(normalized)
        guard chars.count >= n else { return [normalized] }

        var grams: [String] = []
        grams.reserveCapacity(chars.count - n + 1)
        for start in 0...(chars.count - n) {
            grams.append(String(chars[start..<(start + n)]))
        }
        return grams
    }

    private static func normalize(_ text: String) -> String {
        let lowered = text.lowercased()
        let collapsed = lowered.split(whereSeparator: { $0.isWhitespace })
        return collapsed.joined(separator: " ")
    }

    private static func termFrequency(_ grams: [String]) -> [String: Double] {
        var tf: [String: Double] = [:]
        for gram in grams { tf[gram, default: 0] += 1 }
        return tf
    }
}

// MARK: - Union-Find

/// Weighted Union-Find with path compression for threshold clustering.
private struct UnionFind {
    private var parent: [Int]
    private var rank: [Int]

    init(count: Int) {
        parent = Array(0..<count)
        rank = Array(repeating: 0, count: count)
    }

    mutating func find(_ x: Int) -> Int {
        var root = x
        while parent[root] != root { root = parent[root] }
        // Path compression.
        var node = x
        while parent[node] != root {
            let next = parent[node]
            parent[node] = root
            node = next
        }
        return root
    }

    mutating func union(_ a: Int, _ b: Int) {
        let ra = find(a), rb = find(b)
        guard ra != rb else { return }
        if rank[ra] < rank[rb] {
            parent[ra] = rb
        } else if rank[ra] > rank[rb] {
            parent[rb] = ra
        } else {
            parent[rb] = ra
            rank[ra] += 1
        }
    }
}
