import AppKit
import SwiftUI

/// The tabs, down the left instead of across the top.
///
/// Zen strip: Essentials as fill-width icon cells (all spaces, up to three
/// per row), Pinned as title rows (this space only), then loose tabs — with
/// a hairline under Essentials and under the pin block. The traffic lights
/// keep their corner; the column starts under them and the page takes the
/// whole height beside it.
struct SideBar: View {
    @ObservedObject var browser: Browser
    @ObservedObject var prefs: Preferences

    @Namespace private var pill

    @State private var landing = false
    /// The width the column had when the edge was picked up.
    @State private var grabbed: CGFloat?
    @State private var onEdge = false

    /// The neighbouring spaces' own grey, apart from this one's.
    @Namespace private var before
    @Namespace private var after
    /// Morph id shared by an essential square and a pin/loose row of the same
    /// tab while it crosses the essentials boundary.
    @Namespace private var morph

    /// A tab picked up in the sidebar — essentials grid, pin rows, or loose.
    @State private var pinDragging: Tab.ID?
    @State private var pinFrom = 0
    @State private var pinTravel: CGSize = .zero
    /// Where a cross-zone drag would land (insertion highlight).
    @State private var dropHint: DropHint?
    @State private var hapticZone: SideZone?

    private static let row: CGFloat = 28
    private static let gap: CGFloat = 2
    private static let square: CGFloat = 34
    private static let pinGap: CGFloat = 4

    private enum SideZone: Equatable {
        case essentials, pinned, loose
    }

    private struct DropHint: Equatable {
        var zone: SideZone
        var index: Int
    }

