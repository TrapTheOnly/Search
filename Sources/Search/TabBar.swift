import SwiftUI

/// The only chrome there is. Titles, one of them in a grey pill, and the pill
/// slides from the tab you left to the tab you picked rather than blinking out
/// of one and into the other.
struct TabBar: View {
    @ObservedObject var browser: Browser

    @Namespace private var pill
    /// The neighbouring spaces' own grey, apart from this one's.
    @Namespace private var above
    @Namespace private var below

    /// Which tab is under the hand, where it started, and how far it has come.
    @State private var landing = false
    /// The plus only comes out when the pointer is in the row.
    @State private var nearby = false
    @State private var plussed = false
    /// How wide the doors at the far end are, extension buttons included.
    @State private var doors: CGFloat = 0

    var body: some View {
        // A GeometryReader is only here to measure the width. Its content is
        // put in a stack of its own and told to fill it: left to itself a
        // reader pins whatever it holds to the top corner, which is the row
        // riding at the very top of the strip while the traffic lights centre
        // themselves halfway down it.
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                // The empty half of the strip is what you grab to move the
                // window; the tabs keep the run they sit on.
                DragStrip(reserved: Metrics.lights + dot + (making ? min(540, room(in: geo.size.width)) : run(in: geo.size.width)) + Metrics.tabGap + Metrics.plusWidth, trailing: Metrics.helm + 26 + 24)
                // And the corner the lights sit in, which is title bar too —
                // the one stretch left to take hold of when tabs fill the row.
                DragStrip()
                    .frame(width: Metrics.lights)

                HStack(spacing: Metrics.tabGap) {
                    // Who you are, then the space on screen when there are spaces.
                    ProfileDot(browser: browser)
                    if browser.prefs.usesSpaces { SpaceDot(browser: browser) }

                    // Essentials stay put across space switches (profile-owned);
                    // only this space's pins and loose tabs ride the swipe.
                    // Putting essentials inside the swipe made them leave with
                    // the old row and reappear with the new one — a blink.
                    HStack(spacing: Metrics.tabGap) {
                        if !making, !browser.essentials.isEmpty {
                            essentialsStrip(in: geo.size.width, pill: pill)
                        }

                        // The spaces, one above the other: up or down over the bar
                        // and the next one's tabs come in as these go, with nothing
                        // between them (see SpaceSwipe). Past the last, a new one.
                        ZStack(alignment: .leading) {
                            if making {
                                NewSpaceCard(browser: browser, inline: true)
                                    .fixedSize()
                                    .offset(y: browser.spaceSwipe)
                            } else {
                                ScrollViewReader { reader in
                                    ScrollView(.horizontal, showsIndicators: false) {
                                        HStack(spacing: Metrics.tabGap) {
                                            ForEach(Array(browser.spaceShownPieces.enumerated()), id: \.element.id) { index, piece in
                                                spaceItem(piece, index: index, width: width(in: geo.size.width), room: geo.size.width - Metrics.lights - 12, pill: pill)
                                                    .id(piece.id)
                                            }
                                        }
                                        .frame(height: Metrics.strip)
                                    }
                                    .scrollDisabled(!overflowing(in: geo.size.width))
                                    .frame(width: spaceRun(in: geo.size.width))
                                    .onAppear { reveal(reader, in: geo.size.width) }
                                    .onChange(of: overflowing(in: geo.size.width)) { _, _ in reveal(reader, in: geo.size.width) }
                                    .onChange(of: browser.activeID) { _, _ in reveal(reader, in: geo.size.width, gliding: true) }
                                }
                                .offset(y: browser.spaceSwipe)
                            }
                            if browser.spaceSwipe > 0, spaceAt > 0 {
                                page(spaceAt - 1, in: geo.size.width, pill: above)
                                    .offset(y: browser.spaceSwipe - Metrics.strip)
                            }
                            if browser.spaceSwipe < 0, spaceAt < browser.spaces.count {
                                page(spaceAt + 1, in: geo.size.width, pill: below)
                                    .offset(y: browser.spaceSwipe + Metrics.strip)
                            }
                        }
                        .frame(width: making ? min(540, room(in: geo.size.width)) : spaceRun(in: geo.size.width), height: Metrics.strip, alignment: .leading)
                        // Only up and down: a neighbour's row may run wider than this one.
                        .mask(Rectangle().frame(width: 4000, height: Metrics.strip))
                    }
                    .frame(width: making ? min(540, room(in: geo.size.width)) : run(in: geo.size.width), height: Metrics.strip, alignment: .leading)
                    // The way to a new page, right after the tabs rather than
                    // at the end of their run, so it is there however far the
                    // run has scrolled. Out of sight until the pointer is up here.
                    Button { browser.newTab() } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(Palette.muted)
                            .frame(width: 15, height: 15)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 6)
                            .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                            .background(
                                RoundedRectangle(cornerRadius: 9, style: .continuous)
                                    .fill(plussed ? Palette.hover : .clear)
                            )
                    }
                    .buttonStyle(.plain)
                    .onHover { plussed = $0 }
                    .opacity(nearby ? 1 : 0)
                    .scaleEffect(nearby ? 1 : 0.7, anchor: .leading)
                    .allowsHitTesting(nearby)
                    .animation(Motion.settle, value: nearby)

