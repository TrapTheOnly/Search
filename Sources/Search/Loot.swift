import Foundation
import AppKit
import WebKit
import Combine

// What you have kept. Downloads work already; this is only the memory of them,
// so a file you fetched an hour ago is one click from the Finder rather than a
// hunt through a folder. `Fetch` is one still arriving — progress and a cancel.

struct Keep: Codable, Identifiable, Equatable {
    var name: String
    var from: String
    var path: String
    var date: Date

    var id: String { path }

    var url: URL { URL(fileURLWithPath: path) }
    var stillThere: Bool { FileManager.default.fileExists(atPath: path) }
}

/// A download still under way. WebKit's `WKDownload` holds the bytes; this
/// holds the name and how far along, so the panel can draw without asking
/// the download for UI state on every frame. `download` is nil only for a
/// demo row used by the probe (screenshots) — never in ordinary use.
@MainActor
final class Fetch: ObservableObject, Identifiable {
    let id = UUID()
    let download: WKDownload?
    @Published private(set) var name: String
    @Published private(set) var fraction: Double = 0
    @Published private(set) var received: Int64 = 0
    @Published private(set) var expected: Int64 = 0

    private var bag = Set<AnyCancellable>()

    init(_ download: WKDownload, name: String = "Downloading…") {
        self.download = download
        self.name = name
        let progress = download.progress
        progress.publisher(for: \.fractionCompleted)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] value in self?.fraction = value }
            .store(in: &bag)
        progress.publisher(for: \.completedUnitCount)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] value in self?.received = value }
            .store(in: &bag)
        progress.publisher(for: \.totalUnitCount)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] value in self?.expected = value }
            .store(in: &bag)
        progress.publisher(for: \.fileURL)
            .compactMap { $0 }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] url in self?.name = url.lastPathComponent }
            .store(in: &bag)
    }

    /// A stand-in for probe screenshots — progress without a WebKit download.
    init(demo name: String, fraction: Double, received: Int64, expected: Int64) {
        self.download = nil
        self.name = name
        self.fraction = fraction
        self.received = received
        self.expected = expected
    }

    func titled(_ name: String) {
        guard !name.isEmpty else { return }
        self.name = name
    }

    func cancel() { download?.cancel() }

    /// "12 MB of 48 MB · 42%", or a percent when the size isn't known yet.
    var progressSaid: String {
        let percent = Int((min(max(fraction, 0), 1) * 100).rounded())
        if expected > 0 {
            let sizes = "\(Fetch.bytes.string(fromByteCount: received)) of \(Fetch.bytes.string(fromByteCount: expected))"
            return percent > 0 ? "\(sizes) · \(percent)%" : sizes
        }
        if received > 0 {
            return Fetch.bytes.string(fromByteCount: received)
        }
        return percent > 0 ? "\(percent)%" : "Starting…"
    }

    private static let bytes: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        return formatter
    }()
}

@MainActor
final class Loot: ObservableObject {
    @Published private(set) var kept: [Keep] = []

    init() { load() }

    func add(_ keep: Keep) {
        kept.removeAll { $0.path == keep.path }
        kept.insert(keep, at: 0)
        // Fifty is more than anybody scrolls back through.
        if kept.count > 50 { kept.removeLast(kept.count - 50) }
        save()
    }

    func forget(_ keep: Keep) {
        kept.removeAll { $0.id == keep.id }
        save()
    }

    /// Only the list is emptied. Files you asked for are yours, and deleting
    /// them is the Finder's business, not a browser's.
    func forgetAll() {
        kept = []
        save()
    }

    func reveal(_ keep: Keep) {
        NSWorkspace.shared.activateFileViewerSelecting([keep.url])
    }

    func open(_ keep: Keep) {
        NSWorkspace.shared.open(keep.url)
    }

    private static var file: URL { Store.file("downloads.json") }

    private func load() {
        guard let data = try? Data(contentsOf: Loot.file),
              let list = try? JSONDecoder().decode([Keep].self, from: data)
        else { return }
        kept = list
    }

    private func save() {
        let snapshot = kept
        let file = Loot.file
        DispatchQueue.global(qos: .utility).async {
            guard let data = try? JSONEncoder().encode(snapshot) else { return }
            try? FileManager.default.createDirectory(
                at: file.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try? data.write(to: file, options: .atomic)
        }
    }
}