    var body: some View {
        ZStack(alignment: .top) {
            // Not under the card for a new space: it isn't made of views that
            // would take the click first.
            DragStrip(reserved: 0, below: browser.makingSpace ? .greatestFiniteMagnitude : rowsEnd)

            // The band the lights sit in is this mode's title bar: the window
            // is dragged by it and a double-click fills the screen with it,
            // everywhere but over the three doors, which take their own
            // clicks. The lights are the title bar's own and answer first.
            HStack(spacing: 0) {
                DragStrip()
                    .frame(width: 10 + Metrics.sideLights)
                Color.clear
                    .frame(width: Metrics.helm)
                    .allowsHitTesting(false)
                DragStrip()
            }
            .frame(height: Metrics.strip)

            VStack(alignment: .leading, spacing: 0) {
                // The traffic lights' corner, with back, forward and reload
                // sitting right of them — the same three doors as the top
                // bar, moved beside the lights since there's no far end of a
                // row to put them at in this mode.
                HStack(spacing: 0) {
                    Color.clear.frame(width: Metrics.sideLights)
                    Helm(browser: browser)
                    Spacer(minLength: 0)
                }
                .frame(height: Metrics.strip)

                // Essentials stay put across space switches (profile-wide);
                // only this space's pins and loose tabs ride the swipe.
                // Putting them inside the page made a pin square share
                // matched-geometry with a loose row across the swap, and left
                // ghost favicons / empty pin slots after coming back.
                if !browser.essentials.isEmpty {
                    essentialsBlock
                        .padding(.bottom, 8)
                }

                // The spaces side by side, as pages: two fingers sideways move
                // the one on screen and the next one together, the next one
                // coming in as this one goes, with nothing between them.
                pages

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            // Clear of the foot, which sits over the column's bottom edge.
            .padding(.bottom, SideBar.footHeight)
            .onChange(of: browser.spaceID) { _, _ in
                pinDragging = nil
                pinTravel = .zero
                dropHint = nil
                hapticZone = nil
            }

            VStack {
                Spacer()
                foot
            }
        }
        .frame(width: prefs.sideWidth)
        .frame(maxHeight: .infinity)
        // Rows on their way to or from another space stay in the column.
        .clipped()
        .onAppear { SpaceSwipe.shared.start(for: browser) }
        .background {
            ZStack {
                ChromeFill(tint: browser.prefs.usesSpaces ? browser.space.wash : nil)
                if landing { Palette.hover }
            }
        }
        .overlay(alignment: .trailing) {
            Rectangle().fill(Palette.hairline).frame(width: 1)
        }
        .overlay(alignment: .trailing) { edge }
        .onDrop(of: [.url, .text], isTargeted: $landing) { providers in
            browser.take(providers)
        }
        .animation(Motion.quick, value: landing)
        .animation(Motion.quick, value: browser.space.wash)
        .animation(Motion.quick, value: browser.spaceID)
        .animation(Motion.glide, value: browser.activeID)
        .animation(Motion.glide, value: browser.editingTab)
        .animation(Motion.settle, value: browser.tabs.map(\.id))
        .animation(Motion.settle, value: browser.essentials.map(\.id))
        .animation(Motion.settle, value: browser.folders.map(\.collapsed))
        .animation(Motion.settle, value: browser.pinnedCount)
        .animation(Motion.settle, value: browser.downloadsChrome)
    }

    /// The column's edge: pull it to make the column wider or narrower,
    /// double-click it to put it back. The hairline darkens under the pointer
    /// so the edge says it can be taken before it is.
    private var edge: some View {
        Rectangle()
            .fill(Palette.ink.opacity(onEdge || grabbed != nil ? 0.18 : 0))
            .frame(width: onEdge || grabbed != nil ? 2 : 1)
            .frame(width: 9)
            .contentShape(Rectangle())
            .onHover { over in
                onEdge = over
                if over { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { value in
                        if grabbed == nil { grabbed = prefs.sideWidth }
                        let wanted = (grabbed ?? prefs.sideWidth) + value.translation.width
                        prefs.sideWidth = min(Metrics.sideMax, max(Metrics.sideMin, wanted))
                    }
                    .onEnded { _ in grabbed = nil }
            )
            .modifier(OneClick(double: true) {
                withAnimation(Motion.settle) { prefs.sideWidth = Metrics.side }
            })
            .animation(Motion.quick, value: onEdge)
    }

    // MARK: - the spaces, as pages

    /// Where the space on screen sits among them: one past the last while
    /// the card for a new one is up.
    private var spaceAt: Int {
        browser.makingSpace ? browser.spaces.count : (browser.spaces.firstIndex { $0.id == browser.spaceID } ?? 0)
    }

    private var pages: some View {
        let width = prefs.sideWidth
        let swipe = browser.spaceSwipe
        let at = spaceAt
        return ZStack(alignment: .topLeading) {
            page(at, pill: pill)
                .offset(x: swipe)
            // Only while the fingers are bringing one in: the one they are
            // bringing, a page's width away.
            if swipe > 0, at > 0 {
                page(at - 1, pill: before)
                    .offset(x: swipe - width)
            }
            if swipe < 0, at < browser.spaces.count {
                page(at + 1, pill: after)
                    .offset(x: swipe + width)
            }
        }
        // The pages are the column's whole width, each with its own margin.
        .padding(.horizontal, -10)
        .frame(maxHeight: .infinity, alignment: .top)
    }

    /// One space's page: the rows on screen, another space's rows as they
    /// were left, or past the last the card for a new one.
    @ViewBuilder
    private func page(_ index: Int, pill: Namespace.ID) -> some View {
        Group {
            if index == browser.spaces.count {
                VStack(spacing: 0) {
                    Spacer(minLength: 0)
                    NewSpaceCard(browser: browser)
                    Spacer(minLength: 0)
                    Spacer(minLength: 0)
                }
                .frame(maxHeight: .infinity)
            } else if browser.spaces[index].id == browser.spaceID {
                VStack(alignment: .leading, spacing: 0) {
                    // Space pins only — essentials sit above the swipe.
                    if browser.spacePins > 0 {
                        pinned
                            .padding(.bottom, 8)
                            .id(browser.spaceID)
                    }
                    // A row too long for the window scrolls between the pins
                    // and the foot, rather than running under the lights at one
                    // end and the foot at the other. While it fits it stays a
                    // plain stack, and the space under it is still the
                    // window's to be dragged by. Inside the page: the swipe
                    // between spaces moves the page, scroll and all.
                    ViewThatFits(in: .vertical) {
                        rows
                        ScrollViewReader { proxy in
                            // The scroll view reaches into the margin on
                            // the right and the rows keep it inside, so the
                            // system's bar lands in the margin beside them
                            // rather than over the cross on the tab under the
                            // pointer. The column's edge lies over that margin
                            // and answers first, so the bar never fights the
                            // resize; the wheel and the trackpad still scroll.
                            ScrollView(.vertical) {
                                rows.padding(.trailing, 10)
                            }
                            .padding(.trailing, -10)
                            // The tab you go to is the tab you see — ⌘1–⌘9,
                            // ⇧⌘], a link opening beside the one on screen.
                            .onChange(of: browser.activeID) { _, id in
                                guard let id else { return }
                                withAnimation(Motion.glide) { proxy.scrollTo(id) }
                            }
                            .onAppear {
                                if let id = browser.activeID { proxy.scrollTo(id, anchor: .center) }
                            }
                        }
                    }
                }
            } else {
                preview(browser.parked[browser.spaces[index].id] ?? Parked(tabs: [], active: nil), pill: pill)
            }
        }
        .padding(.horizontal, 10)
        .frame(width: prefs.sideWidth, alignment: .topLeading)
    }

    /// Another space's rows, drawn with the same pieces as this one's so the
    /// two read as one column while they pass — and nothing to press until
    /// it is the one on screen. Essentials are omitted: they stay on the
    /// sticky strip above the swipe.
    private func preview(_ row: Parked, pill: Namespace.ID) -> some View {
        let pins = row.tabs.filter { $0.pin != nil && !$0.essential }
        let rest = row.tabs.filter { $0.pin == nil && !$0.essential }
        return VStack(alignment: .leading, spacing: 0) {
            if !pins.isEmpty {
                VStack(spacing: SideBar.gap) {
                    ForEach(pins) { tab in
                        SideRow(
                            browser: browser,
                            prefs: prefs,
                            tab: tab,
                            live: tab.id == row.active,
                            pill: pill,
                            close: {},
                            geometry: "live-pin-row"
                        )
                    }
                }
                .padding(.bottom, 8)
                Rectangle()
                    .fill(Palette.hairline)
                    .frame(height: 1)
                    .padding(.horizontal, 4)
                    .padding(.bottom, 8)
            }
            VStack(spacing: SideBar.gap) {
                ForEach(rest) { tab in
                    SideRow(browser: browser, prefs: prefs, tab: tab, live: tab.id == row.active, pill: pill, close: {})
                }
            }
            newTab
        }
        .allowsHitTesting(false)
    }

    /// Where the rows stop and the window's own drag area starts. Added up
    /// from what was drawn rather than measured: a measurement would arrive a
    /// frame late, and for one frame the whole column would drag the window.
    private var rowsEnd: CGFloat {
        let essentials = browser.essentials.count
        let spacePins = browser.spacePins
        // Essentials: labelled square grid. Pins: labelled rows + separator.
        let essentialBlock = essentialsGridHeight(count: essentials, bottomPad: 10)
        let spacePinBlock: CGFloat = {
            guard spacePins > 0 else { return 0 }
            let label: CGFloat = browser.essentials.isEmpty ? 0 : 18
            let rows = CGFloat(spacePins) * (SideBar.row + SideBar.gap)
            return label + rows + 8 + 1 + 8 // rows + separator + pad
        }()
        let loose = CGFloat(visibleLooseCount + browser.folders.count) * (SideBar.row + SideBar.gap)
        return Metrics.strip + essentialBlock + spacePinBlock + loose + SideBar.row + 8
    }

    private func essentialsGridHeight(count: Int, bottomPad: CGFloat) -> CGFloat {
        guard count > 0 else { return 0 }
        let cols = SideBar.pinColumns(count)
        let rows = (count + cols - 1) / cols
        let cell = pinWidth(for: count)
        let height = min(SideBar.square, cell)
        let label: CGFloat = 18
        return label + CGFloat(rows) * height + CGFloat(max(0, rows - 1)) * SideBar.pinGap + bottomPad
    }

    private var visibleLooseCount: Int {
        looseTabs.filter { tab in
            guard let id = tab.folderID, let folder = browser.folders.first(where: { $0.id == id }) else { return true }
            return !folder.collapsed
        }.count
    }

    // MARK: - essentials squares + pinned rows

    /// This space's pins only. Essentials have their own strip above the swipe.
    private var pinnedTabs: [Tab] { browser.tabs.filter { $0.pin != nil && !$0.essential } }
    private var looseTabs: [Tab] { browser.tabs.filter { $0.pin == nil && !$0.essential } }

    /// Essentials fill the row, Zen-style: up to three equal cells.
    /// 1 → full width; 2 → half/half; 3 → thirds; past three wrap another row.
    /// Never reserve empty columns (that left the sparse single-icon dead space).
    private static func pinColumns(_ count: Int) -> Int {
        min(3, max(1, count))
    }

    /// However many columns the count calls for, they split the row's own
    /// width between them — the row is what fills edge to edge, not each
    /// cell on its own, so this grows past 34 just as readily as it shrinks
    /// below it.
    private var pinWidth: CGFloat { pinWidth(for: browser.essentials.count) }

    private func pinWidth(for count: Int) -> CGFloat {
        let cols = SideBar.pinColumns(count)
        guard cols > 0 else { return SideBar.square }
        let available = prefs.sideWidth - 20 - CGFloat(cols - 1) * SideBar.pinGap
        return max(20, available / CGFloat(cols))
    }

    /// Height stays the classic square; width is what fills. Only shrinks
    /// below 34 when a narrow sidebar leaves no other choice.
    private var pinHeight: CGFloat {
        min(SideBar.square, pinWidth)
    }

    /// Profile-wide essentials: labelled icon cells that fill the row (up to
    /// three), always on, above this space's pin rows. Hairline under the
    /// block (Zen chrome). Width spring-animates when the count changes.
    private var essentialsBlock: some View {
        let tabs = browser.essentials
        let cols = SideBar.pinColumns(tabs.count)
        let width = pinWidth(for: tabs.count)
        let height = min(SideBar.square, width)
        return VStack(alignment: .leading, spacing: 4) {
            Text("Essentials")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Palette.muted)
                .padding(.leading, 2)
            ZStack(alignment: .topLeading) {
                PinGrid(columns: cols, width: width, height: height, spacing: SideBar.pinGap) {
                    ForEach(Array(tabs.enumerated()), id: \.element.id) { index, tab in
                        let held = pinDragging == tab.id
                        PinSquare(
                            browser: browser,
                            prefs: prefs,
                            tab: tab,
                            live: tab.id == browser.activeID,
                            pill: pill,
                            morph: morph,
                            width: width,
                            height: height
                        )
                        .offset(pinOffset(held: held, index: index, columns: cols, width: width, height: height))
                        .transaction { if held { $0.animation = nil } }
                        .animation(held ? nil : Motion.settle, value: dropHint?.index)
                        .zIndex(held ? 1 : 0)
                        .shadow(color: .black.opacity(held ? 0.16 : 0), radius: 10, y: 3)
                        .gesture(essentialDrag(
                            tab: tab,
                            index: index,
                            columns: cols,
                            width: width,
                            height: height,
                            count: tabs.count
                        ))
                        .help(essentialsHelp)
                    }
                }
                if let hint = dropHint, hint.zone == .essentials {
                    insertMark(at: hint.index, in: .essentials, columns: cols, width: width, height: height)
                }
            }
            .coordinateSpace(name: "essentials")
            .animation(Motion.settle, value: width)
            .animation(Motion.settle, value: cols)
            Rectangle()
                .fill(Palette.hairline)
                .frame(height: 1)
                .padding(.horizontal, 4)
                .padding(.top, 6)
        }
    }

    private var essentialsHelp: String {
        if browser.space.sharesSignIns == false {
            return "Essential — stays in every space (profile-wide). This space has its own cookies; use a Profile to hide Essentials too."
        }
        return "Essential — stays in every space"
    }

    /// This space's pins as Zen-style title rows (not an icon grid). A hairline
    /// under the block separates pins from loose tabs — the #14 overlay bug
    /// does not apply: pins no longer share PinSquare geometry with anything.
    private var pinned: some View {
        let tabs = pinnedTabs
        let step = SideBar.row + SideBar.gap
        return VStack(alignment: .leading, spacing: 4) {
            Text("Pinned")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Palette.muted)
                .padding(.leading, 2)
            ZStack(alignment: .topLeading) {
                VStack(spacing: SideBar.gap) {
                    ForEach(Array(tabs.enumerated()), id: \.element.id) { index, tab in
                        if browser.isSplitMember(tab) {
                            EmptyView()
                        } else {
                        let held = pinDragging == tab.id
                        SideRow(
                            browser: browser,
                            prefs: prefs,
                            tab: tab,
                            live: tab.id == browser.activeID,
                            pill: pill,
                            close: { browser.close(tab) },
                            geometry: "live-pin-row",
                            morph: morph
                        )
                        .offset(y: rowPart(held: held, index: index, step: step, zone: .pinned))
                        .transaction { if held { $0.animation = nil } }
                        .animation(held ? nil : Motion.settle, value: dropHint?.index)
                        .zIndex(held ? 1 : 0)
                        .shadow(color: .black.opacity(held ? 0.14 : 0), radius: 12, y: 4)
                        .gesture(pinnedRowDrag(tab: tab, index: index, step: step, count: tabs.count))
                        .help("Pinned to this space")
                        }
                    }
                }
                if let hint = dropHint, hint.zone == .pinned {
                    insertMark(at: hint.index, in: .pinned, columns: 1, width: 0, height: step)
                }
            }
            .coordinateSpace(name: "pins")
            Rectangle()
                .fill(Palette.hairline)
                .frame(height: 1)
                .padding(.horizontal, 4)
                .padding(.top, 6)
        }
    }

