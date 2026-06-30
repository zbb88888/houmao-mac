import Foundation

/// A note to be persisted by a `NoteWriting` implementation.
struct Note: Sendable {
    let content: String
    let createdAt: Date

    init(content: String, createdAt: Date = Date()) {
        self.content = content
        self.createdAt = createdAt
    }
}

/// Abstracts where notes are persisted so each platform can choose its own
/// location (macOS: ~/Documents; iOS: app sandbox / iCloud Drive).
protocol NoteWriting: Sendable {
    /// Append `note` to storage and return the file it was written to.
    @discardableResult
    func append(_ note: Note) async throws -> URL
}

/// Default `NoteWriting` implementation that appends Markdown entries to a
/// per-day file under `<Documents>/<subdirectory>/yyyy-MM-dd.md`.
///
/// Pure Foundation: `FileManager.documentDirectory` resolves to `~/Documents`
/// on macOS and the app sandbox `Documents` on iOS, so the same writer works
/// on both platforms with naturally different roots.
struct FileNoteWriter: NoteWriting {
    /// Path appended under the Documents directory, e.g. `houmao/notes`.
    let subdirectory: String

    init(subdirectory: String = "houmao/notes") {
        self.subdirectory = subdirectory
    }

    @discardableResult
    func append(_ note: Note) async throws -> URL {
        let fm = FileManager.default
        let documents = try fm.url(
            for: .documentDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let dir = documents.appendingPathComponent(subdirectory, isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)

        let day = Self.dayFormatter.string(from: note.createdAt)
        let timestamp = Self.timestampFormatter.string(from: note.createdAt)
        let fileURL = dir.appendingPathComponent("\(day).md")

        let entry = "## \(timestamp)\n\n\(note.content)\n\n---\n\n"
        let data = Data(entry.utf8)

        if fm.fileExists(atPath: fileURL.path) {
            let handle = try FileHandle(forWritingTo: fileURL)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        } else {
            try data.write(to: fileURL, options: .atomic)
        }

        return fileURL
    }

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private static let timestampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()
}
