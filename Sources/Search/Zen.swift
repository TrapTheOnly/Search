import SwiftUI

// The lighter pieces: essentials, folders, split, recent-tab switching,
// space routing, command-bar actions, pin reset, and putting a session
// copy back. Each is a method on Browser; the views sit with the thing
// they draw.

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

    var spacePins: Int { tabs.filter { $0.pin != nil }.count }

    var pieces: [StripPiece] {
        var out: [StripPiece] = essentials.map { .essential($0) }
        out += tabs.filter { $0.pin != nil }.map { .pin($0) }
        let loose = tabs.filter { $0.pin == nil }
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
        pieces.flatMap { piece -> [StripPiece] in
            guard case .folder(let folder, let members) = piece else { return [piece] }
            if folder.collapsed { return [.folder(folder, members)] }
            return [.folder(folder, members)] + members.map { .loose($0) }
        }
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
            pinURL: tab.pinURL?.absoluteString,
            folder: tab.folderID?.uuidString,
            collapsed: collapsed
        )
    }

    func apply(_ entry: Session.Entry, to tab: Tab) {
        tab.pin = entry.pin
        tab.pinURL = entry.pinURL.flatMap(URL.init(string:))
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

    func adoptEssentials(from saved: Session.Shape) {
        guard essentials.isEmpty, let rows = saved.essentials, !rows.isEmpty else { return }
        for entry in rows {
            guard let url = URL(string: entry.url) else { continue }
            let tab = Tab()
            prepare(tab)
            tab.restore(url: url, title: entry.title, name: entry.name)
            apply(entry, to: tab)
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
        if tab.pinURL == nil { tab.pinURL = tab.pending ?? tab.address }
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

    func movePin(_ tab: Tab, to combined: Int) {
        if tab.essential {
            move(tab, to: min(max(0, combined), max(0, essentials.count - 1)))
        } else {
            move(tab, to: max(0, combined - essentials.count))
        }
    }

    // MARK: - space routing

    func host(of url: URL) -> String? {
        guard let host = url.host()?.lowercased() else { return nil }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    func routedSpace(for url: URL) -> UUID? {
        guard prefs.usesSpaces, let host = host(of: url) else { return nil }
        if let id = prefs.routes[host].flatMap(UUID.init(uuidString:)) { return id }
        if let raw = url.host()?.lowercased(), let id = prefs.routes[raw].flatMap(UUID.init(uuidString:)) {
            return id
        }
        return nil
    }

    @discardableResult
    func openRouted(_ url: URL, in id: UUID) -> Tab {
        if id != spaceID { switchSpace(to: id) }
        if let active, active.isBlank, typed.isEmpty, !active.floating {
            active.go(to: url)
            editing = false
            return active
        }
        return open(url, foreground: true, atEnd: true)
    }

    func move(_ tab: Tab, toSpace id: UUID) {
        guard id != spaceID, !tab.essential else { return }
        guard let index = tabs.firstIndex(where: { $0.id == tab.id }) else { return }
        if splitID == tab.id { splitID = nil }
        detach(tab)
        if activeID == tab.id {
            if let next = tabs[safe: min(index, max(0, tabs.count - 1))] {
                select(next)
            } else if let pin = essentials.first {
                select(pin)
            } else {
                newTab()
            }
        }
        var row = parked[id] ?? loadRow(id)
        row.tabs.append(tab)
        parked[id] = row
        writeSession(now: true)
        writeParked(id)
        announce("Moved to \(spaces.first { $0.id == id }?.name ?? "space")")
    }

    func alwaysOpen(_ tab: Tab, in id: UUID) {
        guard let host = (tab.address ?? tab.pending).flatMap({ host(of: $0) }) else { return }
        prefs.routes[host] = id.uuidString
        announce("\(host) opens in \(spaces.first { $0.id == id }?.name ?? "that space")")
        if id != spaceID { move(tab, toSpace: id) }
    }

    func writeParked(_ id: UUID) {
        guard let row = parked[id] else { return }
        let kept = folders
        folders = row.folders
        Session.write(
            now: true,
            space: id,
            .init(
                tabs: row.tabs.compactMap { sessionEntry(for: $0) },
                active: row.tabs.firstIndex { $0.id == row.active } ?? 0,
                folders: row.folders.map { Session.Folder(id: $0.id.uuidString, name: $0.name, collapsed: $0.collapsed) },
                essentials: essentials.compactMap { sessionEntry(for: $0) }
            )
        )
        folders = kept
    }

    // MARK: - reset pin

    func rememberPin(_ tab: Tab) {
        if tab.pinURL == nil { tab.pinURL = tab.pending ?? tab.address }
    }

    func resetPin(_ tab: Tab) {
        guard let url = tab.pinURL else {
            announce("No pin to reset")
            return
        }
        tab.go(to: url)
        announce("Pin reset")
    }

    // MARK: - recent tabs

    func recentIDs() -> [Tab.ID] {
        Array(strip.filter { !$0.isBlank }.sorted { $0.touched > $1.touched }.prefix(7).map(\.id))
    }

    func cycleRecent(back: Bool) {
        if switcher.isEmpty {
            switcher = recentIDs()
            guard !switcher.isEmpty else { return }
            if let here = activeID, let at = switcher.firstIndex(of: here) {
                switcherPick = (at + (back ? -1 : 1) + switcher.count) % switcher.count
            } else {
                switcherPick = back ? switcher.count - 1 : min(1, switcher.count - 1)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) { [weak self] in
                guard let self, !self.switcher.isEmpty else { return }
                self.switching = true
            }
        } else {
            let n = switcher.count
            guard n > 0 else { return }
            switcherPick = (switcherPick + (back ? -1 : 1) + n) % n
            switching = true
        }
    }

    func landSwitcher() {
        guard !switcher.isEmpty else { return }
        if let id = switcher[safe: switcherPick], let tab = find(id) {
            select(tab)
        }
        cancelSwitcher()
    }

    func cancelSwitcher() {
        switching = false
        switcher = []
        switcherPick = 0
    }

    // MARK: - command bar

    func commands(matching typed: String) -> [Suggestion] {
        let needle = typed.trimmingCharacters(in: .whitespaces).lowercased()
        var rows: [(String, String, String)] = [
            ("New Tab", "A blank tab", "new-tab"),
            ("Reopen Closed Tab", ghosts.last.map(\.label) ?? "Nothing closed", "reopen"),
            ("Duplicate Tab", "This page, beside itself", "duplicate"),
            (folded ? "Show Tab Bar" : "Fold Tab Bar", "⌘S", "fold"),
        ]
        if prefs.usesSpaces {
            rows.append(("New Space", "A separate set of tabs", "new-space"))
        }
        if let tab = active {
            rows.append((tab.pin == nil ? "Pin Tab" : "Unpin Tab", tab.label, "pin"))
            if tab.pinURL != nil {
                rows.append(("Reset Pin", tab.pinURL.map { Address.pretty($0) } ?? "", "reset-pin"))
            }
            if splitID == nil, strip.count > 1 {
                rows.append(("Split to the Side", "Two pages in this window", "split"))
            } else if splitID != nil {
                rows.append(("End Split", "Back to one page", "split"))
            }
            if tab.folderID == nil, tab.pin == nil, !tab.isBlank {
                rows.append(("New Folder", "A group in the tab strip", "folder"))
            }
        }
        if glance != nil {
            rows.append(("Close Glance", glance?.title ?? "The peek", "glance-close"))
        }
        let copies = Session.copies(space: spaceID).prefix(3)
        for (n, copy) in copies.enumerated() {
            rows.append((
                "Restore Session",
                copy.date.formatted(date: .abbreviated, time: .shortened),
                "restore-\(n)"
            ))
        }
        return rows
            .filter { needle.isEmpty || $0.0.lowercased().contains(needle) || $0.1.lowercased().contains(needle) }
            .prefix(8)
            .map { Suggestion(key: $0.0, title: $0.1, url: URL(string: "about:blank")!, kind: .command, action: $0.2) }
    }

    func runCommand(_ id: String) {
        switch id {
        case "new-tab": newTab()
        case "new-space": askForSpace()
        case "reopen": reopen()
        case "duplicate": duplicate()
        case "pin":
            guard let tab = active else { return }
            tab.pin == nil ? pin(tab) : unpin(tab)
        case "reset-pin":
            if let tab = active { resetPin(tab) }
        case "glance-close": closeGlance()
        case "split":
            if splitID != nil { endSplit() }
            else if let tab = active { splitAside(tab) }
        case "fold": toggleFold()
        case "folder":
            if let tab = active { newFolder(around: tab) }
        case let rest where rest.hasPrefix("restore-"):
            let n = Int(rest.dropFirst(8)) ?? 0
            let copies = Session.copies(space: spaceID)
            if copies.indices.contains(n) { confirmRestore(copies[n]) }
        default:
            break
        }
    }

    func performKey(_ id: String) -> Bool {
        switch id {
        case "newTab": newTab()
        case "newPrivate": newShyTab()
        case "reopen": reopen()
        case "address": edit()
        case "closeTab":
            if let tab = active { close(tab) }
        case "print": printPage()
        case "find": openFind()
        case "findNext": look(forward: true)
        case "findPrev": look(forward: false)
        case "sidebar": toggleSidebar()
        case "fold": toggleFold()
        case "reload": reload()
        case "reader": toggleReader()
        case "float": toggleFloat()
        case "hide": toggleHiding()
        case "hidden": reviewing.toggle()
        case "zoomIn": zoom(by: 1.1)
        case "zoomOut": zoom(by: 1 / 1.1)
        case "actualSize": resetZoom()
        case "inspector": toggleInspector()
        case "console": showConsole()
        case "inspect": inspectElement()
        case "back": back()
        case "forward": forward()
        case "nextTab": step(1)
        case "prevTab": step(-1)
        case "searchTabs":
            if editing, !offers.isEmpty { stepSummon() } else { summon() }
        case "duplicate": duplicate()
        case "copyAddress": copyAddress()
        case "pasteAndGo": pasteAndGo()
        case "pause": pauseMedia()
        case "bookmark": bookmarkCurrent()
        case "history": recalling.toggle()
        case "downloads": hoarding.toggle()
        case "settings": tuning.toggle()
        case "passwords": managing.toggle()
        case "cycleTabs": cycleRecent(back: false)
        case "cycleTabsBack": cycleRecent(back: true)
        case "resetPin":
            if let tab = active { resetPin(tab) }
        default:
            return false
        }
        return true
    }

    func captureShortcut(_ event: NSEvent) -> Bool {
        guard let id = recordingShortcut else { return false }
        if event.keyCode == 53 {
            recordingShortcut = nil
            return true
        }
        prefs.shortcutOverrides[id] = Stroke.from(event)
        recordingShortcut = nil
        announce("Shortcut set")
        return true
    }

    // MARK: - session backup

    func confirmRestore(_ copy: Session.Copy) {
        Ask.sure(
            "Restore this session?",
            detail: "The tabs open now are replaced by the ones from \(copy.date.formatted(date: .abbreviated, time: .shortened)). A copy of this session is kept first.",
            confirm: "Restore"
        ) { [weak self] in
            self?.restoreBackup(copy.url)
        }
    }

    func restoreBackup(_ url: URL) {
        writeSession(now: true)
        guard Session.replace(space: spaceID, with: url) else {
            announce("Couldn't restore that copy")
            return
        }
        endSplit()
        closeGlance()
        cancelSwitcher()
        for tab in tabs { tab.close() }
        for tab in essentials { tab.close() }
        resetRow()
        essentials = []
        folders = []
        activeID = nil
        restoreSession()
        announce("Session restored")
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

/// Two existing tabs, side by side. Closing a pane puts one page back.
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

/// Up to seven recent tabs: title and host, no live page.
struct SwitcherCard: View {
    @ObservedObject var browser: Browser

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(browser.switcher.enumerated()), id: \.element) { index, id in
                if let tab = browser.find(id) {
                    HStack(spacing: 10) {
                        Text(tab.label)
                            .font(.system(size: 13))
                            .foregroundStyle(Palette.ink)
                            .lineLimit(1)
                        Spacer(minLength: 8)
                        if let host = (tab.address ?? tab.pending).flatMap({ Address.pretty($0) }) {
                            Text(host)
                                .font(.system(size: 12))
                                .foregroundStyle(Palette.muted)
                                .lineLimit(1)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background {
                        if index == browser.switcherPick {
                            RoundedRectangle(cornerRadius: 9, style: .continuous)
                                .fill(Palette.wash)
                        }
                    }
                }
            }
        }
        .padding(6)
        .frame(width: 360)
        .background(Palette.ground, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Palette.hairline, lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.10), radius: 20, y: 6)
        .transition(.scale(scale: 0.97).combined(with: .opacity))
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