    /// Thin bar where a dragged tab will insert.
    @ViewBuilder
    private func insertMark(
        at index: Int,
        in zone: SideZone,
        columns: Int,
        width: CGFloat,
        height: CGFloat
    ) -> some View {
        let bar = RoundedRectangle(cornerRadius: 1, style: .continuous)
            .fill(Palette.ink.opacity(0.45))
            .frame(height: 2)
        switch zone {
        case .essentials:
            let col = index % max(columns, 1)
            let row = index / max(columns, 1)
            bar
                .frame(width: max(12, width * 0.7))
                .offset(
                    x: CGFloat(col) * (width + SideBar.pinGap) + width * 0.15,
                    y: CGFloat(row) * (height + SideBar.pinGap) - 1
                )
                .allowsHitTesting(false)
        case .pinned, .loose:
            bar
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 6)
                .offset(y: CGFloat(index) * height - 1)
                .allowsHitTesting(false)
        }
    }

    private func bumpHaptic(_ zone: SideZone?) {
        guard zone != hapticZone else { return }
        let first = hapticZone == nil && zone != nil
        let crossed = hapticZone != nil && zone != nil && zone != hapticZone
        hapticZone = zone
        guard first || crossed else { return }
        NSHapticFeedbackManager.defaultPerformer.perform(
            crossed ? .levelChange : .alignment, performanceTime: .now
        )
    }

    /// The one square actually held stays glued to the fingers; siblings part
    /// along the live preview path. Model order commits only on drop.
    private func pinOffset(held: Bool, index: Int, columns: Int, width: CGFloat, height: CGFloat) -> CGSize {
        let stepX = width + SideBar.pinGap
        let stepY = height + SideBar.pinGap
        if held { return pinTravel }
        guard pinDragging != nil,
              let hint = dropHint, hint.zone == .essentials,
              hint.index != pinFrom
        else { return .zero }
        let units = TabReorderSlot.parted(index: index, from: pinFrom, to: hint.index)
        guard units != 0 else { return .zero }
        // Part along the grid path by shifting one slot toward the vacancy.
        let fromPos = (row: index / columns, col: index % columns)
        let shifted = index + Int(units)
        let toPos = (row: shifted / columns, col: shifted % columns)
        return CGSize(
            width: CGFloat(toPos.col - fromPos.col) * stepX,
            height: CGFloat(toPos.row - fromPos.row) * stepY
        )
    }

    private func pinDelta(columns: Int, stepX: CGFloat, stepY: CGFloat) -> Int {
        let col = Int((pinTravel.width / stepX).rounded())
        let row = Int((pinTravel.height / stepY).rounded())
        return row * columns + col
    }

    private func pinTarget(from: Int, moved: Int, count: Int) -> Int {
        min(max(0, from + moved), max(0, count - 1))
    }

    /// Vertical row parting while a pin/loose drag is previewed (model still at `pinFrom`).
    private func rowPart(held: Bool, index: Int, step: CGFloat, zone: SideZone) -> CGFloat {
        if held { return pinTravel.height }
        guard pinDragging != nil,
              let hint = dropHint, hint.zone == zone,
              hint.index != pinFrom
        else { return 0 }
        return TabReorderSlot.parted(index: index, from: pinFrom, to: hint.index) * step
    }

    /// Essentials grid: reorder among squares; drag past the bottom edge to
    /// demote into Pinned (row) or further into loose.
    private func essentialDrag(
        tab: Tab,
        index: Int,
        columns: Int,
        width: CGFloat,
        height: CGFloat,
        count: Int
    ) -> some Gesture {
        let blockH = {
            let rows = (count + columns - 1) / columns
            return CGFloat(rows) * height + CGFloat(max(0, rows - 1)) * SideBar.pinGap
        }()
        return DragGesture(minimumDistance: 5, coordinateSpace: .named("essentials"))
            .onChanged { value in
                if pinDragging != tab.id {
                    pinDragging = tab.id
                    pinFrom = index
                    bumpHaptic(.essentials)
                }
                pinTravel = value.translation
                let stepX = width + SideBar.pinGap
                let stepY = height + SideBar.pinGap
                // Past the bottom of the essentials block → leave essentials.
                if value.location.y > blockH + 12 {
                    let intoPins = value.location.y < blockH + 12 + CGFloat(max(1, browser.spacePins)) * (SideBar.row + SideBar.gap) + 40
                    if intoPins || browser.spacePins > 0 {
                        let idx = max(0, Int(((value.location.y - blockH - 12) / (SideBar.row + SideBar.gap)).rounded()))
                        dropHint = DropHint(zone: .pinned, index: min(idx, browser.spacePins))
                        bumpHaptic(.pinned)
                    } else {
                        dropHint = DropHint(zone: .loose, index: 0)
                        bumpHaptic(.loose)
                    }
                    return
                }
                let ideal = pinTarget(
                    from: pinFrom,
                    moved: pinDelta(columns: columns, stepX: stepX, stepY: stepY),
                    count: count
                )
                dropHint = DropHint(zone: .essentials, index: ideal)
                bumpHaptic(.essentials)
            }
            .onEnded { _ in
                let hint = dropHint
                withAnimation(Motion.settle) {
                    if let hint, hint.zone == .pinned {
                        browser.removeEssential(tab)
                        // removeEssential attaches as pin at 0; move to hint.
                        browser.move(tab, to: min(hint.index, max(0, browser.spacePins - 1)))
                    } else if let hint, hint.zone == .loose {
                        browser.unpin(tab)
                    } else if let hint, hint.zone == .essentials, hint.index != pinFrom {
                        browser.movePin(tab, to: hint.index)
                    }
                    pinDragging = nil
                    pinTravel = .zero
                    dropHint = nil
                    hapticZone = nil
                }
            }
    }

    /// Pin rows: reorder vertically; drag up into Essentials to morph into a
    /// square; drag down past the separator to unpin into loose.
    private func pinnedRowDrag(tab: Tab, index: Int, step: CGFloat, count: Int) -> some Gesture {
        DragGesture(minimumDistance: 5, coordinateSpace: .named("pins"))
            .onChanged { value in
                if pinDragging != tab.id {
                    pinDragging = tab.id
                    pinFrom = index
                    bumpHaptic(.pinned)
                }
                pinTravel = CGSize(width: 0, height: value.translation.height)
                // Up past the top → essentials.
                if value.location.y < -10 {
                    let idx = min(browser.essentials.count, max(0, Int((value.location.x / 40).rounded())))
                    dropHint = DropHint(zone: .essentials, index: idx)
                    bumpHaptic(.essentials)
                    return
                }
                // Below the pin block → loose.
                if value.location.y > CGFloat(count) * step + 8 {
                    dropHint = DropHint(zone: .loose, index: 0)
                    bumpHaptic(.loose)
                    return
                }
                let current = dropHint?.zone == .pinned ? (dropHint?.index ?? pinFrom) : pinFrom
                let target = TabReorderSlot.index(
                    travel: value.translation.height,
                    from: pinFrom,
                    current: current,
                    count: count,
                    step: step
                )
                dropHint = DropHint(zone: .pinned, index: target)
                bumpHaptic(.pinned)
            }
            .onEnded { _ in
                let hint = dropHint
                withAnimation(Motion.settle) {
                    if let hint, hint.zone == .essentials {
                        browser.makeEssential(tab)
                        browser.movePin(tab, to: hint.index)
                    } else if let hint, hint.zone == .loose {
                        browser.unpin(tab)
                    } else if let hint, hint.zone == .pinned, hint.index != pinFrom {
                        browser.move(tab, to: hint.index)
                    }
                    pinDragging = nil
                    pinTravel = .zero
                    dropHint = nil
                    hapticZone = nil
                }
            }
    }

    // MARK: - the rows

    /// Loose rows: reorder among themselves; drag above the list into Pinned
    /// or Essentials (morph to square).
    private func looseDrag(tab: Tab, index: Int, step: CGFloat, count: Int) -> some Gesture {
        DragGesture(minimumDistance: 5, coordinateSpace: .named("rows"))
            .onChanged { value in
                if pinDragging != tab.id {
                    pinDragging = tab.id
                    pinFrom = index
                    browser.beginCarry(tab.id)
                    bumpHaptic(.loose)
                }
                pinTravel = CGSize(width: 0, height: value.translation.height)
                // Drag out of the column → lift mini-window for edge split.
                if abs(value.translation.width) > Metrics.splitLift,
                   abs(value.translation.width) > abs(value.translation.height) {
                    dropHint = nil
                    browser.liftCarry(at: browser.splitCarry.point == .zero
                        ? CGPoint(x: Metrics.splitEdge + 8, y: 120)
                        : browser.splitCarry.point)
                    return
                }
                if browser.splitCarry.lifted { return }
                // Above the loose list → pinned, or further → essentials.
                if value.location.y < -8 {
                    if value.location.y < -8 - CGFloat(max(1, browser.spacePins)) * step - 20 {
                        dropHint = DropHint(zone: .essentials, index: browser.essentials.count)
                        bumpHaptic(.essentials)
                    } else {
                        let idx = max(0, browser.spacePins + Int((value.location.y / step).rounded()))
                        dropHint = DropHint(zone: .pinned, index: min(max(0, idx), browser.spacePins))
                        bumpHaptic(.pinned)
                    }
                    return
                }
                let current = dropHint?.zone == .loose ? (dropHint?.index ?? pinFrom) : pinFrom
                let target = TabReorderSlot.index(
                    travel: value.translation.height,
                    from: pinFrom,
                    current: current,
                    count: count,
                    step: step
                )
                dropHint = DropHint(zone: .loose, index: target)
                bumpHaptic(.loose)
            }
            .onEnded { _ in
                let hint = dropHint
                let didLift = browser.splitCarry.lifted
                withAnimation(Motion.settle) {
                    if !didLift {
                        if let hint, hint.zone == .essentials {
                            browser.makeEssential(tab)
                            browser.movePin(tab, to: hint.index)
                        } else if let hint, hint.zone == .pinned {
                            browser.pin(tab)
                            browser.move(tab, to: min(hint.index, max(0, browser.spacePins - 1)))
                        } else if let hint, hint.zone == .loose, hint.index != pinFrom,
                                  loosePieces.indices.contains(hint.index) {
                            if case .folder(let folder, _) = loosePieces[hint.index] {
                                browser.place(tab, in: folder)
                            } else if let dest = loosePieces[hint.index].tab,
                                      let at = browser.tabs.firstIndex(where: { $0.id == dest.id }) {
                                browser.move(tab, to: at)
                            }
                        }
                    }
                    pinDragging = nil
                    pinTravel = .zero
                    dropHint = nil
                    hapticZone = nil
                }
                browser.finishCarry()
            }
    }

    private var loose: some View {
        ZStack(alignment: .topLeading) {
        VStack(spacing: SideBar.gap) {
            if let panes = browser.splitPanes {
                SplitJointStrip(
                    browser: browser,
                    left: panes.left,
                    right: panes.right,
                    width: 160,
                    room: prefs.sideWidth,
                    pill: pill,
                    vertical: true
                )
                .padding(.bottom, 4)
            }
            ForEach(Array(loosePieces.enumerated()), id: \.element.id) { index, piece in
                switch piece {
                case .folder(let folder, let members):
                    FolderRow(browser: browser, folder: folder, members: members) {
                        if let tab = browser.strip.first(where: { $0.id == browser.activeID }),
                           tab.pin == nil, !tab.essential {
                            browser.place(tab, in: folder)
                        }
                    }
                case .loose(let tab), .pin(let tab):
                    if browser.isSplitMember(tab) {
                        EmptyView()
                    } else {
                        let step = SideBar.row + SideBar.gap
                        let held = pinDragging == tab.id
                        SideRow(
                            browser: browser,
                            prefs: prefs,
                            tab: tab,
                            live: tab.id == browser.activeID,
                            pill: pill,
                            close: { browser.close(tab) },
                            morph: morph
                        )
                        .offset(y: rowPart(held: held, index: index, step: step, zone: .loose))
                        .transaction { if held { $0.animation = nil } }
                        .animation(held ? nil : Motion.settle, value: dropHint?.index)
                        .zIndex(held ? 1 : 0)
                        .shadow(color: .black.opacity(held ? 0.14 : 0), radius: 12, y: 4)
                        .gesture(looseDrag(tab: tab, index: index, step: step, count: loosePieces.count))
                    }
                case .essential:
                    EmptyView()
                }
            }
        }
        if let hint = dropHint, hint.zone == .loose {
            insertMark(at: hint.index, in: .loose, columns: 1, width: 0, height: SideBar.row + SideBar.gap)
        }
        }
        .coordinateSpace(name: "rows")
    }

    /// Folder headers and visible loose tabs for the column (pins stay above).
    private var loosePieces: [StripPiece] {
        browser.spaceShownPieces.filter {
            switch $0 {
            case .loose, .folder: return true
            default: return false
            }
        }
    }

    /// The loose tabs and the row that makes another, which scroll as one.
    private var rows: some View {
        VStack(alignment: .leading, spacing: 0) {
            loose
            newTab
        }
    }

    /// The foot's door and its margin beneath.
    private static let footHeight: CGFloat = 26 + 10

    private var newTab: some View {
        Quiet(icon: "plus", title: "New tab", height: SideBar.row) { browser.newTab() }
            .padding(.top, SideBar.gap)
    }

    /// One small door at the bottom: the settings.
    private var foot: some View {
        HStack(spacing: 2) {
            ProfileDot(browser: browser)
            if browser.prefs.usesSpaces { SpaceDot(browser: browser) }
            ExtensionSlot(edge: .trailing)
            Door(icon: "bookmark", help: "Bookmarks") { browser.bookmarksOpen.toggle() }
                .popover(isPresented: $browser.bookmarksOpen, arrowEdge: .trailing) {
                    BookmarksDropdown(browser: browser, bookmarks: browser.bookmarks)
                }
            if browser.downloadsChrome {
                DownloadsDoor(browser: browser)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 10)
    }

}