                    Spacer(minLength: 0)

                    // Back, forward, reload, and the bookmarks, at the far end
                    // of the row. The dropdown hangs from the last one.
                    HStack(spacing: Metrics.tabGap) {
                        ExtensionSlot()
                        Helm(browser: browser)
                            .padding(.trailing, 8)
                        Door(icon: "bookmark", help: "Bookmarks") { browser.bookmarksOpen.toggle() }
                            .popover(isPresented: $browser.bookmarksOpen, arrowEdge: .bottom) {
                                BookmarksDropdown(browser: browser, bookmarks: browser.bookmarks)
                            }
                        if browser.downloadsChrome {
                            DownloadsDoor(browser: browser)
                        }
                    }
                    .background {
                        GeometryReader { box in
                            Color.clear
                                .onAppear { doors = box.size.width }
                                .onChange(of: box.size.width) { _, width in doors = width }
                        }
                    }
                }
                // The traffic lights are the system's. The row starts after
                // them and stays there — nothing here moves to get out of
                // their way, because nothing here was ever in it.
                .padding(.leading, Metrics.lights)
                .padding(.trailing, 12)
                .coordinateSpace(name: "strip")
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .frame(height: Metrics.strip)
        .onHover { nearby = $0 }
        .onAppear { SpaceSwipe.shared.start(for: browser) }
        // A link dragged onto the row opens there.
        .onDrop(of: [.url, .text], isTargeted: $landing) { providers in
            browser.take(providers)
        }
        .background {
            ZStack {
                ChromeFill(tint: browser.prefs.usesSpaces ? browser.space.wash : nil, clearWhenPlain: true)
                if landing { Palette.hover }
            }
        }
        .animation(Motion.quick, value: landing)
        .animation(Motion.quick, value: browser.space.wash)
        .animation(Motion.quick, value: browser.spaceID)
        .animation(Motion.glide, value: browser.activeID)
        // The row makes room for the field on the same spring as everything
        // else. Without this the widths changed between one frame and the next
        // and the tabs appeared to jump aside.
        .animation(Motion.glide, value: browser.editingTab)
        .animation(Motion.settle, value: browser.tabs.map(\.id))
        .animation(Motion.settle, value: browser.essentials.map(\.id))
        .animation(Motion.settle, value: browser.folders.map(\.collapsed))
        .animation(Motion.settle, value: browser.downloadsChrome)
    }

    // MARK: - the spaces, one above the other

    private var making: Bool { browser.prefs.usesSpaces && browser.makingSpace }

    /// Where the space on screen sits among them: one past the last while
    /// the row for a new one is up.
    private var spaceAt: Int {
        browser.makingSpace ? browser.spaces.count : (browser.spaces.firstIndex { $0.id == browser.spaceID } ?? 0)
    }

    /// Essentials alone — mounted outside the swipe so they never leave and
    /// reappear when the space row does.
    @ViewBuilder
    private func essentialsStrip(in strip: CGFloat, pill: Namespace.ID) -> some View {
        HStack(spacing: Metrics.tabGap) {
            ForEach(Array(browser.essentials.enumerated()), id: \.element.id) { index, tab in
                let step = Metrics.pinWidth + Metrics.tabGap
                TabPill(
                    browser: browser,
                    prefs: browser.prefs,
                    tab: tab,
                    live: tab.id == browser.activeID,
                    width: width(in: strip),
                    room: strip - Metrics.lights - 12,
                    pill: pill,
                    close: { browser.close(tab) }
                )
                .modifier(Carried(index: index, count: browser.essentials.count, step: step, vertical: false, space: "essentials") { target in
                    browser.movePin(tab, to: target)
                })
                .id(tab.id)
                .help(essentialsHelp)
            }
        }
        .frame(height: Metrics.strip)
    }

    /// Profile-wide essentials stay visible even in a signed-out space;
    /// cookies are space-local. True isolation is a Profile.
    private var essentialsHelp: String {
        if browser.space.sharesSignIns == false {
            return "Essential — stays in every space (profile-wide). This space has its own cookies; use a Profile to hide Essentials too."
        }
        return "Essential — stays in every space"
    }

    /// Another space's row, drawn with the same pills as this one's so the
    /// two read as one bar while they pass — nothing to press until it is
    /// the one on screen. Past the last, the row for a new space.
    /// Essentials are omitted here: they stay on the sticky strip above.
    @ViewBuilder
    private func page(_ index: Int, in strip: CGFloat, pill: Namespace.ID) -> some View {
        if index == browser.spaces.count {
            NewSpaceCard(browser: browser, inline: true)
                .fixedSize()
                .allowsHitTesting(false)
        } else {
            let space = browser.spaces[index]
            let row = space.id == browser.spaceID
                ? Parked(tabs: browser.tabs, active: browser.activeID, folders: browser.folders)
                : browser.parked[space.id] ?? Parked(tabs: [], active: nil)
            let shown = row.tabs
            let each = width(in: strip, pinned: shown.filter { $0.pin != nil }.count, count: shown.count)
            HStack(spacing: Metrics.tabGap) {
                ForEach(shown) { tab in
                    TabPill(
                        browser: browser,
                        prefs: browser.prefs,
                        tab: tab,
                        live: tab.id == row.active,
                        width: each,
                        room: strip - Metrics.lights - 12,
                        pill: pill,
                        close: {}
                    )
                }
            }
            .frame(height: Metrics.strip)
            .allowsHitTesting(false)
        }
    }

    /// One piece of this space's swipe row: pin, folder header, or loose tab.
    @ViewBuilder
    private func spaceItem(_ piece: StripPiece, index: Int, width: CGFloat, room: CGFloat, pill: Namespace.ID) -> some View {
        switch piece {
        case .essential:
            EmptyView()
        case .pin(let tab), .loose(let tab):
            let step = (tab.pin != nil ? Metrics.pinWidth : width) + Metrics.tabGap
            let tabIndex = browser.tabs.firstIndex(where: { $0.id == tab.id }) ?? index
            TabPill(
                browser: browser,
                prefs: browser.prefs,
                tab: tab,
                live: tab.id == browser.activeID,
                width: width,
                room: room,
                pill: pill,
                close: { browser.close(tab) }
            )
            .modifier(Carried(index: tabIndex, count: browser.tabs.count, step: step, vertical: false, space: "strip") { target in
                guard browser.tabs.indices.contains(target) else { return }
                let dest = browser.tabs[target]
                if tab.pin != nil || dest.pin != nil {
                    browser.movePin(tab, to: target + browser.essentials.count)
                } else if let folderID = dest.folderID,
                          let folder = browser.folders.first(where: { $0.id == folderID }) {
                    browser.place(tab, in: folder)
                } else {
                    browser.move(tab, to: target)
                }
            })
        case .folder(let folder, let members):
            FolderChip(browser: browser, folder: folder, members: members, width: min(140, max(72, width)))
        }
    }

    /// Brings the tab you are on into view once the run scrolls: at once
    /// when the window first shows it, on the strip's spring when you pick
    /// another. A turn of the run loop later, so the run has been laid out.
    private func reveal(_ reader: ScrollViewProxy, in strip: CGFloat, gliding: Bool = false) {
        guard overflowing(in: strip), let id = browser.activeID else { return }
        DispatchQueue.main.async {
            if gliding {
                withAnimation(Motion.glide) { reader.scrollTo(id) }
            } else {
                reader.scrollTo(id)
            }
        }
    }

    /// How wide the run of tabs is: as wide as the tabs while they fit, as
    /// wide as the room there is once they don't. Includes sticky essentials.
    private func run(in strip: CGFloat) -> CGFloat {
        min(content(in: strip), room(in: strip))
    }

    /// Width of the sticky essentials block alone (no trailing gap).
    private func essentialsWidth() -> CGFloat {
        let n = browser.essentials.count
        guard n > 0 else { return 0 }
        return CGFloat(n) * Metrics.pinWidth + CGFloat(max(0, n - 1)) * Metrics.tabGap
    }

    /// The swipeable part of the run — this space's pins and loose tabs —
    /// after sticky essentials have taken their share of `run`.
    private func spaceRun(in strip: CGFloat) -> CGFloat {
        let full = run(in: strip)
        let sticky = essentialsWidth()
        guard sticky > 0 else { return full }
        // Gap between essentials and the space row is outside both frames
        // (parent HStack spacing); subtract sticky only.
        return max(0, full - sticky - Metrics.tabGap)
    }

    private func overflowing(in strip: CGFloat) -> Bool {
        content(in: strip) > room(in: strip) + 0.5
    }

    /// Everything in the run at the width the tabs get — and the address
    /// field's width for a tab being edited, which grows to take it.
    private func content(in strip: CGFloat) -> CGFloat {
        let each = width(in: strip)
        let pinned = CGFloat(browser.pinnedCount)
        let hidden = collapsedCount
        let headers = CGFloat(browser.folders.count)
        let loose = CGFloat(browser.tabs.count - browser.spacePins - hidden)
        let count = Int(pinned + loose + headers)
        var total = pinned * Metrics.pinWidth + headers * min(140, max(72, each)) + loose * each
            + CGFloat(max(0, count - 1)) * Metrics.tabGap
        if let id = browser.editingTab, let tab = browser.strip.first(where: { $0.id == id }) {
            total += min(340, strip - Metrics.lights - 12) - (tab.pin != nil || tab.essential ? Metrics.pinWidth : each)
        }
        return total
    }

    private var collapsedCount: Int {
        browser.tabs.filter { tab in
            guard let id = tab.folderID, let folder = browser.folders.first(where: { $0.id == id }) else { return false }
            return folder.collapsed
        }.count
    }

    /// The strip, less the lights, the plus, the doors at the far end and
    /// the air around them. The doors are measured; until they have been,
    /// the three of the helm and the bookmarks stand in for them.
    private func room(in strip: CGFloat) -> CGFloat {
        let far = doors > 0 ? doors : Metrics.helm + 26
        return max(0, strip - Metrics.lights - dot - 12 - Metrics.plusWidth - far - 3 * Metrics.tabGap)
    }

    /// What the profile (and the space, when there are spaces) take before the tabs.
    private var dot: CGFloat {
        ProfileDot.width + Metrics.tabGap + (browser.prefs.usesSpaces ? SpaceDot.width + Metrics.tabGap : 0)
    }

    /// Every loose tab is the same width, so the cross is always in the same
    /// place. Past a dozen or so they start giving ground; too narrow for a
    /// title they show their mark alone (Metrics.tabTitled), down to the
    /// mark and its air. Past that, the run scrolls. The pinned squares take
    /// their room off the top.
    private func width(in strip: CGFloat) -> CGFloat {
        width(in: strip, pinned: browser.pinnedCount, count: browser.strip.count)
    }

    private func width(in strip: CGFloat, pinned pins: Int, count: Int) -> CGFloat {
        let pinned = CGFloat(pins)
        let loose = CGFloat(count) - pinned
        guard loose > 0 else { return Metrics.tabWidth }
        let spent = pinned * Metrics.pinWidth
            + CGFloat(max(0, count - 1)) * Metrics.tabGap
        return max(Metrics.tabMinWidth, min(Metrics.tabWidth, (room(in: strip) - spent) / loose))
    }
}

