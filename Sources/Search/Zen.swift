import SwiftUI

// Essentials, folders, glance, and split. Essentials stay profile-wide and
// sticky across spaces (see TabBar). Folders / glance / split are ported from
// feature/light-zen; Essentials persistence stays the sticky cut (first space
// session only — do not re-write essentials onto every space).
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
// - Ordinary pins and tab folders are **per space**.
// - Glance is option-click / menu peek (Peek.swift remains shift-click).
// - Split shows two strip tabs side by side; not written to the session.
// - A space with `sharesSignIns == false` ("signed out") isolates cookies /
//   sign-ins only. Essentials still show there — they are not migrated into
//   that space's session. True isolation (hide Essentials too) is a Profile.
// - Persistence writes the essentials list onto the first space's session
//   file only, so a signed-out space never looks like it "owns" them.

struct TabFolder: Identifiable, Equatable {
    var id: UUID
    var name: String
    var collapsed: Bool
}

/// What the strip and the column draw, in order: essentials, this space's
/// pins, then folders and loose tabs.
enum StripPiece: Identifiable {
    case essential(Tab)
    case pin(Tab)
    case folder(TabFolder, [Tab])
    case loose(Tab)

    var id: UUID {
        switch self {
        case .essential(let tab), .pin(let tab), .loose(let tab): return tab.id
        case .folder(let folder, _): return folder.id
        }
    }

