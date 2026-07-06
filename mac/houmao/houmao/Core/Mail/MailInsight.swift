import Foundation

/// Optional LLM enhancement for `/mail` (Phase 6.6, ADR-9).
///
/// Runs **once per cluster** on its representative sample (not per message), so
/// a whole batch of near-duplicate mail costs a single LLM round-trip. The core
/// workflow (classify + cluster + trash) never depends on this — it is purely
/// additive.

/// The LLM's read on a cluster.
struct MailClusterInsight: Sendable {
    enum Importance: String, Sendable, Codable {
        case low
        case medium
        case high

        var displayName: String {
            switch self {
            case .low: return "低"
            case .medium: return "中"
            case .high: return "高"
            }
        }
    }

    let summary: String
    let importance: Importance
    let suggestDelete: Bool
}

/// Builds a prompt from a cluster's representative sample and parses the LLM's
/// structured reply. Pure Foundation; the caller supplies a configured client.
struct MailInsightAnalyzer {
    let client: AiTxtClient

    /// Analyze one cluster via its representative message.
    func analyze(_ cluster: MailCluster) async throws -> MailClusterInsight {
        guard let sample = cluster.messages.first else {
            throw MailProviderError.invalidResponse("空簇")
        }
        let prompt = Self.prompt(for: sample, category: cluster.category, count: cluster.count)
        let reply = try await client.ask(question: prompt, attachments: [])
        return try Self.parse(reply)
    }

    // MARK: - Prompt

    static func prompt(for sample: MailMessage, category: MailCategory, count: Int) -> String {
        """
        你是邮件整理助手。下面是一组共 \(count) 封相似邮件的代表样本（分类：\(category.displayName)）。\
        请判断这组邮件的重要程度，并用一句话中文摘要说明它们大致是什么。
        只输出一个 JSON 对象，不要任何解释或代码块标记，格式如下：
        {"summary": "一句话摘要", "importance": "low|medium|high", "suggestDelete": true|false}
        importance 表示重要度，suggestDelete 表示是否建议清理（true=建议移入废纸篓）。

        发件人: \(sample.from)
        主题: \(sample.subject)
        摘要: \(sample.snippet)
        """
    }

    // MARK: - Parsing

    private struct Raw: Decodable {
        let summary: String
        let importance: MailClusterInsight.Importance
        let suggestDelete: Bool
    }

    /// Leniently parse the model reply: extract the first `{...}` block (models
    /// often wrap JSON in prose or code fences) and decode it.
    static func parse(_ reply: String) throws -> MailClusterInsight {
        guard let start = reply.firstIndex(of: "{"),
              let end = reply.lastIndex(of: "}"),
              start < end else {
            throw MailProviderError.invalidResponse("LLM 未返回 JSON")
        }
        let json = String(reply[start...end])
        guard let data = json.data(using: .utf8) else {
            throw MailProviderError.invalidResponse("JSON 编码失败")
        }
        do {
            let raw = try JSONDecoder().decode(Raw.self, from: data)
            return MailClusterInsight(
                summary: raw.summary.trimmingCharacters(in: .whitespacesAndNewlines),
                importance: raw.importance,
                suggestDelete: raw.suggestDelete
            )
        } catch {
            throw MailProviderError.invalidResponse("LLM JSON 解析失败")
        }
    }
}
