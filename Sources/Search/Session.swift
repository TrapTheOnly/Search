import Foundation

// What was open last time. A list of addresses and their names, and which one
// you were looking at — nothing else, because everything else is either on the
// page or in the history file next door.

enum Session {
    struct Entry: Codable {
        var url: String
        var title: String
        var pin: String?
        /// The name you gave the tab, when you gave it one.
        var name: String?
        /// The address the pin (or essential) was made at, for Reset Pin.
        var pinURL: String?
        /// One-level folder this tab sits in, when it sits in one.
        var folder: String?
        /// Whether that folder is folded shut. Read from any member; they agree.
        var collapsed: Bool?
    }

    struct Folder: Codable, Equatable {
        var id: String
        var name: String
        var collapsed: Bool
    }

    struct Shape: Codable {
        var tabs: [Entry]
        var active: Int
        /// Named groups in this space's strip. Missing on a session from before
        /// folders: the entries' own folder ids are enough to rebuild them.
        var folders: [Folder]?
        /// Pins that follow you into every space. Written on every space's
        /// file so whichever one you open has the list; old files omit it.
        var essentials: [Entry]?
    }

    /// The first space's is the session there always was; each other space
    /// keeps its own beside it.
    private static func file(_ space: UUID) -> URL {
        Store.file(space == Space.firstID ? "session.json" : "session-\(space.uuidString).json")
    }

    static func erase(space: UUID) {
        guard space != Space.firstID else { return }
        try? FileManager.default.removeItem(at: file(space))
    }

    static func read(space: UUID = Space.firstID) -> Shape {
        let file = file(space)
        guard let data = try? Data(contentsOf: file) else { return Shape(tabs: [], active: 0) }
        guard let shape = try? JSONDecoder().decode(Shape.self, from: data) else {
            // A file that's there but won't decode is not the same as no
            // file: something wrote it, and overwriting it on the next save
            // without a trace is how yesterday's tabs actually disappear.
            Store.quarantine(file)
            return Shape(tabs: [], active: 0)
        }
        return shape
    }

    /// `now` writes on the calling thread. Quitting doesn't wait for a
    /// background queue, and a session handed to one on the way out is a
    /// session that may never reach the disk.
    static func write(now: Bool = false, space: UUID = Space.firstID, _ shape: Shape) {
        let file = file(space)
        let put = {
            guard let data = try? JSONEncoder().encode(shape) else { return }
            try? FileManager.default.createDirectory(
                at: file.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try? data.write(to: file, options: .atomic)
            Session.keepCopy(data, of: file)
        }
        if now {
            put()
        } else {
            DispatchQueue.global(qos: .utility).async(execute: put)
        }
    }

    /// Dated copies beside the session, five at most. The bytes are the ones
    /// just written — no second encode, no timer.
    private static func keepCopy(_ data: Data, of file: URL) {
        let folder = file.deletingLastPathComponent().appendingPathComponent("Backups", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let stem = file.deletingPathExtension().lastPathComponent
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        try? data.write(to: folder.appendingPathComponent("\(stem)-\(stamp).json"), options: .atomic)
        let prefix = stem + "-"
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.creationDateKey], options: .skipsHiddenFiles)) ?? []
        let ours = files.filter { $0.lastPathComponent.hasPrefix(prefix) }
            .sorted { a, b in (a.stamp ?? .distantPast) > (b.stamp ?? .distantPast) }
        for extra in ours.dropFirst(5) {
            try? FileManager.default.removeItem(at: extra)
        }
    }

    /// The copies kept for a space, newest first.
    static func copies(space: UUID = Space.firstID) -> [Copy] {
        let file = file(space)
        let folder = file.deletingLastPathComponent().appendingPathComponent("Backups", isDirectory: true)
        let prefix = file.deletingPathExtension().lastPathComponent + "-"
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.creationDateKey], options: .skipsHiddenFiles)) ?? []
        return files
            .filter { $0.lastPathComponent.hasPrefix(prefix) && $0.pathExtension == "json" }
            .compactMap { url -> Copy? in
                guard let date = url.stamp else { return nil }
                return Copy(url: url, date: date)
            }
            .sorted { $0.date > $1.date }
    }

    struct Copy: Identifiable {
        var url: URL
        var date: Date
        var id: String { url.path }
    }

    /// Put a copy back as the live session. The caller reloads the row.
    static func replace(space: UUID, with url: URL) -> Bool {
        guard let data = try? Data(contentsOf: url),
              (try? JSONDecoder().decode(Shape.self, from: data)) != nil
        else { return false }
        let live = file(space)
        try? FileManager.default.createDirectory(at: live.deletingLastPathComponent(), withIntermediateDirectories: true)
        do {
            try data.write(to: live, options: .atomic)
            return true
        } catch {
            return false
        }
    }
}

private extension URL {
    var stamp: Date? {
        (try? resourceValues(forKeys: [.creationDateKey]).creationDate)
            ?? (try? resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
    }
}
