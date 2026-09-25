import SwiftUI
import AppKit

// Essentials, folders, and split. Essentials stay profile-wide and
// sticky across spaces (see TabBar). Folders / split are ported from
// feature/light-zen; Essentials persistence stays the sticky cut (first space
// session only — do not re-write essentials onto every space).
//
// Two verbs, not a gradient:
// - **Pin** — per-space only; lives as a **row** under Essentials (Zen-style),
//   not an icon grid. Separated from loose tabs by a hairline.
// - **Essential** — profile-wide; sticky **icon squares** above space pins in
//   the sidebar and beside the top-bar swipe (TabBar).
// Pin does not "promote toward" Essential. Dragging into Essentials morphs a
// row into a square; dragging out morphs back.
//
// Scope (Zen-aligned):
// - Essentials are **profile-wide**, not space-owned. Switching spaces must
//   not unload or rebuild them (sticky strip in TabBar; sticky essentials
//   block above the sidebar swipe in Side).
// - Ordinary pins and tab folders are **per space**.
// - Peek is option-click / force-press / menu / shift-click (see Peek.swift).
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

    /// Ordered panes while split — left, then right. Nil when not split.
    var splitPanes: (left: Tab, right: Tab)? {
        guard let leftID = splitLeftID, let rightID = splitRightID,
              let left = find(leftID), let right = find(rightID),
              left.id != right.id
        else { return nil }
        return (left, right)
    }

    /// The two tab ids in the joint strip, leading then trailing.
    var splitGroupIDs: [Tab.ID]? {
        guard let left = splitLeftID, let right = splitRightID else { return nil }
        return [left, right]
    }

    /// Whether this tab is one of the two panes.
    func isSplitMember(_ tab: Tab) -> Bool {
        tab.id == splitLeftID || tab.id == splitRightID
    }

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

    // MARK: - split

    func splitAside(_ tab: Tab) {
        closePeek()
        let mate: Tab
        if tab.id == activeID {
            guard let other = strip.filter({ $0.id != tab.id && !$0.isBlank }).max(by: { $0.touched < $1.touched })
            else {
                announce("Nothing to split with")
                return
            }
            mate = other
        } else {
            mate = tab
        }
        guard let focus = active, focus.id != mate.id else {
            announce("Nothing to split with")
            return
        }
        if !mate.wake() { mate.revive() }
        withAnimation(Motion.flight) {
            splitAxis = .horizontal
            splitLeftID = focus.id
            splitRightID = mate.id
            splitID = mate.id
            splitRatio = 0.5
        }
        Haptics.generic()
    }

    /// Open `tab` as a new pane on the given stage edge — always ~50/50, never a sliver.
    func splitOnto(_ edge: SplitEdge, _ tab: Tab) {
        closePeek()
        guard !tab.isBlank else { return }
        let axis: SplitAxis = edge.isHorizontal ? .horizontal : .vertical
        if let panes = splitPanes {
            guard tab.id != panes.left.id, tab.id != panes.right.id else { return }
            if !tab.wake() { tab.revive() }
            withAnimation(Motion.flight) {
                splitAxis = axis
                switch edge {
                case .leading, .top: splitLeftID = tab.id
                case .trailing, .bottom: splitRightID = tab.id
                }
                syncSplitMate()
                splitRatio = 0.5
            }
            Haptics.generic()
            return
        }
        guard let focus = active, focus.id != tab.id else {
            splitAside(tab)
            if splitPanes != nil {
                withAnimation(Motion.settle) {
                    splitAxis = axis
                    if edge == .leading || edge == .top {
                        swapSplit(animated: false)
                    }
                    splitRatio = 0.5
                }
                Haptics.generic()
            }
            return
        }
        if !tab.wake() { tab.revive() }
        withAnimation(Motion.flight) {
            splitAxis = axis
            switch edge {
            case .leading, .top:
                splitLeftID = tab.id
                splitRightID = focus.id
            case .trailing, .bottom:
                splitLeftID = focus.id
                splitRightID = tab.id
            }
            splitID = tab.id
            splitRatio = 0.5
        }
        Haptics.generic()
    }

    func endSplit() {
        splitID = nil
        splitLeftID = nil
        splitRightID = nil
        splitRatio = 0.5
        splitAxis = .horizontal
        splitExpandingID = nil
        splitCarry.clear()
    }

    /// Swap the two panes' sides; focus stays on the same tab.
    /// One commit per gesture — callers gate with hysteresis before calling.
    func swapSplit(animated: Bool = true) {
        guard let left = splitLeftID, let right = splitRightID else { return }
        let apply = {
            self.splitLeftID = right
            self.splitRightID = left
            self.splitRatio = 1 - self.splitRatio
        }
        if animated {
            withAnimation(Motion.glide) { apply() }
        } else {
            apply()
        }
        Haptics.align()
    }

    /// Full-size one pane: grow that side inside `StageCanvas`, then clear split
    /// membership. The kept tab’s `Page` stays in the same ForEach identity —
    /// no `SplitStage` → solo `Page` remount, no blank WKWebView (Zen inset model).
    func expandPane(_ tab: Tab) {
        guard splitLeftID != nil, splitRightID != nil else { return }
        if tab.id != activeID { select(tab) }
        let growLeading = tab.id == splitLeftID
        splitCarry.clear()
        splitExpandingID = tab.id
        withAnimation(Motion.flight) {
            splitRatio = growLeading ? 1 : 0
        }
        Haptics.generic()
        DispatchQueue.main.asyncAfter(deadline: .now() + Metrics.splitExpandSettle) { [weak self] in
            guard let self, self.splitExpandingID == tab.id else { return }
            // Clear membership without animation so ForEach drops the mate only;
            // the kept page’s frame is already full-stage from the flight above.
            self.endSplit()
        }
    }

    /// The cross on a pane: back to one page, the other pane expands.
    func closePane(_ tab: Tab) {
        guard let left = splitLeftID, let right = splitRightID else { return }
        let keepID = tab.id == left ? right : (tab.id == right ? left : nil)
        guard let keepID, let keep = find(keepID) else {
            withAnimation(Motion.flight) { endSplit() }
            return
        }
        expandPane(keep)
    }

    /// Drag-reorder within the joint strip: `from` becomes leading or trailing.
    /// Ignores no-ops; gated so live drag cannot thrash hundreds of times/sec.
    func reorderSplitGroup(from: Tab.ID, asTrailing: Bool) {
        guard let left = splitLeftID, let right = splitRightID else { return }
        guard from == left || from == right else { return }
        let now = CACurrentMediaTime()
        guard now - lastSplitReorderAt > 0.28 else { return }
        let leading: Tab.ID
        let other: Tab.ID
        if asTrailing {
            leading = from == left ? right : left
            other = from
        } else {
            leading = from
            other = from == left ? right : left
        }
        guard leading != splitLeftID else { return }
        lastSplitReorderAt = now
        withAnimation(Motion.glide) {
            splitLeftID = leading
            splitRightID = other
            splitRatio = 1 - splitRatio
            syncSplitMate()
        }
        // Nudge strip order so the pair stays adjacent (loose tabs only).
        if let moving = find(other), let anchor = find(leading),
           moving.pin == nil, !moving.essential,
           anchor.pin == nil, !anchor.essential,
           let at = tabs.firstIndex(where: { $0.id == leading }) {
            move(moving, to: min(asTrailing ? at + 1 : at, tabs.count - 1))
        }
    }

    func beginCarry(_ id: Tab.ID) {
        splitCarry.begin(id, kind: .create)
    }

    /// Lift the carried tab into the mini-window (Zen-style drag interaction).
    func liftCarry(at point: CGPoint) {
        // Creating a split — never enter rearrange kind from the strip.
        if case .rearrange = splitCarry.kind { return }
        splitCarry.lift(at: point)
    }

    func updateCarryPoint(_ point: CGPoint) {
        splitCarry.move(at: point)
    }

    /// Pane-chrome rearrange: same tab stays “in hand”; swap only if finish lands on mate.
    func beginPaneRearrange(_ tab: Tab, from side: SplitEdge, at point: CGPoint) {
        guard isSplitMember(tab) else { return }
        splitCarry.beginRearrange(tab.id, from: side, at: point)
    }

    /// Finish a strip/sidebar/pane drag: create-split drop or rearrange swap on drop only.
    func finishCarry() {
        let id = splitCarry.tabID
        let edge = splitCarry.edge
        let lifted = splitCarry.lifted
        let kind = splitCarry.kind
        splitCarry.clear()
        guard lifted, let id, let tab = find(id) else { return }

        if case .rearrange = kind {
            // Zen: swapNodes only when drop side is the other half — never mid-hover.
            guard edge != nil else { return }
            swapSplit(animated: true)
            select(tab)
            return
        }

        guard let edge else { return }
        if splitPanes == nil, tab.id == activeID { return }
        splitOnto(edge, tab)
    }

    /// Keep `splitID` as the non-focused member of the pair.
    func syncSplitMate() {
        guard let left = splitLeftID, let right = splitRightID else {
            splitID = nil
            return
        }
        if activeID == left {
            splitID = right
        } else if activeID == right {
            splitID = left
        } else {
            splitID = right
        }
    }

    // MARK: - essentials

    func makeEssential(_ tab: Tab) {
        if tab.pin == nil { pin(tab) }
        rememberPin(tab)
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
        // Back as a space pin (still pinned), at the head of this space's pins.
        attach(tab, at: 0)
        scrubSpaceRow()
        writeSession(now: true)
    }

    // MARK: - pin URL / move to space

    /// Remember the address at first pin / essential, once.
    func rememberPin(_ tab: Tab) {
        if tab.pinURL == nil { tab.pinURL = tab.pending ?? tab.address }
    }

    /// Right-click › Replace URL with Current Page — pin home becomes here.
    func replacePinURL(_ tab: Tab) {
        guard let url = tab.pending ?? tab.address else {
            announce("Nothing to replace with")
            return
        }
        tab.pinURL = url
        writeSession(now: true)
        announce("Pin URL replaced")
    }

    /// Navigate back to the address remembered when the pin was made.
    func resetPin(_ tab: Tab) {
        guard let url = tab.pinURL else {
            announce("No pin to reset")
            return
        }
        tab.go(to: url)
        announce("Pin reset")
    }

    /// Move a non-essential tab into another space's parked row.
    func move(_ tab: Tab, toSpace id: UUID) {
        guard id != spaceID, !tab.essential else { return }
        guard let index = tabs.firstIndex(where: { $0.id == tab.id }) else { return }
        if splitID == tab.id || splitLeftID == tab.id || splitRightID == tab.id { endSplit() }
        detach(tab)
        if activeID == tab.id {
            let nextIndex = min(index, max(0, tabs.count - 1))
            if tabs.indices.contains(nextIndex) {
                select(tabs[nextIndex])
            } else if let pin = essentials.first {
                select(pin)
            } else {
                newTab()
            }
        }
        var row = parked[id] ?? loadRow(id)
        row.tabs.append(tab)
        row.tabs = Self.orderSpacePins(row.tabs)
        parked[id] = row
        writeSession(now: true)
        writeParked(id)
        announce("Moved to \(spaces.first { $0.id == id }?.name ?? "space")")
    }

    /// Persist another space's parked tabs (and that space's folders) to disk.
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
                essentials: nil
            )
        )
        folders = kept
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

