import Foundation
import Observation
import os.log

private let driveLog = Logger(subsystem: "com.houmao", category: "DriveSync")

/// Coordinates one-way mirroring of local app files to Google Drive. Used by the
/// Do panel to auto-upload the to-do files (`工作.txt` / `生活.txt` and monthly
/// archives) after each local save (debounced). Data flows local → Drive only;
/// nothing is downloaded or merged. Files land under a `houmao/待办` folder the
/// app creates.
@MainActor
@Observable
final class DriveSyncService {
    enum Status: Equatable {
        case idle
        case uploading
        case failed(String)
    }

    private(set) var status: Status = .idle

    /// An OAuth Client ID must be configured (shared with Gmail).
    var isConfigured: Bool { !AppSettings.shared.googleClientID.isEmpty }
    /// A Google session exists (shared refresh token in the Keychain).
    var isConnected: Bool { GoogleAccount.isConnected }

    /// Cached `houmao/do` folder id resolution (shared across files, so two
    /// near-simultaneous uploads don't each create a duplicate folder).
    private var folderTask: Task<String, Error>?
    /// Per-file debounce so a burst of edits results in a single upload.
    private var debounce: [String: Task<Void, Never>] = [:]

    // MARK: - Connect

    /// Run the OAuth consent flow (shared scopes) so the app gets a refresh token
    /// that also covers Drive. Throws on failure.
    func connect() async throws {
        guard isConfigured else { throw DriveError.notAuthenticated }
        try await GoogleAccount.connect()
        folderTask = nil
        driveLog.info("Drive connected")
    }

    // MARK: - Mirror

    /// Debounced one-way mirror of `content` to `name` on Drive. No-op when not
    /// connected (auto-sync only runs once the user has linked their account).
    func scheduleMirror(name: String, content: String) {
        guard isConnected else { return }
        debounce[name]?.cancel()
        debounce[name] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            await self?.upload(name: name, content: content)
        }
    }

    private func upload(name: String, content: String) async {
        status = .uploading
        do {
            let client = makeClient()
            let folder = try await doFolderID(client)
            try await client.upsertTextFile(name: name, content: content, parentID: folder)
            status = .idle
            driveLog.info("mirrored \(name, privacy: .public) to Drive")
        } catch {
            status = .failed(error.localizedDescription)
            driveLog.error("mirror \(name, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Resolve (and cache) the `houmao/待办` folder id, creating the folders on
    /// first use. Retries next time if resolution fails.
    private func doFolderID(_ client: GoogleDriveClient) async throws -> String {
        if let folderTask { return try await folderTask.value }
        let task = Task { () throws -> String in
            let root = try await client.ensureFolder(named: "houmao", parentID: nil)
            return try await client.ensureFolder(named: "待办", parentID: root)
        }
        folderTask = task
        do {
            return try await task.value
        } catch {
            folderTask = nil
            throw error
        }
    }

    private func makeClient() -> GoogleDriveClient {
        GoogleDriveClient(accessTokenProvider: { try await GoogleAccount.accessToken() })
    }
}
