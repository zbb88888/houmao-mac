import Foundation

/// Gmail REST implementation of `MailProvider` (ADR-8).
///
/// Pure `URLSession` (Core-friendly). Reads metadata only (`format=metadata`),
/// filters server-side with Gmail `q` syntax, and mutates labels via
/// `batchModify` (move to Trash / mark read) — all recoverable, no permanent
/// delete (误删代价不可逆, ADR-8).
struct GmailProvider: MailProvider {
    /// Access-token supplier; typically `await GoogleAuthProvider.validAccessToken()`.
    let accessTokenProvider: @Sendable () async throws -> String

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

    // MARK: - Full message (detail view)

    func fetchFull(id: String) async throws -> MailMessageDetail {
        let query = [URLQueryItem(name: "format", value: "full")]
        let detail: MessageFullResponse = try await get("/messages/\(id)", query: query)
        return detail.toDetail()
    }

    // MARK: - Cleanup

    func trashMessages(ids: [String]) async throws {
        try await batchModify(ids: ids, add: ["TRASH"], remove: [])
    }

    func untrash(ids: [String]) async throws {
        try await batchModify(ids: ids, add: ["INBOX"], remove: ["TRASH"])
    }

    func markRead(ids: [String]) async throws {
        try await batchModify(ids: ids, add: [], remove: ["UNREAD"])
    }

    func markUnread(ids: [String]) async throws {
        try await batchModify(ids: ids, add: ["UNREAD"], remove: [])
    }

    private func batchModify(ids: [String], add: [String], remove: [String]) async throws {
        for chunk in ids.chunked(into: batchLimit) {
            var payload: [String: Any] = ["ids": chunk]
            if !add.isEmpty { payload["addLabelIds"] = add }
            if !remove.isEmpty { payload["removeLabelIds"] = remove }
            let body = try JSONSerialization.data(withJSONObject: payload)
            try await post("/messages/batchModify", body: body)
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
    /// Epoch milliseconds (string), Gmail's server receive time.
    let internalDate: String?
    let payload: Payload?

    func toMailMessage() -> MailMessage {
        let headers = payload?.headers ?? []
        func header(_ name: String) -> String? {
            headers.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value
        }
        let date = internalDate
            .flatMap(Double.init)
            .map { Date(timeIntervalSince1970: $0 / 1000) } ?? .distantPast
        return MailMessage(
            id: id,
            from: header("From") ?? "",
            subject: header("Subject") ?? "",
            snippet: snippet ?? "",
            labelIds: labelIds ?? [],
            hasListUnsubscribe: header("List-Unsubscribe") != nil,
            date: date
        )
    }
}

/// `format=full` response: like the metadata one, but the payload carries the
/// MIME tree (`body.data` + nested `parts`) we decode into readable text.
private struct MessageFullResponse: Decodable {
    struct Body: Decodable { let data: String? }
    struct Part: Decodable {
        let mimeType: String?
        let headers: [MessageDetailResponse.Payload.Header]?
        let body: Body?
        let parts: [Part]?
    }
    let id: String
    let snippet: String?
    let payload: Part?

    func toDetail() -> MailMessageDetail {
        let headers = payload?.headers ?? []
        func header(_ name: String) -> String? {
            headers.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value
        }
        let text = payload.flatMap { Self.extractText(from: $0) } ?? ""
        let body = text.isEmpty ? (snippet ?? "") : text
        return MailMessageDetail(
            id: id,
            from: header("From") ?? "",
            to: header("To") ?? "",
            subject: header("Subject") ?? "",
            date: header("Date") ?? "",
            body: body
        )
    }

    /// Walk the MIME tree, preferring a `text/plain` part; fall back to the
    /// first `text/html` part (tags stripped) so there's always readable text.
    private static func extractText(from part: Part) -> String? {
        if let plain = firstPart(part, mimeType: "text/plain"), let text = decode(plain.body?.data) {
            return text
        }
        if let html = firstPart(part, mimeType: "text/html"), let raw = decode(html.body?.data) {
            return stripHTML(raw)
        }
        return nil
    }

    private static func firstPart(_ part: Part, mimeType: String) -> Part? {
        if part.mimeType?.caseInsensitiveCompare(mimeType) == .orderedSame, part.body?.data != nil {
            return part
        }
        for child in part.parts ?? [] {
            if let match = firstPart(child, mimeType: mimeType) { return match }
        }
        return nil
    }

    /// Gmail encodes body data as base64url (RFC 4648 §5, no padding).
    private static func decode(_ base64url: String?) -> String? {
        guard var s = base64url else { return nil }
        s = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while s.count % 4 != 0 { s.append("=") }
        guard let data = Data(base64Encoded: s) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Naive tag strip so an HTML-only message is still legible in the detail view.
    private static func stripHTML(_ html: String) -> String {
        let stripped = html.replacingOccurrences(
            of: "<[^>]+>", with: "", options: .regularExpression
        )
        return stripped
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .trimmingCharacters(in: .whitespacesAndNewlines)
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
