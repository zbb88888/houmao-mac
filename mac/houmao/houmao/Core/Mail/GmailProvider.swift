import Foundation

/// Gmail REST implementation of `MailProvider` (ADR-8).
///
/// Pure `URLSession` (Core-friendly). Reads metadata only (`format=metadata`),
/// filters server-side with Gmail `q` syntax, and cleans up via `batchModify`
/// (move to Trash, recoverable). Permanent `batchDelete` is disabled unless the
/// caller explicitly opts in (`allowPermanentDelete`) —误删代价不可逆 (ADR-8).
struct GmailProvider: MailProvider {
    /// Access-token supplier; typically `await GoogleAuthProvider.validAccessToken()`.
    let accessTokenProvider: @Sendable () async throws -> String
    /// Gate for the irreversible permanent-delete path.
    var allowPermanentDelete: Bool = false

    private let base = "https://gmail.googleapis.com/gmail/v1/users/me"
    /// Gmail caps batch mutations at 1000 ids per request.
    private let batchLimit = 1000

    // MARK: - List

    func listMessages(query: String, maxResults: Int) async throws -> [String] {
        var ids: [String] = []
        var pageToken: String?

        repeat {
            let remaining = maxResults - ids.count
            guard remaining > 0 else { break }

            var items = [
                URLQueryItem(name: "q", value: query),
                URLQueryItem(name: "maxResults", value: String(min(remaining, 500))),
            ]
            if let token = pageToken { items.append(URLQueryItem(name: "pageToken", value: token)) }

            let page: MessageListResponse = try await get("/messages", query: items)
            ids.append(contentsOf: (page.messages ?? []).map(\.id))
            pageToken = page.nextPageToken
        } while pageToken != nil && ids.count < maxResults

        return Array(ids.prefix(maxResults))
    }

    // MARK: - Metadata

    func fetchMetadata(ids: [String]) async throws -> [MailMessage] {
        guard !ids.isEmpty else { return [] }

        // Bounded-concurrency fan-out of per-message metadata gets.
        let details = try await withThrowingTaskGroup(of: (Int, MailMessage).self) { group -> [MailMessage] in
            let maxConcurrent = 8
            var next = 0

            func addTask(_ index: Int) {
                let id = ids[index]
                group.addTask { (index, try await self.fetchOne(id: id)) }
            }

            while next < min(maxConcurrent, ids.count) {
                addTask(next); next += 1
            }

            var buffer = [MailMessage?](repeating: nil, count: ids.count)
            for try await (index, message) in group {
                buffer[index] = message
                if next < ids.count { addTask(next); next += 1 }
            }
            return buffer.compactMap { $0 }
        }
        return details
    }

    private func fetchOne(id: String) async throws -> MailMessage {
        let query = [
            URLQueryItem(name: "format", value: "metadata"),
            URLQueryItem(name: "metadataHeaders", value: "From"),
            URLQueryItem(name: "metadataHeaders", value: "Subject"),
            URLQueryItem(name: "metadataHeaders", value: "List-Unsubscribe"),
        ]
        let detail: MessageDetailResponse = try await get("/messages/\(id)", query: query)
        return detail.toMailMessage()
    }

    // MARK: - Cleanup

    func trashMessages(ids: [String]) async throws {
        for chunk in ids.chunked(into: batchLimit) {
            let body = try JSONSerialization.data(withJSONObject: [
                "ids": chunk,
                "addLabelIds": ["TRASH"],
            ])
            try await post("/messages/batchModify", body: body)
        }
    }

    func deleteMessages(ids: [String]) async throws {
        guard allowPermanentDelete else { throw MailProviderError.permanentDeleteNotPermitted }
        for chunk in ids.chunked(into: batchLimit) {
            let body = try JSONSerialization.data(withJSONObject: ["ids": chunk])
            try await post("/messages/batchDelete", body: body)
        }
    }

    // MARK: - HTTP

    private func get<T: Decodable>(_ path: String, query: [URLQueryItem]) async throws -> T {
        guard var components = URLComponents(string: base + path) else {
            throw MailProviderError.invalidResponse("bad URL: \(path)")
        }
        components.queryItems = query
        guard let url = components.url else {
            throw MailProviderError.invalidResponse("bad URL components: \(path)")
        }
        var request = URLRequest(url: url)
        try await authorize(&request)
        return try await send(request)
    }

    private func post(_ path: String, body: Data) async throws {
        guard let url = URL(string: base + path) else {
            throw MailProviderError.invalidResponse("bad URL: \(path)")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        try await authorize(&request)
        let (data, response) = try await URLSession.shared.data(for: request)
        try Self.validate(response, data: data)
    }

    private func authorize(_ request: inout URLRequest) async throws {
        let token = try await accessTokenProvider()
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    }

    private func send<T: Decodable>(_ request: URLRequest) async throws -> T {
        let (data, response) = try await URLSession.shared.data(for: request)
        try Self.validate(response, data: data)
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw MailProviderError.invalidResponse("解析失败: \(error.localizedDescription)")
        }
    }

    private static func validate(_ response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else {
            throw MailProviderError.invalidResponse("no HTTP response")
        }
        if http.statusCode == 401 { throw MailProviderError.notAuthenticated }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw MailProviderError.requestFailed("Gmail 请求失败 (\(http.statusCode)): \(body)")
        }
    }
}

// MARK: - Wire formats

private struct MessageListResponse: Decodable {
    struct Ref: Decodable { let id: String }
    let messages: [Ref]?
    let nextPageToken: String?
}

private struct MessageDetailResponse: Decodable {
    struct Payload: Decodable {
        struct Header: Decodable { let name: String; let value: String }
        let headers: [Header]?
    }
    let id: String
    let snippet: String?
    let labelIds: [String]?
    let payload: Payload?

    func toMailMessage() -> MailMessage {
        let headers = payload?.headers ?? []
        func header(_ name: String) -> String? {
            headers.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value
        }
        return MailMessage(
            id: id,
            from: header("From") ?? "",
            subject: header("Subject") ?? "",
            snippet: snippet ?? "",
            labelIds: labelIds ?? [],
            hasListUnsubscribe: header("List-Unsubscribe") != nil
        )
    }
}

// MARK: - Utilities

extension Array {
    /// Split into chunks of at most `size` elements.
    func chunked(into size: Int) -> [[Element]] {
        guard size > 0 else { return [self] }
        return stride(from: 0, to: count, by: size).map {
            Array(self[$0..<Swift.min($0 + size, count)])
        }
    }
}
