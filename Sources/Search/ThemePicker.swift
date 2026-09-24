import AppKit
import SwiftUI

// Theme picker: Look (system / light / dark) plus a continuous hue–saturation
// wash for the space on screen. The wash sits on Look — it never replaces it.
// Opened from the space menu as Theme…; mac-native materials and SF Symbols.

/// Continuous RGB for a space's chrome tint (0…1 each). Named presets resolve
/// to these values; the colour wheel writes them directly.
struct SpaceTint: Equatable, Hashable, Codable {
    var red: Double
    var green: Double
    var blue: Double

    init(red: Double, green: Double, blue: Double) {
        self.red = Self.clamp(red)
        self.green = Self.clamp(green)
        self.blue = Self.clamp(blue)
    }

    init(rgb: (CGFloat, CGFloat, CGFloat)) {
        self.init(red: Double(rgb.0), green: Double(rgb.1), blue: Double(rgb.2))
    }

    static func hsb(_ h: Double, _ s: Double, _ b: Double) -> SpaceTint {
        let hue = ((h.truncatingRemainder(dividingBy: 1)) + 1).truncatingRemainder(dividingBy: 1)
        let sat = clamp(s)
        let bri = clamp(b)
        let i = floor(hue * 6)
        let f = hue * 6 - i
        let p = bri * (1 - sat)
        let q = bri * (1 - f * sat)
        let t = bri * (1 - (1 - f) * sat)
        switch Int(i) % 6 {
        case 0: return SpaceTint(red: bri, green: t, blue: p)
        case 1: return SpaceTint(red: q, green: bri, blue: p)
        case 2: return SpaceTint(red: p, green: bri, blue: t)
        case 3: return SpaceTint(red: p, green: q, blue: bri)
        case 4: return SpaceTint(red: t, green: p, blue: bri)
        default: return SpaceTint(red: bri, green: p, blue: q)
        }
    }

    var hsb: (h: Double, s: Double, b: Double) {
        let r = red, g = green, b = blue
        let maxC = max(r, g, b)
        let minC = min(r, g, b)
        let delta = maxC - minC
        var h: Double = 0
        if delta > 0.000_01 {
            if maxC == r { h = ((g - b) / delta).truncatingRemainder(dividingBy: 6) }
            else if maxC == g { h = (b - r) / delta + 2 }
            else { h = (r - g) / delta + 4 }
            h /= 6
            if h < 0 { h += 1 }
        }
        let s = maxC <= 0.000_01 ? 0 : delta / maxC
        return (h, s, maxC)
    }

    /// Quiet greys wash softer; saturated colours a touch more present.
    var vivid: Bool { hsb.s > 0.22 }

    var color: Color { Color(red: red, green: green, blue: blue) }

    var nsColor: NSColor {
        NSColor(srgbRed: red, green: green, blue: blue, alpha: 1)
    }

    private static func clamp(_ v: Double) -> Double { min(1, max(0, v)) }
}

// MARK: - panel

@MainActor
enum ThemePickerPanel {
    private static var panel: Panel?
    private static var resign: Any?
    private static var clicks: Any?
    private static var keys: Any?

    static var isShown: Bool { panel != nil }

