import AppKit

// The keys this browser answers, and the few a person has asked to change.
//
// Until something is remapped, the same strokes the menus and the key
// monitor have always used still fire — the catalog is those defaults,
// not a new set. Overrides live in Preferences and are a dictionary walk
// on each matching key, nothing more.

struct Stroke: Equatable, Codable {
    var key: String
    var code: UInt16
    var command: Bool
    var shift: Bool
    var option: Bool
    var control: Bool

    func matches(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            .subtracting([.capsLock, .numericPad, .function, .help])
        guard flags.contains(.command) == command,
              flags.contains(.shift) == shift,
              flags.contains(.option) == option,
              flags.contains(.control) == control
        else { return false }
        if code != 0, event.keyCode == code { return true }
        let typed = event.charactersIgnoringModifiers?.lowercased() ?? ""
        return !key.isEmpty && typed == key
    }

    var label: String {
        var out = ""
        if control { out += "⌃" }
        if option { out += "⌥" }
        if shift { out += "⇧" }
        if command { out += "⌘" }
        out += Stroke.glyph(key: key, code: code)
        return out
    }

    private static func glyph(key: String, code: UInt16) -> String {
        switch code {
        case 48: return "⇥"
        case 36, 76: return "↩"
        case 51: return "⌫"
        case 53: return "esc"
        case 123: return "←"
        case 124: return "→"
        case 126: return "↑"
        case 125: return "↓"
        case 24, 69: return "+"
        case 27, 78: return "−"
        default:
            if key == "," { return "," }
            if key == "[" { return "[" }
            if key == "]" { return "]" }
            return key.uppercased()
        }
    }

    static func command(_ key: String, code: UInt16 = 0, shift: Bool = false, option: Bool = false, control: Bool = false) -> Stroke {
        Stroke(key: key, code: code, command: true, shift: shift, option: option, control: control)
    }

    static func from(_ event: NSEvent) -> Stroke {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        return Stroke(
            key: event.charactersIgnoringModifiers?.lowercased() ?? "",
            code: event.keyCode,
            command: flags.contains(.command),
            shift: flags.contains(.shift),
            option: flags.contains(.option),
            control: flags.contains(.control)
        )
    }
}

enum Keys {
    struct Command: Identifiable {
        var id: String
        var title: String
        var stroke: Stroke
    }

    static let catalog: [Command] = [
        Command(id: "newTab", title: "New Tab", stroke: .command("t")),
        Command(id: "newPrivate", title: "New Private Tab", stroke: .command("n", shift: true)),
        Command(id: "reopen", title: "Reopen Closed Tab", stroke: .command("t", shift: true)),
        Command(id: "address", title: "Open Address", stroke: .command("l")),
        Command(id: "closeTab", title: "Close Tab", stroke: .command("w")),
        Command(id: "print", title: "Print", stroke: .command("p")),
        Command(id: "find", title: "Find on Page", stroke: .command("f")),
        Command(id: "findNext", title: "Find Next", stroke: .command("g")),
        Command(id: "findPrev", title: "Find Previous", stroke: .command("g", shift: true)),
        Command(id: "sidebar", title: "Tabs in Sidebar", stroke: .command("s", shift: true)),
        Command(id: "fold", title: "Fold Tab Bar", stroke: .command("s")),
        Command(id: "reload", title: "Reload", stroke: .command("r")),
        Command(id: "reader", title: "Reading Mode", stroke: .command("r", shift: true)),
        Command(id: "float", title: "Float Video", stroke: .command("p", shift: true)),
        Command(id: "hide", title: "Hide Elements", stroke: .command("h", shift: true)),
        Command(id: "hidden", title: "Hidden on This Site", stroke: .command("u", shift: true)),
        Command(id: "zoomIn", title: "Zoom In", stroke: .command("+", code: 24)),
        Command(id: "zoomOut", title: "Zoom Out", stroke: .command("-", code: 27)),
        Command(id: "actualSize", title: "Actual Size", stroke: .command("0", code: 29)),
        Command(id: "inspector", title: "Web Inspector", stroke: .command("i", option: true)),
        Command(id: "console", title: "JavaScript Console", stroke: .command("j", option: true)),
        Command(id: "inspect", title: "Inspect Element", stroke: .command("c", option: true)),
        Command(id: "back", title: "Back", stroke: .command("[")),
        Command(id: "forward", title: "Forward", stroke: .command("]")),
        Command(id: "nextTab", title: "Next Tab", stroke: .command("]", shift: true)),
        Command(id: "prevTab", title: "Previous Tab", stroke: .command("[", shift: true)),
        Command(id: "searchTabs", title: "Search Tabs", stroke: .command("k")),
        Command(id: "duplicate", title: "Duplicate Tab", stroke: .command("d")),
        Command(id: "copyAddress", title: "Copy Address", stroke: .command("c", shift: true)),
        Command(id: "pasteAndGo", title: "Paste and Go", stroke: .command("v", shift: true)),
        Command(id: "pause", title: "Stop Sound in Tab", stroke: .command("m", shift: true)),
        Command(id: "bookmark", title: "Add This Page", stroke: .command("b", shift: true)),
        Command(id: "history", title: "Show History", stroke: .command("y")),
        Command(id: "downloads", title: "Downloads", stroke: .command("j", shift: true)),
        Command(id: "settings", title: "Settings", stroke: .command(",", code: 43)),
        Command(id: "passwords", title: "Passwords", stroke: .command("l", option: true)),
        Command(id: "cycleTabs", title: "Recent Tabs", stroke: Stroke(key: "", code: 48, command: false, shift: false, option: false, control: true)),
        Command(id: "cycleTabsBack", title: "Recent Tabs Back", stroke: Stroke(key: "", code: 48, command: false, shift: true, option: false, control: true)),
        Command(id: "resetPin", title: "Reset Pinned Tab", stroke: .command("p", shift: true, option: true)),
    ]

    static func stroke(for id: String, overrides: [String: Stroke]) -> Stroke? {
        overrides[id] ?? catalog.first { $0.id == id }?.stroke
    }

    /// The command this key is bound to — an override if there is one,
    /// otherwise the default. One walk of a short list.
    static func match(_ event: NSEvent, overrides: [String: Stroke]) -> String? {
        for command in catalog {
            let stroke = overrides[command.id] ?? command.stroke
            if stroke.matches(event) { return command.id }
        }
        return nil
    }

    /// A default stroke that has been remapped away: swallow it so the menu
    /// doesn't fire the old key.
    static func stolen(_ event: NSEvent, overrides: [String: Stroke]) -> Bool {
        for command in catalog {
            guard overrides[command.id] != nil else { continue }
            if command.stroke.matches(event) { return true }
        }
        return false
    }

    /// Two commands that resolve to the same stroke.
    static func conflicts(overrides: [String: Stroke]) -> Set<String> {
        var seen: [String: String] = [:]
        var clash: Set<String> = []
        for command in catalog {
            let stroke = overrides[command.id] ?? command.stroke
            let token = "\(stroke.command)-\(stroke.shift)-\(stroke.option)-\(stroke.control)-\(stroke.code)-\(stroke.key)"
            if let other = seen[token] {
                clash.insert(command.id)
                clash.insert(other)
            } else {
                seen[token] = command.id
            }
        }
        return clash
    }
}