/// Back, forward, reload. They watch the live tab, not the window: whether
/// there is anywhere to go back to is the tab's to say, and it changes with
/// every page. Used here and, beside the traffic lights instead of at the
/// far end of the row, in the sidebar.
struct Helm: View {
    @ObservedObject var browser: Browser

    var body: some View {
        if let tab = browser.active {
            Wheel(browser: browser, tab: tab)
        } else {
            // Nowhere to go and nothing to reload: the doors stay in place,
            // greyed, so the row doesn't shift when a tab arrives.
            HStack(spacing: 2) {
                Door(icon: "chevron.left") {}
                Door(icon: "chevron.right") {}
                Door(icon: "arrow.clockwise") {}
            }
            .opacity(0.3)
            .allowsHitTesting(false)
        }
    }

    private struct Wheel: View {
        let browser: Browser
        @ObservedObject var tab: Tab

        var body: some View {
            let back = !tab.isBlank && tab.canGoBack
            let forward = !tab.isBlank && tab.canGoForward
            HStack(spacing: 2) {
                Door(icon: "chevron.left", help: "Back   ⌘[") { browser.back() }
                    .disabled(!back)
                    .opacity(back ? 1 : 0.3)
                Door(icon: "chevron.right", help: "Forward   ⌘]") { browser.forward() }
                    .disabled(!forward)
                    .opacity(forward ? 1 : 0.3)
                // Reload, or stop while it is still coming.
                Door(
                    icon: tab.loading ? "xmark" : "arrow.clockwise",
                    help: tab.loading ? "Stop   ⌘." : "Reload   ⌘R"
                ) {
                    if tab.loading { tab.stop() } else { browser.reload() }
                }
                .disabled(tab.isBlank)
                .opacity(tab.isBlank ? 0.3 : 1)
            }
            .animation(Motion.quick, value: back)
            .animation(Motion.quick, value: forward)
            .animation(Motion.quick, value: tab.loading)
        }
    }
}