/// Stage host: solo or split. Pages are ForEach’d by tab id so maximize /
/// unsplit never remounts the kept WKWebView (Zen absolute-inset model).
struct StageCanvas: View {
    @ObservedObject var browser: Browser

    @State private var hoveringHandle = false
    @State private var grabbingHandle = false
    @State private var ratioAtGrab: CGFloat?

    private var horizontal: Bool { browser.splitAxis == .horizontal }
    private var expanding: Bool { browser.splitExpandingID != nil }
    private var splitActive: Bool {
        browser.splitLeftID != nil && browser.splitRightID != nil
            && browser.splitLeftID != browser.splitRightID
    }

    private var tint: SpaceTint {
        browser.prefs.usesSpaces ? browser.space.wash : SpaceTint(rgb: Spaces.colourRGB[0])
    }

    /// Stable page identities for the stage — split pair or the active tab alone.
    private var pageIDs: [Tab.ID] {
        if let left = browser.splitLeftID, let right = browser.splitRightID, left != right {
            return [left, right]
        }
        if let id = browser.activeID { return [id] }
        return []
    }

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            ZStack(alignment: .topLeading) {
                ForEach(pageIDs, id: \.self) { id in
                    if let tab = browser.find(id) {
                        let layout = paneLayout(for: id, in: size)
                        pane(tab, side: side(for: id), showChrome: layout.showChrome)
                            .frame(width: max(0, layout.frame.width), height: max(0, layout.frame.height))
                            .offset(x: layout.frame.minX, y: layout.frame.minY)
                            .opacity(layout.opacity)
                            .zIndex(layout.z)
                            .allowsHitTesting(layout.opacity > 0.05 && !browser.splitCarry.isRearranging)
                    }
                }

                if splitActive, !expanding {
                    divider(in: size)
                }
            }
            .coordinateSpace(name: "split-stage")
            .frame(width: size.width, height: size.height)
            .overlay {
                SplitDragOverlay(browser: browser, carry: browser.splitCarry)
            }
            .overlay {
                if browser.prefs.showsLinks { LinkBubble(status: browser.linkStatus) }
            }
            .overlay(alignment: .topTrailing) {
                if browser.finding {
                    FindBar(browser: browser)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .overlay(alignment: .topLeading) {
                if let asked = browser.suggesting, pageIDs.contains(asked.tab) {
                    AccountList(browser: browser, asked: asked)
                        .transition(.opacity)
                }
            }
            .animation(Motion.quick, value: browser.suggesting)
        }
        .animation(Motion.flight, value: browser.splitLeftID)
        .animation(Motion.flight, value: browser.splitRightID)
        .animation(Motion.flight, value: browser.splitAxis)
        .animation(Motion.flight, value: browser.splitExpandingID)
        .animation(grabbingHandle ? nil : Motion.settle, value: browser.splitRatio)
        .animation(Motion.flight, value: pageIDs)
    }

