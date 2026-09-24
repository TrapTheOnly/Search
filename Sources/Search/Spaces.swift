import SwiftUI
import WebKit

// Spaces: separate sets of tabs in the one window, each with its own
// cookies and sign-ins, and a downloads folder of its own if you like.
//
// Off unless turned on in Settings › Tabs. Until then there is one space,
// the first, and nothing about it shows: its tabs are the session there
// has always been and its sites use the store there has always been, so
// turning spaces on signs nobody out.
//
// A space's sites live in a WebKit store of their own, made by identifier;
// history, bookmarks, the passwords in the keychain, settings and
// extensions are shared by every space. Switching swaps the row of tabs:
// the ones left behind are parked, their sound paused, and they sleep
// after half an hour as any tab does. ⌃1–⌃9 switch, as in Arc.

struct Space: Codable, Identifiable, Equatable {
    var id: UUID
    var name: String
    /// Which of `Spaces.colours` washes the chrome (tab strip / sidebar) on
    /// top of Look. Icons name the space in the UI; colour only tints.
    var colour: Int
    /// Its icon, one of `Spaces.icons`.
    var icon: String?
    /// Signed in wherever the first space is — the same cookies and
    /// sign-ins, only the tabs its own — rather than a store of its own.
    /// Chosen when it is made; nil, for a space from before the choice, is
    /// a store of its own.
    var sharesSignIns: Bool?
    /// Where this space's downloads go; nil for the folder in Settings.
    var downloads: String?

    /// The first space: the session and the store there were before spaces.
    static let firstID = UUID(uuidString: "00000000-0000-0000-0000-000000000001") ?? UUID()
    var isFirst: Bool { id == Space.firstID }

    /// The icon it shows: its own, or a house for the first and a
    /// briefcase for any other that has none yet.
    var symbol: String { icon.flatMap { Spaces.icons.contains($0) ? $0 : nil } ?? (isFirst ? "house" : "briefcase") }
}

enum Spaces {
    /// RGB for each named tint — shared by SwiftUI swatches and the chrome wash.
    static let colourRGB: [(CGFloat, CGFloat, CGFloat)] = [
        (0.45, 0.47, 0.52), // slate
        (0.26, 0.52, 0.96), // blue
        (0.20, 0.66, 0.45), // green
        (0.96, 0.62, 0.20), // orange
        (0.90, 0.33, 0.40), // red
        (0.62, 0.40, 0.90), // violet
    ]

    static let colours: [Color] = colourRGB.map { Color(red: $0.0, green: $0.1, blue: $0.2) }
    static let colourNames = ["Slate", "Blue", "Green", "Orange", "Red", "Violet"]

    /// Clamp a stored index into `colours` (older files may be out of range).
    static func colourIndex(_ raw: Int) -> Int {
        guard !colourRGB.isEmpty else { return 0 }
        let n = colourRGB.count
        return ((raw % n) + n) % n
    }

    /// A soft wash of a space colour over chrome. Opacity follows the window's
    /// appearance so the tint sits on Look rather than replacing light/dark.
    static func chromeWash(_ raw: Int) -> Color {
        Color(nsColor: chromeWashNS(raw))
    }

    static func chromeWashNS(_ raw: Int) -> NSColor {
        let i = colourIndex(raw)
        let rgb = colourRGB[i]
        return NSColor(name: nil) { appearance in
            let dim = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            // Slate stays quieter; vivid colours a touch more present in dark.
            let vivid = i != 0
            let alpha: CGFloat = dim ? (vivid ? 0.20 : 0.09) : (vivid ? 0.12 : 0.055)
            return NSColor(srgbRed: rgb.0, green: rgb.1, blue: rgb.2, alpha: alpha)
        }
    }

    /// Solid swatch for menus — the full colour, not the wash.
    static func swatchNS(_ raw: Int) -> NSColor {
        let rgb = colourRGB[colourIndex(raw)]
        return NSColor(srgbRed: rgb.0, green: rgb.1, blue: rgb.2, alpha: 1)
    }

    static func swatchImage(_ raw: Int) -> NSImage {
        let size = NSSize(width: 12, height: 12)
        let image = NSImage(size: size)
        image.lockFocus()
        swatchNS(raw).setFill()
        NSBezierPath(roundedRect: NSRect(origin: .zero, size: size), xRadius: 3, yRadius: 3).fill()
        image.unlockFocus()
        image.isTemplate = false
        return image
    }

