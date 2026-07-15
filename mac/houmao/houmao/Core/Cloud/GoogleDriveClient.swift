import Foundation

/// Errors from the Google Drive REST client.
enum DriveError: Error, LocalizedError {
    case notAuthenticated
    case requestFailed(String)
    case invalidResponse(String)

    var errorDescription: String? {
        switch self {
        case .notAuthenticated: return "未连接 Google Drive"
        case .requestFailed(let m): return m
        case .invalidResponse(let m): return m
        }
    }
}

/// Minimal Google Drive v3 client for the app-managed mirror: find-or-create a
/// folder and upsert a small text file by name (`text/plain`, Markdown content).
/// Pure Foundation (`URLSession`); the access token is injected so this stays
/// independent of the auth actor. Uses the `drive.file` scope, so `files.list`
/// only ever returns files this app created — exactly the set we manage.
struct GoogleDriveClient: Sendable {
    /// Supplies a fresh OAuth access token (refreshes as needed).
    let accessTokenProvider: @Sendable () async throws -> String

    private static let filesEndpoint = "https://www.googleapis.com/drive/v3/files"
    private static let uploadEndpoint = "https://www.googleapis.com/upload/drive/v3/files"
    private static let folderMime = "application/vnd.google-apps.folder"

    // MARK: - Folder

    /// Return the id of the folder named `name` (optionally under `parentID`),
    /// creating it if it doesn't exist.
    func ensureFolder(named name: String, parentID: String?) async throws -> String {
        if let existing = try await findFile(name: name, parentID: parentID, folder: true) {
            return existing
        }
        var metadata: [String: Any] = ["name": name, "mimeType": Self.folderMime]
        if let parentID { metadata["parents"] = [parentID] }
        return try await createMetadata(metadata)
    }

    // MARK: - File upsert

    /// Create or overwrite `name` under `parentID` with `content` (text/plain).
    /// One-way mirror: the Drive copy is replaced with the latest local content.
    func upsertTextFile(name: String, content: String, parentID: String) async throws {
        let mime = "text/plain"
        if let id = try await findFile(name: name, parentID: parentID, folder: false) {
            try await updateMedia(fileID: id, content: content, mime: mime)
        } else {
            try await createMultipart(name: name, content: content, mime: mime, parentID: parentID)
        }
    }

    // MARK: - REST helpers

    /// First file/folder matching `name` (+ optional parent), or nil.
    private func findFile(name: String, parentID: String?, folder: Bool) async throws -> String? {
        var q = "name = '\(escape(name))' and trashed = false"
        q += folder
            ? " and mimeType = '\(Self.folderMime)'"
            : " and mimeType != '\(Self.folderMime)'"
        if let parentID { q += " and '\(escape(parentID))' in parents" }

        var components = URLComponents(string: Self.filesEndpoint)!
        components.queryItems = [
            URLQueryItem(name: "q", value: q),
            URLQueryItem(name: "fields", value: "files(id,name)"),
            URLQueryItem(name: "spaces", value: "drive"),
            URLQueryItem(name: "pageSize", value: "1"),
        ]
        var request = URLRequest(url: components.url!)
        try await authorize(&request)
        let data = try await send(request)
        let list = try decode(FileList.self, from: data)
        return list.files.first?.id
    }

    /// Create a metadata-only resource (used for folders); returns its id.
    private func createMetadata(_ metadata: [String: Any]) async throws -> String {
        var components = URLComponents(string: Self.filesEndpoint)!
        components.queryItems = [URLQueryItem(name: "fields", value: "id")]
        var request = URLRequest(url: components.url!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: metadata)
        try await authorize(&request)
        let data = try await send(request)
        return try decode(FileRef.self, from: data).id
    }

    /// Multipart create: JSON metadata + media body in one request.
    private func createMultipart(name: String, content: String, mime: String, parentID: String) async throws {
        let boundary = "houmao-\(UUID().uuidString)"
        var components = URLComponents(string: Self.uploadEndpoint)!
        components.queryItems = [
            URLQueryItem(name: "uploadType", value: "multipart"),
            URLQueryItem(name: "fields", value: "id"),
        ]
        var request = URLRequest(url: components.url!)
        request.httpMethod = "POST"
        request.setValue("multipart/related; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        let metadata = try JSONSerialization.data(
            withJSONObject: ["name": name, "parents": [parentID]]
        )
        var body = Data()
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Type: application/json; charset=UTF-8\r\n\r\n".data(using: .utf8)!)
        body.append(metadata)
        body.append("\r\n--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Type: \(mime); charset=UTF-8\r\n\r\n".data(using: .utf8)!)
        body.append(Data(content.utf8))
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)
        request.httpBody = body

        try await authorize(&request)
        _ = try await send(request)
    }

    /// Replace an existing file's content (media upload).
    private func updateMedia(fileID: String, content: String, mime: String) async throws {
        var components = URLComponents(string: "\(Self.uploadEndpoint)/\(fileID)")!
        components.queryItems = [URLQueryItem(name: "uploadType", value: "media")]
        var request = URLRequest(url: components.url!)
        request.httpMethod = "PATCH"
        request.setValue("\(mime); charset=UTF-8", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(content.utf8)
        try await authorize(&request)
        _ = try await send(request)
    }

    private func authorize(_ request: inout URLRequest) async throws {
        let token = try await accessTokenProvider()
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    }

    private func send(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw DriveError.invalidResponse("no HTTP response")
        }
        if http.statusCode == 401 { throw DriveError.notAuthenticated }
        guard (200..<300).contains(http.statusCode) else {
            throw DriveError.requestFailed("Drive API \(http.statusCode): \(String(data: data, encoding: .utf8) ?? "")")
        }
        return data
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw DriveError.invalidResponse("Drive 响应解析失败")
        }
    }

    /// Escape single quotes for Drive query strings.
    private func escape(_ value: String) -> String {
        value.replacingOccurrences(of: "'", with: "\\'")
    }

    private struct FileList: Decodable { let files: [FileRef] }
    private struct FileRef: Decodable { let id: String }
}
