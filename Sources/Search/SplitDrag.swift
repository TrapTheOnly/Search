import SwiftUI
import AppKit

// Zen-inspired *interaction* for splitting (see internal/zen-split-study.md):
// lift a tab into a mini-window, live half-zone under the pointer, commit on drop.
// Search chrome + space accent wash — not Zen’s floating orange cards.
//
// Ownership (Zen `_draggingTab`): the carried tab id is fixed for the whole
// gesture. Mate highlight / drop side update under the pointer; pane swap
// happens only on drop — never mid-hover. That killed Search’s “swap what’s
// in hand → thinner forever” rearrange bug.
//
// Carry state lives off Browser’s @Published surface so the tab strip does not
// redraw every pointer move.

/// Stage edge a lifted tab is over — drop opens/replaces that pane.
enum SplitEdge: Equatable {
    case leading, trailing, top, bottom

    var isHorizontal: Bool {
        switch self {
        case .leading, .trailing: return true
        case .top, .bottom: return false
        }
    }

    var alignment: Alignment {
        switch self {
        case .leading: return .leading
        case .trailing: return .trailing
        case .top: return .top
        case .bottom: return .bottom
        }
    }

    /// Mate half when rearranging inside an existing split.
    static func mate(of side: SplitEdge) -> SplitEdge {
        switch side {
        case .leading: return .trailing
        case .trailing: return .leading
        case .top: return .bottom
        case .bottom: return .top
        }
    }
}

enum SplitAxis: Equatable {
    case horizontal, vertical
}

/// Why the tab is being carried — create a split vs rearrange within one.
enum SplitCarryKind: Equatable {
    case create
    /// Dragging one split member; drop on the other half swaps once.
    case rearrange(from: SplitEdge)
}

/// Pointer-driven split drag — observed only by the stage overlay / mini-window.
@MainActor
final class SplitCarry: ObservableObject {
    @Published var tabID: Tab.ID?
    /// True once the tab has left the strip and become a mini-window.
    @Published var lifted = false
    /// Cursor in the stage overlay's local space (top-leading origin).
    @Published var point: CGPoint = .zero
    @Published var edge: SplitEdge?
    @Published var kind: SplitCarryKind = .create
    /// Stage size for side hit-testing (updated by the overlay).
    var stageSize: CGSize = .zero

    private var lastEdge: SplitEdge?

    var isRearranging: Bool {
        if case .rearrange = kind { return true }
        return false
    }

    func begin(_ id: Tab.ID, kind: SplitCarryKind = .create) {
        tabID = id
        lifted = false
        edge = nil
        lastEdge = nil
        self.kind = kind
    }

    /// Start a within-split rearrange: identity fixed, mini follows pointer.
    func beginRearrange(_ id: Tab.ID, from side: SplitEdge, at point: CGPoint) {
        tabID = id
        kind = .rearrange(from: side)
        lifted = true
        self.point = point
        lastEdge = nil
        edge = nil
        refreshEdge()
        Haptics.align()
    }

    func lift(at point: CGPoint) {
        if !lifted {
            lifted = true
            Haptics.align()
        }
        self.point = point
        refreshEdge()
    }

    func move(at point: CGPoint) {
        self.point = point
        if lifted { refreshEdge() }
    }

    func clear() {
        tabID = nil
        lifted = false
        edge = nil
        lastEdge = nil
        kind = .create
        point = .zero
    }

    /// Pointer-side half: pick the dominant axis from center, keep one edge
    /// with hysteresis so rearrange / hover near mid does not thrash.
    private func refreshEdge() {
        let size = stageSize
        guard size.width > 1, size.height > 1 else {
            edge = nil
            return
        }

        if case .rearrange(let from) = kind {
            // Zen center-vs-side: only highlight the mate half when clearly over it.
            let overMate = isOverMateHalf(from: from, size: size)
            let mate = SplitEdge.mate(of: from)
            let next: SplitEdge? = overMate ? mate : nil
            if next != lastEdge {
                if next != nil { Haptics.level() }
                lastEdge = next
            }
            edge = next
            return
        }

        let nx = point.x / size.width
        let ny = point.y / size.height
        let dx = nx - 0.5
        let dy = ny - 0.5
        let dead = Metrics.splitHysteresis

        let raw: SplitEdge = abs(dx) >= abs(dy)
            ? (dx < 0 ? .leading : .trailing)
            : (dy < 0 ? .top : .bottom)

        let next: SplitEdge
        if let current = lastEdge, current != raw {
            let committed: Bool = {
                switch raw {
                case .leading: return nx < 0.5 - dead
                case .trailing: return nx > 0.5 + dead
                case .top: return ny < 0.5 - dead
                case .bottom: return ny > 0.5 + dead
                }
            }()
            let axisClear: Bool = {
                switch raw {
                case .leading, .trailing: return abs(dx) > abs(dy) + dead * 0.5
                case .top, .bottom: return abs(dy) > abs(dx) + dead * 0.5
                }
            }()
            next = (committed && axisClear) ? raw : current
        } else {
            next = raw
        }

        if next != lastEdge {
            Haptics.level()
            lastEdge = next
        }
        edge = next
    }