    /// The icons a space can wear: Apple's own symbols, drawn in one weight
    /// and one grey, grouped as work, thinking, leisure and life.
    static let icons = [
        "briefcase", "building.2", "desktopcomputer", "laptopcomputer", "chevron.left.forwardslash.chevron.right", "terminal",
        "sparkles", "brain.head.profile", "lightbulb", "gamecontroller", "beach.umbrella", "cup.and.saucer",
        "music.note", "film", "paintpalette", "camera", "house", "book",
        "graduationcap", "cart", "airplane", "dumbbell", "leaf", "heart",
    ]
    static let iconNames = [
        "Work", "Office", "Desktop", "Laptop", "Code", "Terminal",
        "AI", "Thinking", "Ideas", "Games", "Leisure", "Café",
        "Music", "Film", "Art", "Photos", "Home", "Reading",
        "Studies", "Shopping", "Travel", "Sport", "Nature", "Personal",
    ]

    private static var file: URL { Store.file("spaces.json") }

    /// Every space, the first one first — made on the spot if there is no
    /// list yet.
    static func read() -> [Space] {
        let saved = (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode([Space].self, from: $0) } ?? []
        let first = saved.first(where: \.isFirst) ?? Space(id: Space.firstID, name: "Personal", colour: 0)
        return [first] + saved.filter { !$0.isFirst }
    }

    static func write(_ spaces: [Space]) {
        guard let data = try? JSONEncoder().encode(spaces) else { return }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)
    }

    /// The space new tabs are made in: the one on screen.
    @MainActor static var current = Space.firstID

    /// Each space's store, made once: WebKit shares processes between views
    /// that ask for the same store object.
    @MainActor private static var stores: [UUID: WKWebsiteDataStore] = [:]
    /// The spaces signed in wherever the first one is (see Space.sharesSignIns).
    @MainActor static var sharing: Set<UUID> = []

    @MainActor static func store(for id: UUID) -> WKWebsiteDataStore {
        if id == Space.firstID || sharing.contains(id) { return Store.websites }
        if let made = stores[id] { return made }
        let made = WKWebsiteDataStore(forIdentifier: id)
        stores[id] = made
        return made
    }

    /// A space's store and everything in it, gone. What it holds — cookies,
    /// sign-ins, storage, caches — is emptied at once. The store itself
    /// WebKit won't remove while this run still holds on to it, however
    /// closed its tabs, so it is written down and removed at the next
    /// launch if the tries in between don't manage.
    @MainActor static func erase(_ id: UUID) {
        guard id != Space.firstID else { return }
        // And once more a moment later, for what its closing tabs were
        // still writing — the cache of the page on screen, for one.
        let store = store(for: id)
        let everything = WKWebsiteDataStore.allWebsiteDataTypes()
        store.removeData(ofTypes: everything, modifiedSince: .distantPast) {}
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            store.removeData(ofTypes: everything, modifiedSince: .distantPast) {}
        }
        stores[id] = nil
        let pending = Set(Store.settings.stringArray(forKey: "spaces.erasing") ?? []).union([id.uuidString])
        Store.settings.set(pending.sorted(), forKey: "spaces.erasing")
        sweep()
        for delay in [3.0, 15.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { sweep() }
        }
    }

    /// Every store of a deleted space that is still there, tried again.
    @MainActor static func sweep() {
        for text in Store.settings.stringArray(forKey: "spaces.erasing") ?? [] {
            guard let id = UUID(uuidString: text) else { continue }
            Task { @MainActor in
                do { try await WKWebsiteDataStore.remove(forIdentifier: id) } catch {
                    // Gone already is as good as removed; anything else is
                    // tried again later.
                    let left = await WKWebsiteDataStore.allDataStoreIdentifiers
                    guard !left.contains(id) else { return }
                }
                let now = (Store.settings.stringArray(forKey: "spaces.erasing") ?? []).filter { $0 != text }
                Store.settings.set(now, forKey: "spaces.erasing")
            }
        }
    }
}

/// A space's row of tabs while another space is on screen.
struct Parked {
    var tabs: [Tab]
    var active: Tab.ID?
}

extension Browser {
    var space: Space { spaces.first { $0.id == spaceID } ?? spaces[0] }

    /// Every tab of the spaces not on screen, for the sleep timer.
    var parkedTabs: [Tab] { parked.values.flatMap(\.tabs) }

    /// Where a download lands: the space's folder, or the one in Settings.
    var downloadsFolder: URL {
        guard prefs.usesSpaces, let path = space.downloads else { return prefs.downloads }
        return URL(fileURLWithPath: path)
    }

    /// ⌃1–⌃9, and the menu on the space's dot.
    func switchSpace(to id: UUID) {
        guard prefs.usesSpaces else { return }
        enter(id)
    }