private struct TabPill: View {
    @ObservedObject var browser: Browser
    @ObservedObject var prefs: Preferences
    @ObservedObject var tab: Tab
    let live: Bool
    let width: CGFloat
    /// How much of the strip there is, for the field that grows over it.
    let room: CGFloat
    let pill: Namespace.ID
    let close: () -> Void

    @State private var hovering = false
    @State private var shake: CGFloat = 0

    private var editing: Bool { browser.editingTab == tab.id }
    private var pinned: Bool { (tab.pin != nil || tab.essential) && !editing }
    /// Too narrow for a title: the site's mark alone, the title in the
    /// tooltip, and ⌘W or the menu to close it — a cross on something this
    /// small would be what a click to pick the tab lands on.
    private var compact: Bool { !editing && !pinned && width < Metrics.tabTitled }
    /// A speaker to press at the end of the pill: the page plays sound, or
    /// was muted. The ring, while the page is still coming, goes first.
    private var speaker: Bool { !editing && !tab.loading && (tab.noisy || tab.muted) }

    /// A pinned tab is a square, an edited one is a field, everything else is
    /// its share of what is left.
    private var span: CGFloat {
        if editing { return min(340, room) }
        return pinned ? Metrics.pinWidth : width
    }

    var body: some View {
        Group {
            if pinned {
                Group {
                    if browser.editingPin == tab.id {
                        PinField(browser: browser, tab: tab)
                    } else if prefs.glyph == .icons, let icon = tab.icon {
                        Mark(icon: icon, letter: tab.pin ?? "", size: 16, dim: tab.asleep)
                    } else {
                        Text(tab.pin ?? "")
                            .font(.system(size: 12, weight: .medium))
                            // A pin holding no page is still there and still
                            // yours; it just isn't costing anything.
                            .foregroundStyle(colour.opacity(tab.asleep ? 0.45 : 1))
                    }
                }
                .frame(width: 16, height: 16)
                .padding(.horizontal, 7)
                .padding(.vertical, 6)
                .frame(width: span)
            } else {
                loose
            }
        }
        .background { ground }
        .modifier(Shake(travel: shake))
        .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        // Never both at once.
        //
        // A view carrying a single tap *and* a double tap has to wait out the
        // system's double-click delay before it can conclude that a click was
        // single — and that delay is a preference, adjustable up to a second.
        // Which is exactly how long a tab took to come forward.
        //
        // So each tab carries one gesture. The pinned square you are already
        // on has nothing to do on a single click, so it takes the double one
        // and edits its letter; everything else answers the first click at
        // once. Change Letter in the menu covers the rest.
        .modifier(OneClick(double: live && pinned) {
            if live && pinned {
                browser.editLetter(tab)
            } else if live && !pinned {
                browser.beginTabEdit(tab)
            } else {
                browser.select(tab)
            }
        })
        .overlay { MiddleClick(act: close) }
        .onHover { hovering = $0 }
        .contextMenu { TabMenu(browser: browser, tab: tab, close: close) }
        .help(pinned || compact ? tab.label : "")
        .animation(Motion.quick, value: hovering)
        .animation(Motion.glide, value: editing)
        .animation(Motion.glide, value: tab.pin)
        .onChange(of: browser.refusals) { _, _ in
            guard editing else { return }
            shake = 0
            withAnimation(.easeOut(duration: 0.5)) { shake = 1 }
        }
        // Arriving and leaving from the strip rather than from nowhere.
        .transition(.scale(scale: 0.9, anchor: .leading).combined(with: .opacity))
    }