    private func isOverMateHalf(from: SplitEdge, size: CGSize) -> Bool {
        let dead = Metrics.splitHysteresis
        let nx = point.x / size.width
        let ny = point.y / size.height
        switch from {
        case .leading: return nx > 0.5 + dead
        case .trailing: return nx < 0.5 - dead
        case .top: return ny > 0.5 + dead
        case .bottom: return ny < 0.5 - dead
        }
    }
}

/// One dynamic half-stage drop zone + mini-window while a tab is lifted.
struct SplitDragOverlay: View {
    @ObservedObject var browser: Browser
    @ObservedObject var carry: SplitCarry

    private var tint: SpaceTint {
        browser.prefs.usesSpaces ? browser.space.wash : SpaceTint(rgb: Spaces.colourRGB[0])
    }

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            ZStack {
                if carry.lifted, let edge = carry.edge {
                    halfZone(edge: edge, size: size)
                        .transition(.opacity)
                }
                if carry.lifted, let id = carry.tabID, let tab = browser.find(id) {
                    SplitMiniWindow(tab: tab, edge: carry.edge, tint: tint)
                        .position(carry.point)
                        .transition(.scale(scale: 0.92).combined(with: .opacity))
                        .zIndex(20)
                }
            }
            .frame(width: size.width, height: size.height)
            .onAppear { carry.stageSize = size }
            .onChange(of: size) { _, new in carry.stageSize = new }
            .background(SplitCarryProbe(carry: carry, browser: browser))
            .animation(Motion.settle, value: carry.lifted)
            .animation(Motion.quick, value: carry.edge)
        }
        .allowsHitTesting(false)
    }

    /// ~50% of the stage on the active side — Zen half inset, Search accent wash.
    private func halfZone(edge: SplitEdge, size: CGSize) -> some View {
        let inset: CGFloat = 8
        let w = edge.isHorizontal ? size.width * 0.5 - inset * 1.5 : size.width - inset * 2
        let h = edge.isHorizontal ? size.height - inset * 2 : size.height * 0.5 - inset * 1.5
        return RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(Spaces.splitAccent(tint, alpha: 0.28))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Spaces.splitAccent(tint, alpha: 0.55), lineWidth: 1.5)
            )
            .frame(width: max(0, w), height: max(0, h))
            .padding(inset)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: edge.alignment)
            .animation(Motion.quick, value: edge)
    }
}

/// Compact Search-chrome preview that follows the pointer (Zen interaction, not Zen look).
struct SplitMiniWindow: View {
    @ObservedObject var tab: Tab
    var edge: SplitEdge?
    var tint: SpaceTint

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Mark(icon: tab.icon, letter: tab.monogram, size: 14)
                Text(tab.label)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Palette.ink)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .frame(height: 28)
            .background {
                ZStack {
                    Palette.wash
                    Spaces.splitHeaderWash(tint, focused: true)
                }
            }

            ZStack {
                Palette.ground
                if let host = (tab.address ?? tab.pending).flatMap({ Address.pretty($0) }) {
                    Text(host)
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.muted)
                        .padding(12)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: Metrics.splitMini.width, height: Metrics.splitMini.height)
        .background(Palette.ground, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Spaces.splitAccent(tint, alpha: edge == nil ? 0.25 : 0.55), lineWidth: 1)
        )
        .shadow(color: .black.opacity(edge == nil ? 0.18 : 0.26), radius: edge == nil ? 16 : 22, y: 8)
        .scaleEffect(edge == nil ? 1 : 1.03)
        .animation(Motion.quick, value: edge)
    }
}

/// Tracks the pointer while a tab is carried / lifted (does not republish Browser).
private struct SplitCarryProbe: NSViewRepresentable {
    @ObservedObject var carry: SplitCarry
    var browser: Browser

    func makeNSView(context: Context) -> ProbeView {
        let view = ProbeView()
        view.carry = carry
        view.browser = browser
        return view
    }

    func updateNSView(_ view: ProbeView, context: Context) {
        view.carry = carry
        view.browser = browser
    }

    final class ProbeView: NSView {
        weak var carry: SplitCarry?
        weak var browser: Browser?
        private var monitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window != nil { start() } else { stop() }
        }

        private func start() {
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDragged, .leftMouseUp]) { [weak self] event in
                self?.track(event)
                return event
            }
        }

        private func stop() {
            if let monitor {
                NSEvent.removeMonitor(monitor)
                self.monitor = nil
            }
        }

        private func track(_ event: NSEvent) {
            guard let carry, carry.tabID != nil, let window else { return }
            let local = convert(event.locationInWindow, from: nil)
            // AppKit Y is bottom-up; SwiftUI GeometryReader is top-down.
            let point = CGPoint(x: local.x, y: bounds.height - local.y)
            if carry.lifted {
                carry.move(at: point)
            } else {
                carry.point = point
            }
            _ = window
            if event.type == .leftMouseUp, carry.lifted {
                browser?.finishCarry()
            }
        }

        deinit { stop() }
    }
}