    private func enter(_ id: UUID) {
        guard id != spaceID, let to = spaces.firstIndex(where: { $0.id == id }) else { return }
        // Which way the icon at the foot turns over: the way the spaces lie.
        if !makingSpace { spaceStep = to > (spaces.firstIndex { $0.id == spaceID } ?? 0) ? 1 : -1 }
        cancelTabEdit()
        if floater.showing { land() }
        writeSession(now: true)

        // The row on screen is parked as it is. Its sound stops: a space
        // you left is not one you are listening to.
        for tab in tabs where tab.built != nil { tab.web.pauseAllMediaPlayback() }
        parked[spaceID] = Parked(tabs: tabs, active: activeID)

        spaceID = id
        Spaces.current = id
        Store.settings.set(id.uuidString, forKey: "space.current")
        if let back = parked.removeValue(forKey: id), !back.tabs.isEmpty {
            showRow(back.tabs, active: back.active)
            if let active, !active.wake() { active.revive() }
        } else {
            showRow([], active: nil)
            restoreSession()
        }
        editing = active?.isBlank ?? true
        typed = ""
        askFocus()
        announce(space.name)
    }

    /// Every other space's row, made ahead of time, so the column can show
    /// the next space beside this one while two fingers bring it in.
    func preloadSpaces() {
        for space in spaces where space.id != spaceID && parked[space.id] == nil {
            parked[space.id] = loadRow(space.id)
        }
    }

    func switchSpace(index: Int) {
        guard spaces.indices.contains(index) else { return }
        switchSpace(to: spaces[index].id)
    }

    /// The icon a new space gets unless told: the first no space wears yet.
    var freeIcon: String {
        let used = Set(spaces.map(\.symbol))
        return Spaces.icons.first { !used.contains($0) } ?? "briefcase"
    }

    /// The tint a new space gets unless told: the first colour no space wears yet.
    var freeColour: Int {
        let used = Set(spaces.map { Spaces.colourIndex($0.colour) })
        return (0..<Spaces.colourRGB.count).first { !used.contains($0) } ?? 0
    }

    /// A new space, empty, and on screen — signed in where the others are,
    /// or starting afresh with its own cookies and sign-ins.
    func addSpace(named name: String, icon: String? = nil, colour: Int? = nil, sharesSignIns: Bool = true) {
        makingSpace = false
        let made = Space(id: UUID(), name: name, colour: colour ?? freeColour, icon: icon ?? freeIcon, sharesSignIns: sharesSignIns)
        spaces.append(made)
        Spaces.write(spaces)
        switchSpace(to: made.id)
    }

    /// Dragged to another place among the dots. ⌃1–⌃9 follow the order.
    func moveSpace(_ id: UUID, to index: Int) {
        guard let from = spaces.firstIndex(where: { $0.id == id }), spaces.indices.contains(index), from != index else { return }
        spaces.move(fromOffsets: IndexSet(integer: from), toOffset: index > from ? index + 1 : index)
        Spaces.write(spaces)
    }

    /// "New Space…": the card for a new space, in the column or the bar.
    func askForSpace() {
        // In place, where the next space would come in, in the column or the
        // bar alike; a question only while the tabs are folded out of sight.
        if !folded || peeking {
            let here = spaces.firstIndex { $0.id == spaceID } ?? 0
            SpaceSwipe.shared.start(for: self)
            SpaceSwipe.shared.slide(self, to: spaces.count, from: here)
        } else {
            Ask.newSpace { name, shared in self.addSpace(named: name, sharesSignIns: shared) }
        }
    }

    func renameSpace(_ id: UUID, to name: String) {
        guard let at = spaces.firstIndex(where: { $0.id == id }), !name.isEmpty else { return }
        spaces[at].name = name
        Spaces.write(spaces)
    }

    func setSpaceIcon(_ id: UUID, to icon: String) {
        guard let at = spaces.firstIndex(where: { $0.id == id }) else { return }
        spaces[at].icon = icon
        Spaces.write(spaces)
    }

    func setSpaceColour(_ id: UUID, to colour: Int) {
        guard let at = spaces.firstIndex(where: { $0.id == id }) else { return }
        spaces[at].colour = Spaces.colourIndex(colour)
        Spaces.write(spaces)
    }

    func setSpaceDownloads(_ id: UUID, to folder: URL?) {
        guard let at = spaces.firstIndex(where: { $0.id == id }) else { return }
        spaces[at].downloads = folder?.path
        Spaces.write(spaces)
    }