/// Essentials' square grid, every cell laid out at once. A lazy grid makes
/// its cells only once the column is on screen, where the column's slide
/// can't take them along: folded with ⌘S and brought back, the squares stood
/// in place while the column came in beneath them. A dozen squares need no
/// laziness. Width/height are animatable so add/remove springs the split
/// instead of jumping.
private struct PinGrid: Layout {
    var columns: Int
    var width: CGFloat
    var height: CGFloat
    var spacing: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(width, height) }
        set {
            width = newValue.first
            height = newValue.second
        }
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let cols = max(1, columns)
        let rows = max(1, (subviews.count + cols - 1) / cols)
        return CGSize(
            width: CGFloat(cols) * width + CGFloat(max(0, cols - 1)) * spacing,
            height: CGFloat(rows) * height + CGFloat(max(0, rows - 1)) * spacing
        )
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let cols = max(1, columns)
        for (index, subview) in subviews.enumerated() {
            subview.place(
                at: CGPoint(
                    x: bounds.minX + CGFloat(index % cols) * (width + spacing),
                    y: bounds.minY + CGFloat(index / cols) * (height + spacing)
                ),
                proposal: ProposedViewSize(width: width, height: height)
            )
        }
    }
}

/// A pinned tab as a cell in the block at the top of the column — as wide as
/// its row asks for, but never taller than the classic square, so a row with
/// room to spare turns into a wide, short button rather than a bigger icon.
private struct PinSquare: View {
    @ObservedObject var browser: Browser
    @ObservedObject var prefs: Preferences
    @ObservedObject var tab: Tab
    let live: Bool
    let pill: Namespace.ID
    var morph: Namespace.ID?
    var width: CGFloat = 34
    var height: CGFloat = 34