    var tab: Tab? {
        switch self {
        case .essential(let tab), .pin(let tab), .loose(let tab): return tab
        case .folder: return nil
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

    var splitMate: Tab? { splitID.flatMap { id in strip.first { $0.id == id } } }

    var spacePins: Int { tabs.filter { $0.pin != nil && !$0.essential }.count }

    var pieces: [StripPiece] {
        var out: [StripPiece] = essentials.map { .essential($0) }
        out += spacePieces
        return out
    }

    /// This space only — pins, folders, loose — for the sticky strip's swipe row.
    var spacePieces: [StripPiece] {
        var out: [StripPiece] = tabs.filter { $0.pin != nil && !$0.essential }.map { .pin($0) }
        let loose = tabs.filter { $0.pin == nil && !$0.essential }
        var seen = Set<UUID>()
        for tab in loose {
            if let fid = tab.folderID, let folder = folders.first(where: { $0.id == fid }) {
                if seen.insert(fid).inserted {
                    out.append(.folder(folder, loose.filter { $0.folderID == fid }))
                }
            } else {
                out.append(.loose(tab))
            }
        }
        for folder in folders where !seen.contains(folder.id) {
            out.append(.folder(folder, []))
        }
        return out
    }

    /// Folders that are shut hide their members.
    var shownPieces: [StripPiece] {
        pieces.flatMap(expandFolder)
    }

    var spaceShownPieces: [StripPiece] {
        spacePieces.flatMap(expandFolder)
    }

    private func expandFolder(_ piece: StripPiece) -> [StripPiece] {
        guard case .folder(let folder, let members) = piece else { return [piece] }
        if folder.collapsed { return [.folder(folder, members)] }
        return [.folder(folder, members)] + members.map { .loose($0) }
    }

    // MARK: - session rows

    func sessionEntry(for tab: Tab) -> Session.Entry? {
        guard !tab.shy, !tab.bench else { return nil }
        guard let url = tab.pending ?? tab.address,
              url.scheme?.hasPrefix("http") == true
        else { return nil }
        let collapsed = tab.folderID.flatMap { id in folders.first { $0.id == id }?.collapsed }
        return Session.Entry(
            url: url.absoluteString,
            title: tab.title,
            pin: tab.pin,
            name: tab.name,
            folder: tab.folderID?.uuidString,
            collapsed: collapsed
        )
    }

    func apply(_ entry: Session.Entry, to tab: Tab) {
        tab.pin = entry.pin
        tab.folderID = entry.folder.flatMap(UUID.init(uuidString:))
    }

    func folders(from saved: Session.Shape) -> [TabFolder] {
        if let listed = saved.folders {
            return listed.compactMap { raw in
                guard let id = UUID(uuidString: raw.id) else { return nil }
                return TabFolder(id: id, name: raw.name, collapsed: raw.collapsed)
            }
        }
        var seen: [UUID: TabFolder] = [:]
        for entry in saved.tabs {
            guard let text = entry.folder, let id = UUID(uuidString: text) else { continue }
            if seen[id] == nil {
                seen[id] = TabFolder(id: id, name: "Folder", collapsed: entry.collapsed ?? false)
            } else if let collapsed = entry.collapsed {
                seen[id]?.collapsed = collapsed
            }
        }
        return Array(seen.values)
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
            apply(entry, to: tab)
            tab.folderID = nil
            tab.essential = true
            if tab.pin == nil { tab.pin = tab.monogram }
            essentials.append(tab)
        }
    }

    // MARK: - glance

    func glance(_ url: URL) {
        closeGlance()
        glance = Glance(url: url, browser: self)
    }

    func glance(_ tab: Tab) {
        guard let url = tab.pending ?? tab.address else { return }
        glance(url)
    }

    func closeGlance() {
        // Keep the page in the card while it settles out. Tearing the web
        // view down first emptied the stage, then the overlay faded — a
        // blank flash, then a fade, instead of one motion.
        let dying = glance
        glance = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { dying?.discard() }
    }

    func promoteGlance() {
        guard let url = glance?.address else { return }
        closeGlance()
        open(url, foreground: true)
    }

    func splitGlance() {
        guard let url = glance?.address else { return }
        closeGlance()
        let tab = open(url, foreground: false)
        splitAside(tab)
    }

    // MARK: - split

    func splitAside(_ tab: Tab) {
        closeGlance()
        if tab.id == activeID {
            guard let other = strip.filter({ $0.id != tab.id && !$0.isBlank }).max(by: { $0.touched < $1.touched })
            else {
                announce("Nothing to split with")
                return
            }
            splitID = other.id
            if !other.wake() { other.revive() }
        } else {
            splitID = tab.id
            if !tab.wake() { tab.revive() }
        }
    }

    func endSplit() { splitID = nil }

    /// The cross on a pane: back to one page, the tab itself stays.
    func closePane(_ tab: Tab) {
        guard splitID != nil else { return }
        if tab.id == splitID {
            splitID = nil
            return
        }
        if tab.id == activeID, let mate = splitMate {
            splitID = nil
            select(mate)
        }
    }

    // MARK: - essentials

    func makeEssential(_ tab: Tab) {
        if tab.pin == nil { pin(tab) }
        tab.folderID = nil
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

    // MARK: - folders

    func newFolder(around tab: Tab) {
        Ask.name("New Folder", placeholder: "Name", initial: "Folder", confirm: "Create") { name in
            let folder = TabFolder(id: UUID(), name: name, collapsed: false)
            self.folders.append(folder)
            tab.folderID = folder.id
            if tab.pin != nil { self.unpin(tab) }
            self.writeSession(now: true)
        }
    }

    func place(_ tab: Tab, in folder: TabFolder) {
        guard !tab.essential else { return }
        if tab.pin != nil { unpin(tab) }
        tab.folderID = folder.id
        rememberSession()
    }

    func removeFromFolder(_ tab: Tab) {
        tab.folderID = nil
        rememberSession()
    }

    func renameFolder(_ folder: TabFolder) {
        Ask.name("Rename Folder", placeholder: folder.name, initial: folder.name, confirm: "Rename") { name in
            guard let at = self.folders.firstIndex(where: { $0.id == folder.id }) else { return }
            self.folders[at].name = name
            self.writeSession(now: true)
        }
    }

    func deleteFolder(_ folder: TabFolder) {
        for tab in tabs where tab.folderID == folder.id { tab.folderID = nil }
        folders.removeAll { $0.id == folder.id }
        writeSession(now: true)
    }

    func toggleFolder(_ folder: TabFolder) {
        guard let at = folders.firstIndex(where: { $0.id == folder.id }) else { return }
        withAnimation(Motion.settle) { folders[at].collapsed.toggle() }
        rememberSession()
    }

    /// Session folder rows for the current `folders` list.
    var sessionFolders: [Session.Folder] {
        folders.map { Session.Folder(id: $0.id.uuidString, name: $0.name, collapsed: $0.collapsed) }
    }
}

/// Two tabs side by side in the stage.
struct SplitStage: View {
    @ObservedObject var browser: Browser
    let left: Tab
    let right: Tab

    var body: some View {
        HStack(spacing: 0) {
            pane(left)
            Rectangle().fill(Palette.hairline).frame(width: 1)
            pane(right)
        }
    }

    private func pane(_ tab: Tab) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text(tab.label)
                    .font(.system(size: 11.5, weight: tab.id == browser.activeID ? .medium : .regular))
                    .foregroundStyle(tab.id == browser.activeID ? Palette.ink : Palette.muted)
                    .lineLimit(1)
                Spacer(minLength: 0)
                Door(icon: "xmark", help: "Close pane") { browser.closePane(tab) }
            }
            .padding(.horizontal, 10)
            .frame(height: 28)
            .background(tab.id == browser.activeID ? Palette.wash : Palette.ground)
            .contentShape(Rectangle())
            .onTapGesture { browser.select(tab) }

            Page(tab: tab)
        }
    }
}