    /// A space, its tabs, and its cookies and sign-ins, gone. The first one
    /// stays: it is where everything was before there were spaces.
    func deleteSpace(_ id: UUID) {
        guard id != Space.firstID, let at = spaces.firstIndex(where: { $0.id == id }) else { return }
        if spaceID == id { switchSpace(to: Space.firstID) }
        for tab in parked.removeValue(forKey: id)?.tabs ?? [] { tab.close() }
        let shared = spaces[at].sharesSignIns == true
        spaces.remove(at: at)
        Spaces.write(spaces)
        Session.erase(space: id)
        // A space signed in with the others has nothing of its own to erase:
        // its cookies are theirs.
        if !shared { Spaces.erase(id) }
    }

    /// Spaces turned off: back to the first one. The others are kept, in
    /// case they are turned on again.
    func leaveSpaces() {
        enter(Space.firstID)
        for (_, row) in parked { for tab in row.tabs { tab.close() } }
        parked = [:]
    }
}

// MARK: - the dot

/// The space on screen, as its icon: at the column's foot, or before the
/// tabs in the row. One icon however many spaces there are; a click opens
/// the menu. When the space changes the icon turns over the way the spaces
/// went — out on one side, the next one in from the other.
struct SpaceDot: View {
    @ObservedObject var browser: Browser
    @State private var hovering = false
    /// What is drawn, a step behind the browser: the space changes in a
    /// frame with nothing animated (see SpaceSwipe.slide), and the icon
    /// turns over just after, on a change of its own.
    @State private var shown: (key: String, symbol: String)?

    static let width: CGFloat = 26

    private var symbol: String { browser.makingSpace ? "plus" : browser.space.symbol }
    private var key: String { browser.makingSpace ? "new" : "\(browser.spaceID.uuidString)-\(browser.space.symbol)" }
    private var dotFill: Color {
        if hovering { return Palette.hover }
        guard browser.prefs.usesSpaces, !browser.makingSpace else { return .clear }
        return Spaces.chromeWash(browser.space.colour)
    }

    var body: some View {
        Button { SpaceMenu.show(for: browser) } label: {
            ZStack {
                Image(systemName: shown?.symbol ?? symbol)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(hovering ? Palette.ink : Palette.muted)
                    .id(shown?.key ?? key)
                    // The way the tabs go: sideways in the column; in the bar
                    // across the top, up for the next space, down going back.
                    .transition(.push(from: browser.prefs.sidebar
                        ? (browser.spaceStep > 0 ? .trailing : .leading)
                        : (browser.spaceStep > 0 ? .bottom : .top)))
            }
            .frame(width: SpaceDot.width, height: 26)
            .clipped()
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(dotFill)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("\(browser.space.name) — ⌃1–⌃9, or two fingers \(browser.prefs.sidebar ? "sideways" : "up or down") over the tabs, to switch")
        .animation(Motion.quick, value: browser.space.colour)
        .onChange(of: key) { _, now in
            let symbol = symbol
            DispatchQueue.main.async {
                withAnimation(.easeOut(duration: 0.22)) { shown = (now, symbol) }
            }
        }
        .animation(Motion.quick, value: hovering)
    }
}

/// The dot's menu: the spaces, then what can be done to the one on screen.
@MainActor
enum SpaceMenu {
    /// Menu items call back into Swift through this.
    private final class Action: NSObject {
        let run: () -> Void
        init(_ run: @escaping () -> Void) { self.run = run }
        @objc func fire() { run() }
    }

    private static var actions: [Action] = []