    @State private var hovering = false

    /// Everything drawn inside scales off the shorter edge — the one that
    /// stays put — so the glyph sits at its usual size, centred, rather than
    /// stretching to chase the width.
    private var scale: CGFloat { min(width, height) }

    var body: some View {
        Group {
            if browser.editingPin == tab.id {
                PinField(browser: browser, tab: tab)
            } else if prefs.glyph == .icons, let icon = tab.icon {
                Mark(icon: icon, letter: tab.pin ?? "", size: scale * 16 / 34, dim: tab.asleep)
            } else {
                Text(tab.pin ?? "")
                    .font(.system(size: scale * 12 / 34, weight: .medium))
                    .foregroundStyle((live ? Palette.ink : Palette.muted).opacity(tab.asleep ? 0.45 : 1))
            }
        }
        .frame(width: scale * 16 / 34, height: scale * 16 / 34)
        .frame(width: width, height: height)
        .background {
            if live {
                RoundedRectangle(cornerRadius: scale * 9 / 34, style: .continuous)
                    .fill(Palette.wash)
                    // Essentials only: never share "live" with pin/loose rows
                    // (#14 ghost favicons after a space swap).
                    .matchedGeometryEffect(id: "live-essential", in: pill)
            } else {
                RoundedRectangle(cornerRadius: scale * 9 / 34, style: .continuous)
                    .fill(hovering ? Palette.hover : Palette.wash.opacity(0.55))
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: scale * 9 / 34, style: .continuous))
        .modifier(OneClick(double: live) {
            if live { browser.editLetter(tab) } else { browser.select(tab) }
        })
        // Put down, like ⌘W: close() is what knows a pin isn't removed.
        .overlay { MiddleClick { browser.close(tab) } }
        .onHover { hovering = $0 }
        .contextMenu { TabMenu(browser: browser, tab: tab, close: { browser.close(tab) }) }
        .help(tab.label)
        .animation(Motion.quick, value: hovering)
        // Morph into / out of the square when crossing the essentials boundary.
        .modifier(MorphLink(id: tab.id, namespace: morph))
        .transition(.scale(scale: 0.8).combined(with: .opacity))
    }
}