    @ViewBuilder
    private var loose: some View {
        if compact {
            ZStack {
                if tab.loading {
                    Ring()
                } else {
                    Mark(icon: prefs.glyph == .icons ? tab.icon : nil, letter: tab.monogram, size: 15, dim: tab.asleep)
                }
            }
            .frame(width: 16, height: 16)
            .padding(.vertical, 6)
            .frame(width: span)
        } else {
            titled
        }
    }

    private var titled: some View {
        HStack(spacing: 6) {
            if editing {
                TabAddressField(browser: browser)
                    .frame(height: 16)
            } else {
                if prefs.glyph == .icons, !tab.isBlank {
                    Mark(icon: tab.icon, letter: tab.monogram, size: 15)
                }
                if tab.bench {
                    // A script's tab, not yours.
                    Image(systemName: "flask")
                        .font(.system(size: 9))
                        .foregroundStyle(colour.opacity(0.7))
                }
                if tab.shy {
                    // Quiet, and only on the tabs that keep nothing.
                    Image(systemName: "eye.slash")
                        .font(.system(size: 9))
                        .foregroundStyle(colour.opacity(0.7))
                }
                Text(tab.label)
                    .font(.system(size: 12.5))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .foregroundStyle(colour)
            }

            Spacer(minLength: 2)

            // The speaker, which can be pressed, is at the end of the pill on
            // its own, and one place in under the pointer, beside the cross
            // and clear of its reach.
            HStack(spacing: 0) {
                if speaker {
                    Speaker(tab: tab)
                        .padding(.trailing, hovering ? 8 : 0)
                        .transition(.opacity)
                }

                // Pinned to the right-hand end of the pill, not trailing the title.
                // One slot doing two jobs: the cross when the pointer is here, the
                // ring while the page is still coming, never both.
                ZStack {
                    if hovering {
                        Image(systemName: "xmark")
                            .font(.system(size: 8, weight: .semibold))
                            .foregroundStyle(Palette.muted)
                            .frame(width: 15, height: 15)
                            .background(Palette.ink.opacity(0.07), in: Circle())
                            .transition(.opacity)
                    } else if tab.loading {
                        Ring().transition(.opacity)
                    }
                }
                .frame(width: editing || (speaker && !hovering) ? 0 : 15, height: 15)
                .opacity(editing ? 0 : 1)
                // The cross is 15 points across because that is how big it should
                // look. What you have to hit is the whole right-hand end of the
                // tab: an overlay is not laid out, so it can reach past its own
                // frame without moving anything that is.
                .overlay {
                    if !editing {
                        Color.clear
                            .frame(width: 30, height: 28)
                            .contentShape(Rectangle())
                            .onTapGesture { if hovering { close() } }
                    }
                }
                .animation(Motion.quick, value: hovering)
                .animation(Motion.quick, value: tab.loading)
            }
        }
        .padding(.leading, 11)
        .padding(.trailing, editing ? 11 : 7)
        .padding(.vertical, 6)
        .frame(width: span, alignment: .leading)
        .animation(Motion.quick, value: speaker)
    }

