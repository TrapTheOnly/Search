import SwiftUI
import WebKit

// Profiles: separate local identities in the one window.
//
// A profile is who you are in this browser — its own tabs, spaces, cookies,
// history, bookmarks, hidden elements, passwords and which extensions are
// on. Spaces still do what they did: named rows of tabs inside the profile
// on screen. Switching a profile is the same kind of thing as switching a
// space, not a second window and not a second process.
//
// The files that were already in Application Support/Search belong to
// Personal, the first profile, named for the first space. They stay where
// they are. Another profile keeps its files under Profiles/<id>/. A test
// world already has a folder of its own (see Store.world); profiles live
// inside that.

struct Profile: Codable, Identifiable, Equatable {
    var id: UUID
    var name: String
    /// Which of `Spaces.colours`.
    var colour: Int
    /// One of `Profiles.icons`.
    var icon: String?

    /// The first profile: the session and the store there were before
    /// profiles. Same sentinel as the first space, on purpose — Personal
    /// is both.
    static let firstID = UUID(uuidString: "00000000-0000-0000-0000-000000000001") ?? UUID()
    var isFirst: Bool { id == Profile.firstID }

    var symbol: String {
        icon.flatMap { Profiles.icons.contains($0) ? $0 : nil } ?? (isFirst ? "person" : "person.crop.circle")
    }

    var tint: Color { Spaces.colours[colour % Spaces.colours.count] }
}

enum Profiles {
    static let icons = [
        "person", "person.crop.circle", "briefcase", "house", "laptopcomputer", "building.2",
        "book", "graduationcap", "heart", "star", "leaf", "gamecontroller",
    ]
    static let iconNames = [
        "Person", "Account", "Work", "Home", "Laptop", "Office",
        "Reading", "Studies", "Personal", "Star", "Nature", "Play",
    ]

    private static var file: URL { Store.folder.appendingPathComponent("profiles.json") }

    struct Shape: Codable {
        var profiles: [Profile]
        var current: UUID
    }

    /// Personal, always first. A missing list is the browser there has
    /// always been: one profile, nothing moved.
    static func read() -> [Profile] {
        let saved = load().profiles
        let first = saved.first(where: \.isFirst) ?? Profile(id: Profile.firstID, name: "Personal", colour: 0, icon: "person")
        return [first] + saved.filter { !$0.isFirst }
    }

    /// Who is on screen, without creating a file. A list that won't decode
    /// is set aside rather than trusted.
    static func peekCurrent() -> UUID {
        let shape = load()
        return shape.profiles.contains(where: { $0.id == shape.current }) ? shape.current : Profile.firstID
    }