/// Optional matched-geometry link so a row can morph into an essential square.
private struct MorphLink: ViewModifier {
    let id: Tab.ID
    let namespace: Namespace.ID?

    @ViewBuilder
    func body(content: Content) -> some View {
        if let namespace {
            content.matchedGeometryEffect(id: id, in: namespace)
        } else {
            content
        }
    }
}

/// One tab, as a line in the column.
private struct SideRow: View {
    @ObservedObject var browser: Browser
    @ObservedObject var prefs: Preferences
    @ObservedObject var tab: Tab
    let live: Bool
    let pill: Namespace.ID
    let close: () -> Void
    /// Matched-geometry id for the live wash — pin rows use `live-pin-row`
    /// so a space-swap never morphs a pin into a loose row (#14).
    var geometry: String = "live-row"
    var morph: Namespace.ID?

    @State private var hovering = false
    @State private var shake: CGFloat = 0

    private var editing: Bool { browser.editingTab == tab.id }

    /// A pin holding no page (put down with ⌘W, or restored and not yet
    /// opened). The trailing control deletes the pin rather than "closing"
    /// a session that is already gone.
    private var dormantPin: Bool { tab.pin != nil && tab.asleep }

    /// The ring or the speaker, which stay for as long as the page loads or
    /// plays (or is muted) and so keep a place of their own at the end of the
    /// row. The cross is only there under the pointer, and takes none.
    private var status: Bool { !editing && (tab.loading || speaker) }
    /// The speaker, which can be pressed, and so steps in beside the cross
    /// under the pointer rather than hiding beneath it as the ring does.
    private var speaker: Bool { !tab.loading && (tab.noisy || tab.muted) }