    private func side(for id: Tab.ID) -> SplitEdge {
        if id == browser.splitLeftID {
            return horizontal ? .leading : .top
        }
        if id == browser.splitRightID {
            return horizontal ? .trailing : .bottom
        }
        return .leading
    }

    private struct PaneLayout {
        var frame: CGRect
        var opacity: Double
        var z: Double
        var showChrome: Bool
    }

    private func paneLayout(for id: Tab.ID, in size: CGSize) -> PaneLayout {
        guard splitActive,
              let left = browser.splitLeftID,
              let right = browser.splitRightID
        else {
            return PaneLayout(frame: CGRect(origin: .zero, size: size), opacity: 1, z: 0, showChrome: false)
        }

        let raw = browser.splitRatio
        let ratio: CGFloat = expanding
            ? min(max(raw, 0), 1)
            : min(max(raw, Metrics.splitMin), 1 - Metrics.splitMin)
        let handle = expanding ? 0 : Metrics.splitHandle
        let isLeft = id == left
        let isMateDying = expanding && browser.splitExpandingID != id
        let isExpanding = browser.splitExpandingID == id

        let frame: CGRect
        if horizontal {
            let first = max(0, size.width * ratio - handle / 2)
            let second = max(0, size.width - first - handle)
            if isLeft {
                frame = CGRect(x: 0, y: 0, width: first, height: size.height)
            } else {
                frame = CGRect(x: first + handle, y: 0, width: second, height: size.height)
            }
        } else {
            let first = max(0, size.height * ratio - handle / 2)
            let second = max(0, size.height - first - handle)
            if isLeft {
                frame = CGRect(x: 0, y: 0, width: size.width, height: first)
            } else {
                frame = CGRect(x: 0, y: first + handle, width: size.width, height: second)
            }
        }

        return PaneLayout(
            frame: frame,
            opacity: isMateDying ? 0 : 1,
            z: isExpanding ? 2 : (id == right ? 1 : 0),
            showChrome: !expanding
        )
    }