    static func write(_ profiles: [Profile], current: UUID) {
        let first = profiles.first(where: \.isFirst) ?? Profile(id: Profile.firstID, name: "Personal", colour: 0, icon: "person")
        let list = [first] + profiles.filter { !$0.isFirst }
        let current = list.contains(where: { $0.id == current }) ? current : first.id
        guard let data = try? JSONEncoder().encode(Shape(profiles: list, current: current)) else { return }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)
    }

    static func setCurrent(_ id: UUID) {
        write(read(), current: id)
        Store.profileID = id
    }

    /// The setting that remembers which space this profile was last in.
    static var spaceKey: String { "space.current.\(Store.profileID.uuidString)" }

    /// The space this profile left on, or — for Personal, once — the key
    /// from before spaces were per-profile.
    static func lastSpace() -> UUID? {
        if let id = Store.settings.string(forKey: spaceKey).flatMap(UUID.init) { return id }
        if Store.profileID == Profile.firstID {
            return Store.settings.string(forKey: "space.current").flatMap(UUID.init)
        }
        return nil
    }

    private static func load() -> Shape {
        let empty = Shape(profiles: [Profile(id: Profile.firstID, name: "Personal", colour: 0, icon: "person")], current: Profile.firstID)
        guard FileManager.default.fileExists(atPath: file.path) else { return empty }
        guard let data = try? Data(contentsOf: file) else { return empty }
        guard let shape = try? JSONDecoder().decode(Shape.self, from: data), !shape.profiles.isEmpty else {
            Store.quarantine(file)
            return empty
        }
        return shape
    }

    // MARK: - cookies

    /// Personal uses the store there always was, so turning profiles on
    /// signs nobody out. Another profile gets a store of its own.
    @MainActor private static var stores: [UUID: WKWebsiteDataStore] = [:]

    @MainActor static var websites: WKWebsiteDataStore {
        let id = Store.profileID
        if id == Profile.firstID { return Store.websites }
        if let made = stores[id] { return made }
        let made = WKWebsiteDataStore(forIdentifier: id)
        stores[id] = made
        return made
    }

    /// A profile's store and the files it kept, gone. Personal is not
    /// erased this way: its files sit next to the other profiles'.
    @MainActor static func erase(_ id: UUID) {
        guard id != Profile.firstID else { return }
        // Isolated spaces of this profile have stores of their own; the
        // folder goes next, so they are named while the files are still here.
        let previous = Store.profileID
        Store.profileID = id
        let leftover = Spaces.read()
        Store.profileID = previous
        for space in leftover where space.sharesSignIns != true && !space.isFirst {
            Spaces.erase(space.id)
        }
        stores[id] = nil
        let folder = Store.folder.appendingPathComponent("Profiles/\(id.uuidString)", isDirectory: true)
        try? FileManager.default.removeItem(at: folder)
        let pending = Set(Store.settings.stringArray(forKey: "profiles.erasing") ?? []).union([id.uuidString])
        Store.settings.set(pending.sorted(), forKey: "profiles.erasing")
        Vault.erase(profile: id)
        sweep()
        for delay in [3.0, 15.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { sweep() }
        }
    }

    @MainActor static func sweep() {
        for text in Store.settings.stringArray(forKey: "profiles.erasing") ?? [] {
            guard let id = UUID(uuidString: text) else { continue }
            Task { @MainActor in
                do { try await WKWebsiteDataStore.remove(forIdentifier: id) } catch {
                    let left = await WKWebsiteDataStore.allDataStoreIdentifiers
                    guard !left.contains(id) else { return }
                }
                let now = (Store.settings.stringArray(forKey: "profiles.erasing") ?? []).filter { $0 != text }
                Store.settings.set(now, forKey: "profiles.erasing")
            }
        }
    }

    // MARK: - extensions, per profile

    /// Which installed extensions are on in this profile. Missing means
    /// whatever `installed.json` says — the first visit copies that.
    static func extensionEnabled() -> [String: Bool] {
        guard let data = try? Data(contentsOf: Store.file("extensions-state.json")),
              let saved = try? JSONDecoder().decode([String: Bool].self, from: data)
        else { return [:] }
        return saved
    }

    static func setExtension(_ id: String, enabled: Bool) {
        var saved = extensionEnabled()
        saved[id] = enabled
        guard let data = try? JSONEncoder().encode(saved) else { return }
        try? FileManager.default.createDirectory(
            at: Store.file("extensions-state.json").deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? data.write(to: Store.file("extensions-state.json"), options: .atomic)
    }
}

extension Browser {
    var profile: Profile { profiles.first { $0.id == profileID } ?? profiles[0] }

    /// The icon a new profile gets unless told: the first no profile wears yet.
    var freeProfileIcon: String {
        let used = Set(profiles.map(\.symbol))
        return Profiles.icons.first { !used.contains($0) } ?? "person.crop.circle"
    }

    var freeProfileColour: Int {
        let used = Set(profiles.map(\.colour))
        return (0..<Spaces.colours.count).first { !used.contains($0) } ?? (profiles.count % Spaces.colours.count)
    }

    /// In-process: the same window, the other identity. Tabs are torn down
    /// rather than parked — a profile you left is not one whose pages should
    /// keep running. The session file brings them back.
    func switchProfile(to id: UUID) {
        guard id != profileID, profiles.contains(where: { $0.id == id }) else { return }
        cancelTabEdit()
        if floater.showing { land() }
        writeSession(now: true)
        resetProfileRow()

        profileID = id
        Profiles.setCurrent(id)

        spaces = Spaces.read()
        spaceID = Space.firstID
        if prefs.usesSpaces, let last = Profiles.lastSpace(), spaces.contains(where: { $0.id == last }) {
            spaceID = last
        }
        Spaces.current = spaceID
        Spaces.sharing = Set(spaces.filter { $0.sharesSignIns == true }.map(\.id))

        bookmarks.reload()
        history.reload()
        curtain.reload()
        relist()
        if #available(macOS 15.4, *) { Extensions.shared.applyProfile() }

        restoreSession()
        if prefs.usesSpaces { preloadSpaces() }
        editing = active?.isBlank ?? true
        typed = ""
        askFocus()
        announce(profile.name)
    }