    /// Trailing control: close an open pin/tab; for a dormant pin, unpin and
    /// discard the row so it leaves the list entirely.
    private func trailingAct() {
        if dormantPin {
            browser.unpin(tab)
            if tab.asleep { browser.close(tab) }
        } else {
            close()
        }
    }

    var body: some View {
        HStack(spacing: 8) {
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

            if status {
                Spacer(minLength: 2)

                ZStack {
                    if tab.loading {
                        Ring().transition(.opacity)
                    } else {
                        Speaker(tab: tab).transition(.opacity)
                    }
                }
                .frame(width: 15, height: 15)
                // The cross takes this place while the pointer is here; the
                // speaker moves one place in, clear of the cross's reach.
                .opacity(hovering && !speaker ? 0 : 1)
                .padding(.trailing, hovering && speaker ? 23 : 0)
            }
        }
        .padding(.leading, 10)
        .padding(.trailing, status ? 7 : 10)
        .frame(height: 28)
        .frame(maxWidth: .infinity, alignment: .leading)
        // The title keeps its length under the pointer and fades out
        // beneath the cross, rather than being cut shorter, so its end
        // doesn't jump on each row the pointer passes.
        .mask {
            ZStack {
                Rectangle().opacity(hovering && !editing && !status ? 0 : 1)
                HStack(spacing: 0) {
                    Rectangle()
                    LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing)
                        .frame(width: 16)
                    Color.clear.frame(width: 26)
                }
            }
        }
        .overlay(alignment: .trailing) {
            if !editing {
                ZStack {
                    if hovering {
                        Image(systemName: dormantPin ? "trash" : "xmark")
                            .font(.system(size: dormantPin ? 8.5 : 8, weight: .semibold))
                            .foregroundStyle(Palette.muted)
                            .frame(width: 15, height: 15)
                            .background(Palette.ink.opacity(0.07), in: Circle())
                            .transition(.opacity)
                    }
                }
                .frame(width: 15, height: 15)
                .help(dormantPin ? "Remove pin" : "Close tab")
                .overlay {
                    Color.clear
                        .frame(width: 30, height: 28)
                        .contentShape(Rectangle())
                        .onTapGesture { if hovering { trailingAct() } }
                }
                .padding(.trailing, 7)
            }
        }
        .animation(Motion.quick, value: tab.loading)
        .animation(Motion.quick, value: speaker)
        .animation(Motion.quick, value: dormantPin)
        .background { ground }
        .modifier(Shake(travel: shake))
        .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .modifier(OneClick(double: false) {
            if live { browser.beginTabEdit(tab) } else { browser.select(tab) }
        })
        .overlay { MiddleClick(act: trailingAct) }
        .onHover { hovering = $0 }
        .contextMenu { TabMenu(browser: browser, tab: tab, close: trailingAct) }
        .animation(Motion.quick, value: hovering)
        .animation(Motion.glide, value: editing)
        .onChange(of: browser.refusals) { _, _ in
            guard editing else { return }
            shake = 0
            withAnimation(.easeOut(duration: 0.5)) { shake = 1 }
        }
        .modifier(MorphLink(id: tab.id, namespace: morph))
        .transition(.scale(scale: 0.94, anchor: .leading).combined(with: .opacity))
    }

    @ViewBuilder
    private var ground: some View {
        if live {
            ZStack(alignment: .leading) {
                Rectangle().fill(Palette.wash)
                if prefs.showsReading {
                    GeometryReader { geo in
                        Rectangle()
                            .fill(Palette.ink.opacity(0.055))
                            .frame(width: geo.size.width * tab.reading)
                            .animation(.easeOut(duration: 0.15), value: tab.reading)
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            .matchedGeometryEffect(id: geometry, in: pill)
        } else if hovering {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Palette.hover)
        }
    }

    private var colour: Color {
        if live { return Palette.ink }
        return hovering ? Palette.ink.opacity(0.7) : Palette.muted
    }
}

/// A row that is an action rather than a page. Quiet until the pointer is on it.
struct Quiet: View {
    let icon: String
    let title: String
    var height: CGFloat = 28
    let act: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: act) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 10, weight: .medium))
                    .frame(width: 15)
                Text(title)
                    .font(.system(size: 12.5))
                Spacer(minLength: 0)
            }
            .foregroundStyle(hovering ? Palette.ink.opacity(0.7) : Palette.faint)
            .padding(.leading, 10)
            .frame(height: height)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(hovering ? Palette.hover : .clear)
            )
            .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(Motion.quick, value: hovering)
    }
}