    @ViewBuilder
    private var ground: some View {
        if live {
            // The grey fills from the left as you read down the page. It is
            // the one thing in the window that says how far in you are, and
            // it says it without adding anything to the window.
            ZStack(alignment: .leading) {
                Rectangle().fill(Palette.wash)
                // Not on a pinned square, nor a tab down to its mark. Thirty
                // points of grey filling from the left behind a single letter
                // says nothing about anything — it needs the width of a title
                // to read as progress at all.
                if !pinned && !compact && prefs.showsReading {
                    Rectangle()
                        .fill(Palette.ink.opacity(0.055))
                        .frame(width: span * tab.reading)
                        .animation(.easeOut(duration: 0.15), value: tab.reading)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            .matchedGeometryEffect(id: pinned ? "live-pin" : "live-row", in: pill)
        } else if hovering {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Palette.hover)
        } else if pinned {
            // A letter with nothing behind it reads as debris. A pinned tab
            // keeps a faint ground of its own so the block of them reads as
            // one thing.
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Palette.wash.opacity(0.55))
        }
    }

    private var colour: Color {
        if live { return Palette.ink }
        return hovering ? Palette.ink.opacity(0.7) : Palette.muted
    }
}

/// The address, inside its own tab.
///
/// A field of its own rather than SwiftUI's, for one reason: the system paints
/// selected text as a solid block of accent colour, which over a pale grey pill
/// this size is the loudest thing in the window. Here it is a tenth of the ink.
/// A tab picked up and carried along its row, the others making way as it
/// passes them — across the top or down the column alike.
///
/// The hand's travel is the tab's own: every move of the pointer redraws the
/// one tab being carried, not the whole column or bar around it (with the
/// neighbouring spaces drawn beside it, that was every row and every square
/// of three spaces, each frame, and the tab trailed behind the hand). The row
/// only redraws when the tab actually changes place.
struct Carried: ViewModifier {
    let index: Int
    let count: Int
    /// One place in the row: the tab's length and the gap after it.
    let step: CGFloat
    let vertical: Bool
    /// The row's coordinate space, not the tab's: a tab that has just moved
    /// keeps its bearings (see the sidebar's grid).
    let space: String
    let move: (Int) -> Void

    @State private var held = false
    @State private var from = 0
    @State private var travel: CGFloat = 0

    func body(content: Content) -> some View {
        // What it has travelled, less the ground its new place has already
        // given it.
        let shift = held ? travel - CGFloat(index - from) * step : 0
        return content
            .offset(x: vertical ? 0 : shift, y: vertical ? shift : 0)
            // Under the hand exactly. Its place in the row springs when it
            // passes another tab, and the offset springs back the same way —
            // until the next move of the hand cuts the offset's spring short
            // and leaves the place's running: the tab jumped a whole slot and
            // drifted back each time it passed one. Only the others glide.
            .transaction { if held { $0.animation = nil } }
            .zIndex(held ? 1 : 0)
            .shadow(color: .black.opacity(held ? 0.14 : 0), radius: 12, y: 4)
            .gesture(
                DragGesture(minimumDistance: 5, coordinateSpace: .named(space))
                    .onChanged { value in
                        if !held {
                            held = true
                            from = index
                        }
                        travel = vertical ? value.translation.height : value.translation.width
                        let target = min(max(0, from + Int((travel / step).rounded())), count - 1)
                        if target != index {
                            withAnimation(Motion.settle) { move(target) }
                        }
                    }
                    .onEnded { _ in
                        withAnimation(Motion.settle) {
                            held = false
                            travel = 0
                        }
                    }
            )
    }
}

struct TabAddressField: NSViewRepresentable {
    @ObservedObject var browser: Browser