    func addProfile(named name: String, icon: String? = nil, colour: Int? = nil) {
        let made = Profile(
            id: UUID(),
            name: name,
            colour: colour ?? freeProfileColour,
            icon: icon ?? freeProfileIcon
        )
        profiles.append(made)
        Profiles.write(profiles, current: profileID)
        switchProfile(to: made.id)
    }

    func renameProfile(_ id: UUID, to name: String) {
        guard let at = profiles.firstIndex(where: { $0.id == id }), !name.isEmpty else { return }
        profiles[at].name = name
        Profiles.write(profiles, current: profileID)
    }

    func setProfileIcon(_ id: UUID, to icon: String) {
        guard let at = profiles.firstIndex(where: { $0.id == id }) else { return }
        profiles[at].icon = icon
        Profiles.write(profiles, current: profileID)
    }

    func setProfileColour(_ id: UUID, to colour: Int) {
        guard let at = profiles.firstIndex(where: { $0.id == id }) else { return }
        profiles[at].colour = colour
        Profiles.write(profiles, current: profileID)
    }

    /// A profile, its files, its cookies and its passwords, gone. Personal
    /// stays: it is where everything was before there were profiles, and its
    /// files sit in the folder the others live next to.
    func deleteProfile(_ id: UUID) {
        guard id != Profile.firstID, profiles.count > 1,
              let at = profiles.firstIndex(where: { $0.id == id })
        else { return }
        if profileID == id {
            let fallback = profiles.first { $0.id != id }?.id ?? Profile.firstID
            switchProfile(to: fallback)
        }
        profiles.remove(at: at)
        Profiles.write(profiles, current: profileID)
        Profiles.erase(id)
    }

    func askForProfile() {
        Ask.newProfile { name in self.addProfile(named: name) }
    }
}

// MARK: - the dot

/// The profile on screen, as its icon: at the column's foot and before the
/// tabs in the row, next to the space's. One icon however many profiles
/// there are; a click opens the menu. Colour is the profile's; the rest of
/// the chrome stays the app's grey.
struct ProfileDot: View {
    @ObservedObject var browser: Browser
    @State private var hovering = false

    static let width: CGFloat = 26