    private static func item(_ title: String, key: String = "", checked: Bool = false, _ run: @escaping () -> Void) -> NSMenuItem {
        let action = Action(run)
        actions.append(action)
        let item = NSMenuItem(title: title, action: #selector(Action.fire), keyEquivalent: key)
        item.target = action
        item.keyEquivalentModifierMask = key.isEmpty ? [] : .control
        item.state = checked ? .on : .off
        return item
    }

    static func show(for browser: Browser) {
        actions = []
        let menu = NSMenu()
        for (index, space) in browser.spaces.enumerated() {
            let entry = item(space.name, key: index < 9 ? "\(index + 1)" : "", checked: space.id == browser.spaceID) {
                browser.switchSpace(to: space.id)
            }
            entry.image = NSImage(systemSymbolName: space.symbol, accessibilityDescription: nil)
            menu.addItem(entry)
        }
        menu.addItem(.separator())
        menu.addItem(item("New Space…") { browser.askForSpace() })
        menu.addItem(.separator())
        let here = browser.space
        menu.addItem(item("Rename “\(here.name)”…") {
            Ask.name("Rename Space", placeholder: here.name, initial: here.name, confirm: "Rename") { browser.renameSpace(here.id, to: $0) }
        })
        let icons = NSMenu()
        for (symbol, name) in zip(Spaces.icons, Spaces.iconNames) {
            let choice = item(name, checked: here.symbol == symbol) { browser.setSpaceIcon(here.id, to: symbol) }
            choice.image = NSImage(systemSymbolName: symbol, accessibilityDescription: name)
            icons.addItem(choice)
        }
        let icon = NSMenuItem(title: "Icon", action: nil, keyEquivalent: "")
        icon.submenu = icons
        menu.addItem(icon)
        let tints = NSMenu()
        for (index, name) in Spaces.colourNames.enumerated() {
            let choice = item(name, checked: Spaces.colourIndex(here.colour) == index) {
                browser.setSpaceColour(here.id, to: index)
            }
            choice.image = Spaces.swatchImage(index)
            tints.addItem(choice)
        }
        let tint = NSMenuItem(title: "Colour", action: nil, keyEquivalent: "")
        tint.submenu = tints
        menu.addItem(tint)
        // The order is the swipe's, and ⌃1–⌃9's.
        if let at = browser.spaces.firstIndex(where: { $0.id == here.id }) {
            if at > 0 { menu.addItem(item("Move Left") { browser.moveSpace(here.id, to: at - 1) }) }
            if at < browser.spaces.count - 1 { menu.addItem(item("Move Right") { browser.moveSpace(here.id, to: at + 1) }) }
        }
        let folder = here.downloads.map { URL(fileURLWithPath: $0).lastPathComponent }
        menu.addItem(item(folder.map { "Downloads to “\($0)”…" } ?? "Downloads Folder…") {
            Ask.folder { browser.setSpaceDownloads(here.id, to: $0) }
        })
        if folder != nil {
            menu.addItem(item("Downloads to the Folder in Settings") { browser.setSpaceDownloads(here.id, to: nil) })
        }
        if !here.isFirst {
            menu.addItem(.separator())
            menu.addItem(item("Delete “\(here.name)”…") {
                Ask.sure("Delete “\(here.name)”?", detail: "Its tabs close, and its cookies and sign-ins are erased from this Mac. History and bookmarks stay.", confirm: "Delete") {
                    browser.deleteSpace(here.id)
                }
            })
        }
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }
}

/// The few questions a space's menu asks, as sheets on the window.
@MainActor
enum Ask {
    static func name(_ title: String, placeholder: String, initial: String = "", confirm: String, then: @escaping (String) -> Void) {
        let alert = NSAlert()
        alert.messageText = title
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.placeholderString = placeholder
        field.stringValue = initial
        alert.accessoryView = field
        alert.addButton(withTitle: confirm)
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        show(alert) { ok in
            let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if ok, !name.isEmpty { then(name) }
        }
    }

    /// A new space's name, and whether it keeps the sign-ins the others
    /// have — for when the column isn't there to hold the card.
    static func newSpace(then: @escaping (String, Bool) -> Void) {
        let alert = NSAlert()
        alert.messageText = "New Space"
        alert.informativeText = "Its own tabs. Signed in where your other spaces are, unless it starts afresh."
        let field = NSTextField(frame: NSRect(x: 0, y: 30, width: 260, height: 24))
        field.placeholderString = "Work"
        let fresh = NSButton(checkboxWithTitle: "Start signed out, with its own cookies", target: nil, action: nil)
        fresh.frame = NSRect(x: 0, y: 0, width: 260, height: 22)
        let box = NSView(frame: NSRect(x: 0, y: 0, width: 260, height: 56))
        box.addSubview(field)
        box.addSubview(fresh)
        alert.accessoryView = box
        alert.addButton(withTitle: "Create")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        show(alert) { ok in
            let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if ok, !name.isEmpty { then(name, fresh.state != .on) }
        }
    }

    static func sure(_ title: String, detail: String, confirm: String, then: @escaping () -> Void) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = detail
        alert.addButton(withTitle: confirm).hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")
        show(alert) { ok in if ok { then() } }
    }

    static func folder(then: @escaping (URL?) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Use for This Space"
        panel.message = "Downloads in this space go here. Cancel keeps the folder it has."
        guard let window = Links.window else { return }
        panel.beginSheetModal(for: window) { answer in
            if answer == .OK, let url = panel.url { then(url) }
        }
    }

    private static func show(_ alert: NSAlert, _ done: @escaping (Bool) -> Void) {
        guard let window = Links.window else {
            done(alert.runModal() == .alertFirstButtonReturn)
            return
        }
        alert.beginSheetModal(for: window) { done($0 == .alertFirstButtonReturn) }
    }
}
