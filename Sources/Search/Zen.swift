import SwiftUI

// Essentials: pins that stay visible in every space, above that space's own
// tabs. Ordinary pins stay where they are. Ported from feature/light-zen;
// folders, glance and split stay out of this cut.

/// What the strip and the column draw, in order: essentials, this space's
/// pins, then loose tabs.
enum StripPiece: Identifiable {
    case essential(Tab)
    case pin(Tab)
    case loose(Tab)

    var id: UUID {
        switch self {
        case .essential(let tab), .pin(let tab), .loose(let tab): return tab.id
        }
    }

    var tab: Tab? {
        switch self {
        case .essential(let tab), .pin(let tab), .loose(let tab): return tab
        }
    }
}

extension Browser {
    /// Essentials first, then this space — the row the strip shows.
    var strip: [Tab] { essentials + tabs }

    func find(_ id: Tab.ID) -> Tab? {
        if let tab = strip.first(where: { $0.id == id }) { return tab }
        return parkedTabs.first { $0.id == id }
    }

    var spacePins: Int { tabs.filter { $0.pin != nil }.count }

    var pieces: [StripPiece] {
        var out: [StripPiece] = essentials.map { .essential($0) }
        out += tabs.filter { $0.pin != nil }.map { .pin($0) }
        out += tabs.filter { $0.pin == nil }.map { .loose($0) }
        return out
    }

    /// Same as pieces today; kept so a later folders port can fold members.
    var shownPieces: [StripPiece] { pieces }

    // MARK: - session rows

    func sessionEntry(for tab: Tab) -> Session.Entry? {
        guard !tab.shy, !tab.bench else { return nil }
        guard let url = tab.pending ?? tab.address,
              url.scheme?.hasPrefix("http") == true
        else { return nil }
        return Session.Entry(
            url: url.absoluteString,
            title: tab.title,
            pin: tab.pin,
            name: tab.name
        )
    }

    func adoptEssentials(from saved: Session.Shape) {
        guard essentials.isEmpty, let rows = saved.essentials, !rows.isEmpty else { return }
        for entry in rows {
            guard let url = URL(string: entry.url) else { continue }
            let tab = Tab()
            prepare(tab)
            tab.restore(url: url, title: entry.title, name: entry.name)
            tab.pin = entry.pin
            tab.essential = true
            if tab.pin == nil { tab.pin = tab.monogram }
            essentials.append(tab)
        }
    }

    // MARK: - essentials

    func makeEssential(_ tab: Tab) {
        if tab.pin == nil { pin(tab) }
        tab.essential = true
        detach(tab)
        if !essentials.contains(where: { $0.id == tab.id }) {
            essentials.append(tab)
        }
        writeSession(now: true)
    }

    func removeEssential(_ tab: Tab) {
        tab.essential = false
        essentials.removeAll { $0.id == tab.id }
        attach(tab, at: 0)
        writeSession(now: true)
    }

    /// Reorder within the combined pin block (essentials then this space's
    /// pins). Essentials and ordinary pins do not mix.
    func movePin(_ tab: Tab, to combined: Int) {
        if tab.essential {
            move(tab, to: min(max(0, combined), max(0, essentials.count - 1)))
        } else {
            move(tab, to: max(0, combined - essentials.count))
        }
    }
}