    var body: some View {
        Button { ProfileMenu.show(for: browser) } label: {
            Image(systemName: browser.profile.symbol)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(hovering ? Palette.ink : browser.profile.tint)
                .frame(width: ProfileDot.width, height: 26)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(hovering ? Palette.hover : .clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("\(browser.profile.name) — switch profile")
        .animation(Motion.quick, value: hovering)
    }
}

/// Safari's shape: the current profile (symbol, name, check), the others,
/// then New Profile and Manage.
@MainActor
enum ProfileMenu {
    private final class Action: NSObject {
        let run: () -> Void
        init(_ run: @escaping () -> Void) { self.run = run }
        @objc func fire() { run() }
    }

    private static var actions: [Action] = []

    private static func item(_ title: String, checked: Bool = false, _ run: @escaping () -> Void) -> NSMenuItem {
        let action = Action(run)
        actions.append(action)
        let item = NSMenuItem(title: title, action: #selector(Action.fire), keyEquivalent: "")
        item.target = action
        item.state = checked ? .on : .off
        return item
    }

    static func show(for browser: Browser) {
        actions = []
        let menu = NSMenu()
        for profile in browser.profiles {
            let entry = item(profile.name, checked: profile.id == browser.profileID) {
                withAnimation(Motion.glide) { browser.switchProfile(to: profile.id) }
            }
            entry.image = mark(for: profile)
            menu.addItem(entry)
        }
        menu.addItem(.separator())
        menu.addItem(item("New Profile…") { browser.askForProfile() })
        menu.addItem(item("Manage Profiles…") { browser.managingProfiles = true })
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }

    private static func mark(for profile: Profile) -> NSImage? {
        let base = NSImage(systemSymbolName: profile.symbol, accessibilityDescription: profile.name)
        let color = NSColor(profile.tint)
        let configured = base?.withSymbolConfiguration(
            NSImage.SymbolConfiguration(pointSize: 12, weight: .medium)
                .applying(.init(paletteColors: [color]))
        )
        return configured ?? base
    }
}

/// The list behind Manage: every profile, rename, delete. Personal cannot
/// be deleted. One profile and many both look like a finished list.
struct ProfilesPanel: View {
    @ObservedObject var browser: Browser

    var body: some View {
        Plate("Profiles", width: 420, close: { browser.managingProfiles = false }) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Each profile is a separate identity on this Mac: its own tabs, spaces, sign-ins, history and bookmarks.")
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.muted)
                    .fixedSize(horizontal: false, vertical: true)

                Card {
                    ForEach(Array(browser.profiles.enumerated()), id: \.element.id) { index, profile in
                        if index > 0 { Rule() }
                        row(profile)
                    }
                }
            }
        } foot: {
            HStack {
                Spacer(minLength: 0)
                Pill("New Profile…") { browser.askForProfile() }
            }
        }
    }

    private func row(_ profile: Profile) -> some View {
        let current = profile.id == browser.profileID
        return HStack(spacing: 10) {
            iconButton(profile)
            VStack(alignment: .leading, spacing: 2) {
                Text(profile.name)
                    .font(.system(size: 13))
                    .foregroundStyle(Palette.ink)
                Text(profile.isFirst ? "The profile everything started in" : (current ? "On screen" : "On this Mac"))
                    .font(.system(size: 11.5))
                    .foregroundStyle(Palette.muted)
            }
            Spacer(minLength: 8)
            if current {
                Image(systemName: "checkmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Palette.ink)
            }
            Quick("Rename") {
                Ask.name("Rename Profile", placeholder: profile.name, initial: profile.name, confirm: "Rename") {
                    browser.renameProfile(profile.id, to: $0)
                }
            }
            if !profile.isFirst {
                Quick("Delete", tint: Palette.ink.opacity(0.7)) {
                    Ask.sure(
                        "Delete “\(profile.name)”?",
                        detail: "Its tabs, history, bookmarks, cookies and saved passwords are erased from this Mac. Other profiles are not touched.",
                        confirm: "Delete"
                    ) {
                        browser.deleteProfile(profile.id)
                    }
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .contentShape(Rectangle())
        .onTapGesture {
            guard !current else { return }
            withAnimation(Motion.glide) { browser.switchProfile(to: profile.id) }
        }
    }

    private func iconButton(_ profile: Profile) -> some View {
        ProfileIconPick(browser: browser, profile: profile)
    }
}

/// The profile's mark, and a click for the others — the same popover a new
/// space uses for its icon.
private struct ProfileIconPick: View {
    @ObservedObject var browser: Browser
    let profile: Profile
    @State private var choosing = false

    var body: some View {
        Button { choosing = true } label: {
            Image(systemName: profile.symbol)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(profile.tint)
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Choose an icon")
        .popover(isPresented: $choosing, arrowEdge: .bottom) {
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(28), spacing: 4), count: 6), spacing: 4) {
                ForEach(Array(zip(Profiles.icons, Profiles.iconNames)), id: \.0) { symbol, name in
                    Button {
                        browser.setProfileIcon(profile.id, to: symbol)
                        choosing = false
                    } label: {
                        Image(systemName: symbol)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(profile.symbol == symbol ? Palette.ink : Palette.muted)
                            .frame(width: 28, height: 28)
                            .background(
                                RoundedRectangle(cornerRadius: 7, style: .continuous)
                                    .fill(profile.symbol == symbol ? Palette.wash : .clear)
                            )
                    }
                    .buttonStyle(.plain)
                    .help(name)
                }
            }
            .padding(8)
        }
    }
}
