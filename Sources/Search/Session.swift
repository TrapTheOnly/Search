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
    }

    struct Shape: Codable {
        var tabs: [Entry]
        var active: Int
    }

    /// One live tab, as `writeSession` sees it: enough to decide whether it
    /// is written, and where the selection lands after the ones that aren't.
    struct Live {
        var id: UUID
        var shy: Bool
        var bench: Bool
        var url: URL?
        var title: String
        var pin: String?
        var name: String?
    }

    /// Private, bench, and non-http tabs stay out of the file. `active` is
    /// an index into what remains, so a bench tab sitting before the one
    /// you were looking at does not shift the restored selection.
    static func compact(_ tabs: [Live], active: UUID?) -> Shape {
        let kept = tabs.compactMap { tab -> (UUID, Entry)? in
            guard !tab.shy, !tab.bench else { return nil }
            guard let url = tab.url, url.scheme?.hasPrefix("http") == true else { return nil }
            return (tab.id, Entry(
                url: url.absoluteString, title: tab.title, pin: tab.pin, name: tab.name
            ))
        }
        return Shape(
            tabs: kept.map(\.1),
            active: kept.firstIndex { $0.0 == active } ?? 0
        )
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

    /// One writer for every session file. A utility write that left after a
    /// quit write was scheduled would otherwise reach the disk last and put
    /// yesterday back.
    private static let writer = DispatchQueue(label: "search.session.write")

    /// `now` waits for the writer. Quitting doesn't wait for a
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
        }
        if now {
            writer.sync(execute: put)
        } else {
            writer.async(execute: put)
        }
    }
}