    func makeCoordinator() -> Coordinator { Coordinator(browser: browser) }

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField()
        field.delegate = context.coordinator
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 12.5)
        field.textColor = Palette.NS.ink
        field.cell?.usesSingleLineMode = true
        field.cell?.wraps = false
        field.stringValue = browser.tabDraft
        context.coordinator.watch(field)
        // The site card stands under whichever field the address is in.
        SiteCardPanel.follow(browser, anchor: field)
        return field
    }

    static func dismantleNSView(_ field: NSTextField, coordinator: Coordinator) {
        coordinator.unwatch()
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        let coordinator = context.coordinator
        coordinator.browser = browser
        if !coordinator.typing, field.stringValue != browser.tabDraft {
            field.stringValue = browser.tabDraft
        }
        guard !coordinator.claimed else { return }
        coordinator.claimed = true
        DispatchQueue.main.async {
            field.window?.makeFirstResponder(field)
            guard let editor = field.currentEditor() as? NSTextView else { return }
            editor.selectedTextAttributes = [
                .backgroundColor: NSColor(Palette.ink.opacity(0.11)),
                .foregroundColor: Palette.NS.ink,
            ]
            editor.selectAll(nil)
        }
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var browser: Browser
        var claimed = false
        var typing = false

        init(browser: Browser) { self.browser = browser }

        func controlTextDidChange(_ note: Notification) {
            guard let field = note.object as? NSTextField else { return }
            typing = true
            browser.tabDraft = field.stringValue
            typing = false
        }

        func control(
            _ control: NSControl,
            textView: NSTextView,
            doCommandBy command: Selector
        ) -> Bool {
            switch command {
            case #selector(NSResponder.insertNewline(_:)):
                // Returning true keeps the field editing, which is what lets a
                // refused address stay on screen instead of being thrown away.
                browser.commitTabEdit()
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                browser.cancelTabEdit()
                return true
            default:
                return false
            }
        }

        /// Clicking anywhere else keeps what was typed, as Return does.
        func controlTextDidEndEditing(_ note: Notification) {
            let browser = browser
            DispatchQueue.main.async { browser.finishTabEdit() }
        }

        /// A press on something that takes no focus — the strip's empty
        /// stretch, the column below the rows — leaves the field focused and
        /// editing, so presses are watched for while it is there: one anywhere
        /// but in the field ends the edit the same way. The press itself goes
        /// on to what it was for.
        private var watcher: Any?

        @MainActor func watch(_ field: NSTextField) {
            guard watcher == nil else { return }
            watcher = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self, weak field] event in
                guard let self, let field, event.window === field.window,
                      !field.bounds.contains(field.convert(event.locationInWindow, from: nil))
                else { return event }
                let browser = self.browser
                DispatchQueue.main.async { browser.finishTabEdit() }
                return event
            }
        }

        @MainActor func unwatch() {
            if let watcher { NSEvent.removeMonitor(watcher) }
            watcher = nil
        }
    }
}

/// What a right-click on any tab offers, wherever the tab is drawn.
struct TabMenu: View {
    @ObservedObject var browser: Browser
    @ObservedObject var tab: Tab
    let close: () -> Void

    var body: some View {
        if tab.pin == nil && !tab.essential {
            Button("Pin to this space") { browser.pin(tab) }
                .disabled(tab.isBlank)
        } else if tab.pin != nil {
            Button("Change Letter") { browser.editLetter(tab) }
            Button(tab.essential ? "Unpin" : "Unpin from this space") { browser.unpin(tab) }
        }
        if tab.essential {
            Button("Remove from Essentials") { browser.removeEssential(tab) }
        } else {
            Button("Make Essential (all spaces)") { browser.makeEssential(tab) }
                .disabled(tab.isBlank)
        }
        if tab.pin != nil || tab.essential {
            Button("Replace URL with Current Page") { browser.replacePinURL(tab) }
                .disabled(tab.isBlank || (tab.pending ?? tab.address) == nil)
            Button("Reset Pin") { browser.resetPin(tab) }
                .disabled(tab.pinURL == nil)
        }
        Button("Glance") { browser.glance(tab) }
            .disabled(tab.isBlank)
        Button(browser.splitID == nil ? "Split to the Side" : "End Split") {
            if browser.splitID == nil { browser.splitAside(tab) } else { browser.endSplit() }
        }
        .disabled(tab.isBlank && browser.splitID == nil)
        if browser.prefs.usesSpaces {
            Menu("Move to Space") {
                ForEach(browser.spaces) { space in
                    Button(space.name) { browser.move(tab, toSpace: space.id) }
                        .disabled(space.id == browser.spaceID || tab.essential)
                }
            }
        }
        if tab.pin == nil && !tab.essential {
            Button("New Folder") { browser.newFolder(around: tab) }
                .disabled(tab.isBlank)
            if !browser.folders.isEmpty {
                Menu("Add to Folder") {
                    ForEach(browser.folders) { folder in
                        Button(folder.name) { browser.place(tab, in: folder) }
                    }
                }
            }
            if tab.folderID != nil {
                Button("Remove from Folder") { browser.removeFromFolder(tab) }
            }
        }
        Divider()
        Button("Rename") { browser.beginTabRename(tab) }
        Button("Duplicate") {
            browser.select(tab)
            browser.duplicate()
        }
        .disabled(tab.isBlank)
        // The card a click on the tab you are on shows under its address.
        Button("Site Information…") {
            if browser.activeID != tab.id { browser.select(tab) }
            browser.beginTabEdit(tab)
        }
        .disabled(tab.isBlank || tab.address == nil || tab.pin != nil || tab.essential)
        Button("Copy Address") {
            browser.select(tab)
            browser.copyAddress()
        }
        .disabled(tab.isBlank)
        Button("Copy as Markdown Link") {
            browser.select(tab)
            browser.copyMarkdownLink()
        }
        .disabled(tab.isBlank)
        Button(tab.muted ? "Unmute Tab" : "Mute Tab") { tab.toggleMute() }
        Divider()
        Button("Close Tab", action: close)
        Button("Close Other Tabs") { browser.closeOthers(but: tab) }
            .disabled(browser.strip.count < 2)
        // ⌘⇧T, and the History menu's Recently Closed, where few think to
        // look for it: here too, where tabs are closed.
        Button("Reopen Closed Tab") { browser.reopen() }
            .disabled(browser.ghosts.isEmpty)
    }
}