    private func pane(_ tab: Tab, side: SplitEdge, showChrome: Bool) -> some View {
        let focused = tab.id == browser.activeID
        // Chrome height collapses to 0 on maximize so `Page` stays the same
        // child in the VStack — no remount when leaving split.
        return VStack(spacing: 0) {
            chrome(tab, side: side)
                .frame(height: showChrome ? Metrics.splitChrome : 0)
                .clipped()
                .opacity(showChrome ? 1 : 0)
                .allowsHitTesting(showChrome)
            Page(tab: tab)
                .clipShape(Rectangle())
        }
        .overlay(alignment: .top) {
            if showChrome {
                Rectangle()
                    .fill(Spaces.splitAccent(tint, alpha: focused ? 0.55 : 0.22))
                    .frame(height: focused ? 2 : 1)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { browser.select(tab) }
    }

    private func chrome(_ tab: Tab, side: SplitEdge) -> some View {
        let focused = tab.id == browser.activeID
        return HStack(spacing: 4) {
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(focused ? Spaces.splitAccent(tint, alpha: 0.7) : Palette.faint)
                .padding(.trailing, 2)
            Text(tab.label)
                .font(.system(size: 11.5, weight: focused ? .semibold : .regular))
                .foregroundStyle(focused ? Palette.ink : Palette.muted)
                .lineLimit(1)
            Spacer(minLength: 0)
            Door(icon: "arrow.up.left.and.arrow.down.right", help: "Full size") {
                browser.expandPane(tab)
            }
            Door(icon: "xmark", help: "Close pane") {
                browser.closePane(tab)
            }
        }
        .padding(.horizontal, 8)
        .frame(height: Metrics.splitChrome)
        .background {
            ZStack {
                focused ? Palette.wash.opacity(0.9) : Palette.ground.opacity(0.55)
                Spaces.splitHeaderWash(tint, focused: focused)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { browser.select(tab) }
        .gesture(rearrangeDrag(for: tab, side: side))
        .help("Drag onto the other half to swap")
    }

    private func divider(in size: CGSize) -> some View {
        let span = horizontal ? size.width : size.height
        let raw = browser.splitRatio
        let ratio = min(max(raw, Metrics.splitMin), 1 - Metrics.splitMin)
        let handle = Metrics.splitHandle
        let first = max(0, span * ratio - handle / 2)
        let accent = Spaces.splitAccent(tint, alpha: hoveringHandle || grabbingHandle ? 0.7 : 0.4)

        return ZStack {
            Color.clear
            if horizontal {
                Rectangle().fill(accent).frame(width: 1)
                Capsule()
                    .fill(accent.opacity(hoveringHandle || grabbingHandle ? 1 : 0.65))
                    .frame(width: hoveringHandle || grabbingHandle ? 3 : 2, height: hoveringHandle || grabbingHandle ? 40 : 28)
            } else {
                Rectangle().fill(accent).frame(height: 1)
                Capsule()
                    .fill(accent.opacity(hoveringHandle || grabbingHandle ? 1 : 0.65))
                    .frame(width: hoveringHandle || grabbingHandle ? 40 : 28, height: hoveringHandle || grabbingHandle ? 3 : 2)
            }
        }
        .frame(
            width: horizontal ? handle : size.width,
            height: horizontal ? size.height : handle
        )
        .offset(
            x: horizontal ? first : 0,
            y: horizontal ? 0 : first
        )
        .contentShape(Rectangle())
        .onHover { over in
            hoveringHandle = over
            applyResizeCursor()
        }
        .gesture(
            DragGesture(minimumDistance: 1, coordinateSpace: .named("split-stage"))
                .onChanged { value in
                    if ratioAtGrab == nil {
                        ratioAtGrab = browser.splitRatio
                        grabbingHandle = true
                        applyResizeCursor()
                    }
                    let base = ratioAtGrab ?? 0.5
                    let delta = horizontal ? value.translation.width : value.translation.height
                    let next = base + delta / max(span, 1)
                    browser.splitRatio = min(max(next, Metrics.splitMin), 1 - Metrics.splitMin)
                    applyResizeCursor()
                }
                .onEnded { _ in
                    ratioAtGrab = nil
                    grabbingHandle = false
                    applyResizeCursor()
                }
        )
        .modifier(OneClick(double: true) {
            withAnimation(Motion.settle) { browser.splitRatio = 0.5 }
        })
        .animation(Motion.quick, value: hoveringHandle)
        .animation(Motion.quick, value: grabbingHandle)
        .zIndex(5)
        .help("Drag to resize · double-click to balance")
    }

    private func applyResizeCursor() {
        if hoveringHandle || grabbingHandle {
            (horizontal ? NSCursor.resizeLeftRight : NSCursor.resizeUpDown).set()
        } else {
            NSCursor.arrow.set()
        }
    }

    /// Zen rearrange: lift a fixed-identity mini-window; swap only on drop over mate.
    private func rearrangeDrag(for tab: Tab, side: SplitEdge) -> some Gesture {
        DragGesture(minimumDistance: 12, coordinateSpace: .named("split-stage"))
            .onChanged { value in
                if !browser.splitCarry.isRearranging {
                    browser.beginPaneRearrange(tab, from: side, at: value.location)
                } else {
                    browser.updateCarryPoint(value.location)
                }
            }
            .onEnded { _ in
                browser.finishCarry()
            }
    }
}

/// Legacy name — stage is always `StageCanvas` now (solo + split).
typealias SplitStage = StageCanvas

/// Joint strip for the two split tabs + unsplit control (mac-native, not Zen cards).
struct SplitJointStrip: View {
    @ObservedObject var browser: Browser
    let left: Tab
    let right: Tab
    let width: CGFloat
    let room: CGFloat
    let pill: Namespace.ID
    var vertical: Bool = false

    private var tint: SpaceTint {
        browser.prefs.usesSpaces ? browser.space.wash : SpaceTint(rgb: Spaces.colourRGB[0])
    }

    var body: some View {
        Group {
            if vertical {
                column
            } else {
                row
            }
        }
    }

    private var row: some View {
        HStack(spacing: 2) {
            member(left, trailing: false)
            member(right, trailing: true)
            Door(icon: "rectangle.split.1x2", help: "End Split") {
                withAnimation(Motion.settle) { browser.endSplit() }
            }
            .padding(.leading, 2)
        }
        .padding(3)
        .background {
            ZStack {
                Palette.wash.opacity(0.55)
                Spaces.splitHeaderWash(tint, focused: false)
            }
            .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
        }
        .animation(Motion.glide, value: browser.splitLeftID)
    }

    /// Sidebar joint: linked rail + paired rows — no bare "Split" label.
    private var column: some View {
        HStack(alignment: .center, spacing: 6) {
            Capsule()
                .fill(Spaces.splitAccent(tint, alpha: 0.55))
                .frame(width: 3, height: 52)
                .padding(.leading, 2)

            VStack(spacing: 2) {
                HStack(spacing: 4) {
                    Image(systemName: "rectangle.split.1x2")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Spaces.splitAccent(tint, alpha: 0.75))
                        .help("Split view")
                    Spacer(minLength: 0)
                    Door(icon: "xmark", help: "End Split") {
                        withAnimation(Motion.settle) { browser.endSplit() }
                    }
                }
                .padding(.horizontal, 2)
                memberRow(left, trailing: false)
                memberRow(right, trailing: true)
            }
        }
        .padding(.vertical, 4)
        .padding(.trailing, 4)
        .background {
            ZStack {
                Palette.wash.opacity(0.45)
                Spaces.splitHeaderWash(tint, focused: false)
            }
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Spaces.splitAccent(tint, alpha: 0.35), lineWidth: 1)
        )
    }

    @ViewBuilder
    private func member(_ tab: Tab, trailing: Bool) -> some View {
        SplitJointPill(browser: browser, tab: tab, width: min(width, 140), room: room, pill: pill, tint: tint)
            .gesture(jointSwapDrag(tab: tab, trailing: trailing, vertical: false))
    }

    private func memberRow(_ tab: Tab, trailing: Bool) -> some View {
        SplitJointSideRow(browser: browser, tab: tab, tint: tint)
            .gesture(jointSwapDrag(tab: tab, trailing: trailing, vertical: true))
    }

    /// Drop-only swap inside the joint — never live-reorders mid-hover (ownership fix).
    private func jointSwapDrag(tab: Tab, trailing: Bool, vertical: Bool) -> some Gesture {
        DragGesture(minimumDistance: 16, coordinateSpace: .local)
            .onEnded { value in
                let travel = vertical ? value.translation.height : value.translation.width
                let threshold: CGFloat = vertical ? 28 : min(width, 140) * Metrics.splitSwapCommit
                let shouldSwap: Bool = {
                    if trailing { return travel < -threshold }
                    return travel > threshold
                }()
                guard shouldSwap else { return }
                browser.reorderSplitGroup(from: tab.id, asTrailing: !trailing)
            }
    }
}

/// A strip pill used inside the joint group (shared TabMenu / select).
private struct SplitJointPill: View {
    @ObservedObject var browser: Browser
    @ObservedObject var tab: Tab
    let width: CGFloat
    let room: CGFloat
    let pill: Namespace.ID
    var tint: SpaceTint

    @State private var hovering = false

    private var focused: Bool { tab.id == browser.activeID }

    var body: some View {
        HStack(spacing: 6) {
            Mark(icon: browser.prefs.glyph == .icons ? tab.icon : nil, letter: tab.monogram, size: 13, dim: tab.asleep)
            Text(tab.label)
                .font(.system(size: 12, weight: focused ? .semibold : .regular))
                .foregroundStyle(Palette.ink)
                .lineLimit(1)
        }
        .padding(.horizontal, 8)
        .frame(width: width, height: 28)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(focused ? Palette.wash : (hovering ? Palette.hover : .clear))
            if focused {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Spaces.splitHeaderWash(tint, focused: true))
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .onTapGesture { browser.select(tab) }
        .onHover { hovering = $0 }
        .contextMenu { TabMenu(browser: browser, tab: tab, close: { browser.close(tab) }) }
        .animation(Motion.quick, value: hovering)
    }
}

private struct SplitJointSideRow: View {
    @ObservedObject var browser: Browser
    @ObservedObject var tab: Tab
    var tint: SpaceTint
    @State private var hovering = false

    private var focused: Bool { tab.id == browser.activeID }

    var body: some View {
        HStack(spacing: 8) {
            Mark(icon: browser.prefs.glyph == .icons ? tab.icon : nil, letter: tab.monogram, size: 14, dim: tab.asleep)
            Text(tab.label)
                .font(.system(size: 12.5, weight: focused ? .semibold : .regular))
                .foregroundStyle(Palette.ink)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .frame(height: 28)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(focused ? Palette.wash : (hovering ? Palette.hover : .clear))
            if focused {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Spaces.splitHeaderWash(tint, focused: true))
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { browser.select(tab) }
        .onHover { hovering = $0 }
        .contextMenu { TabMenu(browser: browser, tab: tab, close: { browser.close(tab) }) }
        .animation(Motion.quick, value: hovering)
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
