import SwiftUI

// Essentials: pins that stay visible in every space of this profile, above
// that space's own tabs. Ordinary pins stay where they are. Ported from
// feature/light-zen; folders, glance and split stay out of this cut.
//
// Two verbs, not a gradient:
// - **Pin** — per-space only; lives in that space's pin grid / strip.
// - **Essential** — profile-wide; sticky above space pins in the sidebar and
//   beside the top-bar swipe (TabBar).
// Pin does not "promote toward" Essential.
//
// Scope (Zen-aligned):
// - Essentials are **profile-wide**, not space-owned. Switching spaces must
//   not unload or rebuild them (sticky strip in TabBar; sticky essentials
//   block above the sidebar swipe in Side).
// - A space with `sharesSignIns == false` ("signed out") isolates cookies /
//   sign-ins only. Essentials still show there — they are not migrated into
//   that space's session. True isolation (hide Essentials too) is a Profile.
// - Persistence writes the essentials list onto the first space's session
//   file only, so a signed-out space never looks like it "owns" them.

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

    var spacePins: Int { tabs.filter { $0.pin != nil && !$0.essential }.count }

    var pieces: [StripPiece] {
        var out: [StripPiece] = essentials.map { .essential($0) }
        out += tabs.filter { $0.pin != nil && !$0.essential }.map { .pin($0) }
        out += tabs.filter { $0.pin == nil && !$0.essential }.map { .loose($0) }
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

    /// Restore profile-wide essentials once. Prefer the first space's session
    /// (canonical home); fall back to whatever the current space file still
    /// carries from older builds that wrote essentials everywhere.
    func adoptEssentials(from saved: Session.Shape) {
        guard essentials.isEmpty else { return }
        let home = Session.read(space: Space.firstID)
        let rows = home.essentials ?? saved.essentials
        guard let rows, !rows.isEmpty else { return }
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
        // Belt and braces: nothing essential may remain in the space row.
        scrubSpaceRow()
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