/// One gesture or the other, never the two together.
struct OneClick: ViewModifier {
    let double: Bool
    let act: () -> Void

    func body(content: Content) -> some View {
        if double {
            content.onTapGesture(count: 2, perform: act)
        } else {
            content.onTapGesture(perform: act)
        }
    }
}

/// The middle button on a tab closes it, as it does in every other browser.
///
/// SwiftUI has no gesture for that button, so this is a real view laid over
/// the tab — and a real view is asked first (see DragStrip). It says yes for
/// the middle button and nothing else: to a left click, a drag or a right
/// click it isn't there, and the tab's own gestures and menu go on as before.
struct MiddleClick: NSViewRepresentable {
    let act: () -> Void

    func makeNSView(context: Context) -> NSView { Catch() }

    func updateNSView(_ view: NSView, context: Context) {
        (view as? Catch)?.act = act
    }

    private final class Catch: NSView {
        var act: () -> Void = {}
        private var pressed = false

        /// Asked about every event that lands on the tab, the pointer moving
        /// over it included; the one being delivered is the one to judge by.
        override func hitTest(_ point: NSPoint) -> NSView? {
            guard let event = NSApp.currentEvent,
                  event.type == .otherMouseDown || event.type == .otherMouseUp,
                  event.buttonNumber == 2
            else { return nil }
            return super.hitTest(point)
        }

        override func otherMouseDown(with event: NSEvent) {
            pressed = true
        }

        /// On the release, not the press, and only if it is still over the
        /// tab: a middle button pressed by mistake can be taken back the way
        /// a click on the cross can, by moving off before letting go.
        override func otherMouseUp(with event: NSEvent) {
            guard pressed else { return }
            pressed = false
            if bounds.contains(convert(event.locationInWindow, from: nil)) { act() }
        }
    }
}

/// An almost-closed ring, turning — the same one the canvas app uses, small
/// enough to sit inside a tab without becoming the loudest thing in it.
struct Ring: View {
    var size: CGFloat = 10
    @State private var angle: Double = 0

    var body: some View {
        Circle()
            .trim(from: 0, to: 0.78)
            .stroke(
                Palette.muted.opacity(0.7),
                style: StrokeStyle(lineWidth: 1.4, lineCap: .round)
            )
            .frame(width: size, height: size)
            .rotationEffect(.degrees(angle))
            .onAppear {
                withAnimation(.linear(duration: 0.85).repeatForever(autoreverses: false)) {
                    angle = 360
                }
            }
    }
}


/// The letter of a pinned tab, typed in the square itself.
///
/// A field of its own rather than SwiftUI's, for the same reason as the address
/// in a tab: the system paints selected text as a solid block of accent colour,
/// and over a thirty-point grey square that is the loudest thing on screen.
struct PinField: NSViewRepresentable {
    @ObservedObject var browser: Browser
    @ObservedObject var tab: Tab

    func makeCoordinator() -> Coordinator { Coordinator(browser: browser, tab: tab) }

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField()
        field.delegate = context.coordinator
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.alignment = .center
        field.font = .systemFont(ofSize: 12, weight: .medium)
        field.textColor = Palette.NS.ink
        field.cell?.usesSingleLineMode = true
        field.cell?.wraps = false
        field.stringValue = tab.pin ?? ""
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        let coordinator = context.coordinator
        coordinator.browser = browser
        coordinator.tab = tab
        if !coordinator.typing, field.stringValue != tab.pin ?? "" {
            field.stringValue = tab.pin ?? ""
        }
        guard !coordinator.claimed else { return }
        coordinator.claimed = true
        DispatchQueue.main.async {
            field.window?.makeFirstResponder(field)
            guard let editor = field.currentEditor() as? NSTextView else { return }
            editor.selectedTextAttributes = [
                .backgroundColor: NSColor(Palette.ink.opacity(0.12)),
                .foregroundColor: Palette.NS.ink,
            ]
            // The guessed letter arrives selected, so one keystroke replaces it
            // and doing nothing keeps it.
            editor.selectAll(nil)
        }
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var browser: Browser
        var tab: Tab
        var claimed = false
        var typing = false

        init(browser: Browser, tab: Tab) {
            self.browser = browser
            self.tab = tab
        }

        func controlTextDidChange(_ note: Notification) {
            guard let field = note.object as? NSTextField else { return }
            typing = true
            browser.letter(field.stringValue, for: tab)
            // One character only, and shown as it will be worn.
            field.stringValue = tab.pin ?? ""
            typing = false
        }

        func control(
            _ control: NSControl,
            textView: NSTextView,
            doCommandBy command: Selector
        ) -> Bool {
            switch command {
            case #selector(NSResponder.insertNewline(_:)),
                 #selector(NSResponder.cancelOperation(_:)),
                 #selector(NSResponder.insertTab(_:)):
                browser.endPinEdit()
                return true
            default:
                return false
            }
        }

        func controlTextDidEndEditing(_ note: Notification) {
            let browser = browser
            DispatchQueue.main.async { browser.endPinEdit() }
        }
    }
}