/// The speaker at the end of a tab that plays sound, or that was muted and
/// so says it is: a press mutes the tab or lets it be heard again. Drawn as
/// it was before it could be pressed, with the cross's faint disc behind
/// it only while the pointer is on it.
struct Speaker: View {
    @ObservedObject var tab: Tab

    @State private var hovering = false

    var body: some View {
        Button(action: tab.toggleMute) {
            Image(systemName: tab.muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                .font(.system(size: 8))
                .foregroundStyle(Palette.muted)
                .frame(width: 15, height: 15)
                .background(Palette.ink.opacity(hovering ? 0.07 : 0), in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(tab.muted ? "Unmute Tab" : "Mute Tab")
        .animation(Motion.quick, value: hovering)
    }
}

/// A small square holding one symbol. Lit when what it opens is open.
struct Door: View {
    let icon: String
    var on = false
    var help = ""
    let act: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: act) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(on ? Palette.ink : (hovering ? Palette.ink.opacity(0.7) : Palette.muted))
                .frame(width: 26, height: 26)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(on ? Palette.wash : (hovering ? Palette.hover : .clear))
                )
                .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
        .animation(Motion.quick, value: hovering)
        .animation(Motion.quick, value: on)
    }
}

/// Downloads, as a chrome door: appears while files arrive, keeps a quiet
/// progress ring, and opens the same panel as ⇧⌘J. Goes when the panel is
/// opened after the last file lands, or about four seconds later on its own.
struct DownloadsDoor: View {
    @ObservedObject var browser: Browser

    @State private var hovering = false

    private var busy: Bool { !browser.fetching.isEmpty }
    private var fraction: Double { browser.downloadFraction }
    private var count: Int { browser.fetching.count }

    var body: some View {
        Button { browser.hoarding = true } label: {
            ZStack {
                Image(systemName: busy ? "arrow.down" : "checkmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(browser.hoarding || hovering ? Palette.ink : Palette.muted)
                if busy {
                    Circle()
                        .stroke(Palette.faint.opacity(0.55), lineWidth: 1.5)
                        .frame(width: 18, height: 18)
                    Circle()
                        .trim(from: 0, to: min(max(fraction, 0.04), 1))
                        .stroke(Palette.ink.opacity(0.7), style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .frame(width: 18, height: 18)
                        .animation(Motion.quick, value: fraction)
                }
            }
            .frame(width: 26, height: 26)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(browser.hoarding ? Palette.wash : (hovering ? Palette.hover : .clear))
            )
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(busy
              ? (count == 1 ? "1 download in progress   ⇧⌘J" : "\(count) downloads in progress   ⇧⌘J")
              : "Downloads   ⇧⌘J")
        .accessibilityLabel(busy ? "Downloads, in progress" : "Downloads")
        .animation(Motion.quick, value: hovering)
        .animation(Motion.quick, value: browser.hoarding)
        .animation(Motion.quick, value: busy)
        .transition(.opacity.combined(with: .scale(scale: 0.88)))
    }
}