    static func show(for browser: Browser) {
        hide()
        let root = ThemePicker(browser: browser)
        let host = NSHostingView(rootView: root)
        let size = NSSize(width: 292, height: 368)
        host.frame = NSRect(origin: .zero, size: size)

        let glass = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
        glass.material = .popover
        glass.state = .active
        glass.blendingMode = .behindWindow
        glass.wantsLayer = true
        glass.layer?.cornerRadius = 16
        glass.layer?.cornerCurve = .continuous
        glass.layer?.masksToBounds = true
        host.autoresizingMask = [.width, .height]
        glass.addSubview(host)

        let panel = Panel(contentRect: NSRect(origin: .zero, size: size),
                          styleMask: [.borderless, .nonactivatingPanel],
                          backing: .buffered, defer: false)
        panel.contentView = glass
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.collectionBehavior = [.transient, .moveToActiveSpace]
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = true

        place(panel, size: size)
        panel.orderFront(nil)
        self.panel = panel

        resign = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { hide() }
        }
        clicks = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { event in
            MainActor.assumeIsolated {
                guard let panel = self.panel else { return }
                let spot = panel.convertPoint(fromScreen: NSEvent.mouseLocation)
                if !panel.contentView!.bounds.contains(spot) { hide() }
            }
            return event
        }
        keys = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 { // Escape
                MainActor.assumeIsolated { hide() }
                return nil
            }
            return event
        }
    }

    static func hide() {
        if let resign {
            NotificationCenter.default.removeObserver(resign)
            self.resign = nil
        }
        if let clicks {
            NSEvent.removeMonitor(clicks)
            self.clicks = nil
        }
        if let keys {
            NSEvent.removeMonitor(keys)
            self.keys = nil
        }
        panel?.orderOut(nil)
        panel = nil
    }

    private static func place(_ panel: NSPanel, size: NSSize) {
        let mouse = NSEvent.mouseLocation
        var origin = NSPoint(x: mouse.x - size.width / 2, y: mouse.y - size.height - 12)
        if let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) ?? NSScreen.main {
            let pad: CGFloat = 10
            let visible = screen.visibleFrame
            origin.x = min(max(origin.x, visible.minX + pad), visible.maxX - size.width - pad)
            origin.y = min(max(origin.y, visible.minY + pad), visible.maxY - size.height - pad)
        }
        panel.setFrameOrigin(origin)
    }

    private final class Panel: NSPanel {
        override var canBecomeKey: Bool { true }
        override var canBecomeMain: Bool { false }
    }
}

// MARK: - view

struct ThemePicker: View {
    @ObservedObject var browser: Browser

    @State private var hue: Double = 0.08
    @State private var sat: Double = 0.75
    @State private var bri: Double = 0.92
    @State private var dragging = false

    private var look: Binding<Look> {
        Binding(get: { browser.prefs.look }, set: { browser.prefs.look = $0 })
    }

    var body: some View {
        VStack(spacing: 14) {
            appearanceRow
            plane
            swatches
            Text("Tint washes the chrome — Look stays light, dark, or system.")
                .font(.system(size: 10.5))
                .foregroundStyle(Palette.muted)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
        }
        .padding(16)
        .frame(width: 292, height: 368)
        .onAppear { syncFromSpace() }
        .onChange(of: browser.spaceID) { _, _ in syncFromSpace() }
        .onChange(of: browser.space.wash) { _, _ in
            guard !dragging else { return }
            syncFromSpace()
        }
    }

    // MARK: Look

    private var appearanceRow: some View {
        HStack(spacing: 4) {
            ForEach(Look.allCases) { mode in
                Button {
                    withAnimation(Motion.quick) { look.wrappedValue = mode }
                } label: {
                    Image(systemName: mode.symbol)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(look.wrappedValue == mode ? Palette.ink : Palette.muted)
                        .frame(width: 36, height: 28)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(look.wrappedValue == mode ? Palette.wash : .clear)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(mode.title)
            }
        }
        .padding(3)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Palette.hairline.opacity(0.55))
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Appearance")
    }

    // MARK: hue–sat plane + brightness

