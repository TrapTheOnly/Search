import SwiftUI
import AppKit

// Zen-like *interaction* for splitting: lift a tab into a mini-window, drag it
// across the stage, snap to an edge, drop. Search chrome (Look wash, no orange
// floating cards). Carry state lives off Browser's @Published surface so the
// tab strip does not redraw every pointer move (that was the flicker/overlap).

/// Stage edge a lifted tab is over — drop opens/replaces that pane.
enum SplitEdge: Equatable {
    case leading, trailing, top, bottom

    var isHorizontal: Bool {
        switch self {
        case .leading, .trailing: return true
        case .top, .bottom: return false
        }
    }
}

enum SplitAxis: Equatable {
    case horizontal, vertical
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
    /// Stage size for edge hit-testing (updated by the overlay).
    var stageSize: CGSize = .zero

    private var lastEdge: SplitEdge?

    func begin(_ id: Tab.ID) {
        tabID = id
        lifted = false
        edge = nil
        lastEdge = nil
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
        point = .zero
    }

    private func refreshEdge() {
        let size = stageSize
        guard size.width > 1, size.height > 1 else {
            edge = nil
            return
        }
        let zone = Metrics.splitEdge
        let x = point.x
        let y = point.y
        // Prefer the nearer edge when near a corner.
        let distL = x
        let distR = size.width - x
        let distT = y
        let distB = size.height - y
        let nearest = min(distL, distR, distT, distB)
        let next: SplitEdge?
        if nearest > zone {
            next = nil
        } else if nearest == distL {
            next = .leading
        } else if nearest == distR {
            next = .trailing
        } else if nearest == distT {
            next = .top
        } else {
            next = .bottom
        }
        if next != lastEdge {
            if next != nil { Haptics.level() }
            lastEdge = next
        }
        edge = next
    }
}

/// Four-edge drop zones + mini-window while a tab is lifted.
struct SplitDragOverlay: View {
    @ObservedObject var browser: Browser
    @ObservedObject var carry: SplitCarry

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            ZStack {
                if carry.tabID != nil {
                    edgeBands(size: size)
                }
                if carry.lifted, let id = carry.tabID, let tab = browser.find(id) {
                    SplitMiniWindow(tab: tab, edge: carry.edge)
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

    private func edgeBands(size: CGSize) -> some View {
        let zone = Metrics.splitEdge
        return ZStack {
            band(active: carry.edge == .leading)
                .frame(width: zone, height: size.height)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            band(active: carry.edge == .trailing)
                .frame(width: zone, height: size.height)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
            band(active: carry.edge == .top)
                .frame(width: size.width, height: zone)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            band(active: carry.edge == .bottom)
                .frame(width: size.width, height: zone)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        }
        .opacity(carry.lifted ? 1 : 0.35)
    }

    private func band(active: Bool) -> some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(Palette.ink.opacity(active ? 0.12 : 0.04))
            .padding(5)
            .overlay {
                if active {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Palette.ink.opacity(0.18), lineWidth: 1)
                        .padding(5)
                }
            }
    }
}

/// Compact Search-chrome preview that follows the pointer (Zen interaction, not Zen look).
struct SplitMiniWindow: View {
    @ObservedObject var tab: Tab
    var edge: SplitEdge?

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
            .background(Palette.wash)

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
                .strokeBorder(Palette.hairline, lineWidth: 1)
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