/// A named group in the strip: the same pill as a tab, a chevron for shut.
struct FolderChip: View {
    @ObservedObject var browser: Browser
    let folder: TabFolder
    let members: [Tab]
    var width: CGFloat = 120
    var onDrop: (() -> Void)?

    @State private var hovering = false

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "chevron.right")
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(Palette.muted)
                .rotationEffect(.degrees(folder.collapsed ? 0 : 90))
            Text(folder.name)
                .font(.system(size: 12))
                .foregroundStyle(Palette.ink)
                .lineLimit(1)
            Text("\(members.count)")
                .font(.system(size: 10))
                .foregroundStyle(Palette.muted)
        }
        .padding(.horizontal, 8)
        .frame(width: width, height: 28)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(hovering ? Palette.hover : Palette.wash.opacity(0.55))
        )
        .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .onTapGesture { browser.toggleFolder(folder) }
        .onHover { hovering = $0 }
        .contextMenu {
            Button("Rename") { browser.renameFolder(folder) }
            Button("Delete") { browser.deleteFolder(folder) }
        }
        .onDrop(of: [.url, .text], isTargeted: nil) { providers in
            onDrop?()
            return browser.take(providers)
        }
        .animation(Motion.quick, value: hovering)
        .animation(Motion.settle, value: folder.collapsed)
    }
}

/// The same group, as a line in the column.
struct FolderRow: View {
    @ObservedObject var browser: Browser
    let folder: TabFolder
    let members: [Tab]
    var onDrop: (() -> Void)?

    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "chevron.right")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(Palette.muted)
                .rotationEffect(.degrees(folder.collapsed ? 0 : 90))
                .frame(width: 12)
            Text(folder.name)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(Palette.ink)
                .lineLimit(1)
            Spacer(minLength: 0)
            Text("\(members.count)")
                .font(.system(size: 11))
                .foregroundStyle(Palette.muted)
        }
        .padding(.horizontal, 10)
        .frame(height: 28)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(hovering ? Palette.hover : .clear)
        )
        .contentShape(Rectangle())
        .onTapGesture { browser.toggleFolder(folder) }
        .onHover { hovering = $0 }
        .contextMenu {
            Button("Rename") { browser.renameFolder(folder) }
            Button("Delete") { browser.deleteFolder(folder) }
        }
        .onDrop(of: [.url, .text], isTargeted: nil) { _ in
            onDrop?()
            return false
        }
        .animation(Motion.quick, value: hovering)
        .animation(Motion.settle, value: folder.collapsed)
    }
}