    private var plane: some View {
        HStack(spacing: 10) {
            HueSatPlane(hue: $hue, sat: $sat, brightness: bri) {
                dragging = true
                commitWheel(persist: false)
            } onEnded: {
                dragging = false
                commitWheel(persist: true)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Palette.hairline.opacity(0.7), lineWidth: 1)
            )

            BrightnessStrip(hue: hue, sat: sat, brightness: $bri) {
                dragging = true
                commitWheel(persist: false)
            } onEnded: {
                dragging = false
                commitWheel(persist: true)
            }
            .frame(width: 18)
            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(Palette.hairline.opacity(0.7), lineWidth: 1)
            )
        }
        .frame(height: 196)
    }

    // MARK: presets

    private var swatches: some View {
        HStack(spacing: 8) {
            ForEach(Array(Spaces.colourRGB.enumerated()), id: \.offset) { index, rgb in
                let tint = SpaceTint(rgb: rgb)
                let selected = browser.space.tint == nil
                    && Spaces.colourIndex(browser.space.colour) == index
                Button {
                    browser.setSpaceColour(browser.spaceID, to: index)
                    syncFromSpace()
                } label: {
                    Circle()
                        .fill(tint.color)
                        .frame(width: 22, height: 22)
                        .overlay(
                            Circle()
                                .strokeBorder(Color.white.opacity(selected ? 0.95 : 0.35), lineWidth: selected ? 2.5 : 1)
                        )
                        .shadow(color: .black.opacity(0.18), radius: selected ? 2 : 0, y: 0.5)
                }
                .buttonStyle(.plain)
                .help(Spaces.colourNames[index])
                .accessibilityLabel(Spaces.colourNames[index])
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func syncFromSpace() {
        let wash = browser.space.wash
        let hsb = wash.hsb
        hue = hsb.h
        sat = max(hsb.s, 0.02)
        bri = max(hsb.b, 0.15)
    }

    private func commitWheel(persist: Bool = true) {
        let tint = SpaceTint.hsb(hue, sat, bri)
        browser.setSpaceTint(browser.spaceID, to: tint, persist: persist)
    }
}

// MARK: - Look symbols

extension Look {
    var symbol: String {
        switch self {
        case .system: return "circle.lefthalf.filled"
        case .light: return "sun.max"
        case .dark: return "moon"
        }
    }
}

// MARK: - plane

private struct HueSatPlane: View {
    @Binding var hue: Double
    @Binding var sat: Double
    var brightness: Double
    var onChanged: () -> Void
    var onEnded: () -> Void

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Canvas { context, size in
                    let steps = 48
                    for x in 0..<steps {
                        for y in 0..<steps {
                            let h = Double(x) / Double(steps - 1)
                            let s = 1 - Double(y) / Double(steps - 1)
                            let color = SpaceTint.hsb(h, s, brightness).color
                            let rect = CGRect(
                                x: CGFloat(x) / CGFloat(steps) * size.width,
                                y: CGFloat(y) / CGFloat(steps) * size.height,
                                width: size.width / CGFloat(steps) + 0.5,
                                height: size.height / CGFloat(steps) + 0.5
                            )
                            context.fill(Path(rect), with: .color(color))
                        }
                    }
                    // Soft vignette so the thumb reads on every hue.
                    context.fill(
                        Path(CGRect(origin: .zero, size: size)),
                        with: .color(.black.opacity(0.06))
                    )
                }
                .allowsHitTesting(false)

                Circle()
                    .fill(SpaceTint.hsb(hue, sat, brightness).color)
                    .frame(width: 22, height: 22)
                    .overlay(Circle().strokeBorder(.white, lineWidth: 3))
                    .shadow(color: .black.opacity(0.35), radius: 3, y: 1)
                    .position(
                        x: CGFloat(hue) * geo.size.width,
                        y: CGFloat(1 - sat) * geo.size.height
                    )
                    .allowsHitTesting(false)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        hue = min(1, max(0, value.location.x / max(geo.size.width, 1)))
                        sat = min(1, max(0, 1 - value.location.y / max(geo.size.height, 1)))
                        onChanged()
                    }
                    .onEnded { _ in onEnded() }
            )
        }
    }
}

private struct BrightnessStrip: View {
    var hue: Double
    var sat: Double
    @Binding var brightness: Double
    var onChanged: () -> Void
    var onEnded: () -> Void

    var body: some View {
        GeometryReader { geo in
            ZStack {
                LinearGradient(
                    colors: [
                        SpaceTint.hsb(hue, sat, 1).color,
                        SpaceTint.hsb(hue, sat, 0).color,
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .allowsHitTesting(false)

                Capsule()
                    .fill(.white)
                    .frame(width: 14, height: 6)
                    .shadow(color: .black.opacity(0.25), radius: 1, y: 0.5)
                    .position(x: geo.size.width / 2, y: CGFloat(1 - brightness) * geo.size.height)
                    .allowsHitTesting(false)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        brightness = min(1, max(0.08, 1 - value.location.y / max(geo.size.height, 1)))
                        onChanged()
                    }
                    .onEnded { _ in onEnded() }
            )
        }
    }
}
