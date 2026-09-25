import SwiftUI

// Peek: a link's page in a panel over the one you are reading. Shift-click
// (when Settings says so), Option-click, force-press, or Peek in a tab's menu.
// Escape, a click beside the panel or its close puts it away; promote keeps
// the same tab — and the same WKWebView — as a full tab in the strip.
//
// The page is a Tab of its own, only not in the row until promoted. Promoting
// moves that Tab into the strip and hands its web view to the stage; nothing
// is loaded twice and the view is never recreated.

extension Browser {
    /// Option-click / force-press / menu — Peek from whatever tab is in front.
    func peek(_ url: URL) {
        guard let from = active else { return }
        peek(url, from: from)
    }

    /// Peek a link from a known tab (shift-click path).
    func peek(_ url: URL, from tab: Tab) {
        if let dying = peekTab {
            peekTab = nil
            peekLanding = false
            dying.peeking = false
            dying.close()
        }
        peekLanding = false
        let page = Tab(shy: tab.shy)
        prepare(page)
        page.peeking = true
        page.go(to: url)
        withAnimation(Motion.settle) { peekTab = page }
        Haptics.generic()
    }

    /// Peek the address a tab already holds (tab menu).
    func peek(_ tab: Tab) {
        guard let url = tab.pending ?? tab.address else { return }
        peek(url, from: active ?? tab)
    }

    /// Put away: the page goes with the panel, unless it was already kept.
    func closePeek() {
        guard let page = peekTab else { return }
        peekLanding = false
        let kept = tabs.contains { $0.id == page.id }
        withAnimation(Motion.quick) { peekTab = nil }
        page.peeking = false
        if !kept { page.close() }
    }

    /// Promote: expand into the stage, land a strip tab, reuse the web view.
    ///
    /// Order matters. Peek's StageView and the main StageView must never both
    /// claim the same WKWebView in one layout pass (that is the blank page).
    /// Insert first so the sidebar tab appears during the flight; drop the
    /// overlay next; on the following turn clear `peeking` and select so the
    /// stage takes the identical view — no reload, no new Tab.
    func keepPeek() {
        guard let page = peekTab, !peekLanding else { return }
        let here = tabs.firstIndex { $0.id == activeID }
        withAnimation(Motion.settle) { peekLanding = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.28) { [weak self] in
            guard let self, self.peekTab?.id == page.id else { return }
            let at = here.map { $0 + 1 } ?? self.tabs.count
            if !self.tabs.contains(where: { $0.id == page.id }) {
                self.insert(page, at: at)
            }
            // Release Peek's StageView first while the tab still says peeking,
            // so the main stage will not fight for the web view this turn.
            self.peekLanding = false
            self.peekTab = nil
            DispatchQueue.main.async {
                page.peeking = false
                if let web = page.built {
                    web.alphaValue = 1
                    web.needsDisplay = true
                }
                withAnimation(Motion.settle) { self.select(page) }
            }
        }
    }
}

/// The peek over the page: the page dimmed around it, and the panel.
struct PeekLayer: View {
    @ObservedObject var browser: Browser

    var body: some View {
        ZStack {
            // The dimming only fades. Grown and shrunk with the panel, its
            // edges travelled across the window as it came (Drice, 24 Sep 2026).
            if browser.peekTab != nil {
                Color.black.opacity(browser.peekLanding ? 0 : 0.22)
                    .contentShape(Rectangle())
                    .onTapGesture { browser.closePeek() }
                    .allowsHitTesting(!browser.peekLanding)
                    .transition(.opacity)
            }
            if let tab = browser.peekTab {
                PeekPanel(browser: browser, tab: tab)
                    .transition(.asymmetric(
                        insertion: .opacity.combined(with: .scale(scale: 0.97)),
                        removal: .opacity
                    ))
            }
        }
        .animation(Motion.settle, value: browser.peekLanding)
    }
}

/// The panel itself — Mac-native chrome inside the frame (not floating knobs).
struct PeekPanel: View {
    @ObservedObject var browser: Browser
    @ObservedObject var tab: Tab

    var body: some View {
        GeometryReader { geo in
            ZStack {
                panel
                    .frame(
                        width: geo.size.width * (browser.peekLanding ? 1 : 0.82),
                        height: geo.size.height * (browser.peekLanding ? 1 : 0.86)
                    )
                    // Promote → expand into the stage, not shrink toward the strip.
                    .scaleEffect(browser.peekLanding ? 1.02 : 1, anchor: .center)
                    .opacity(browser.peekLanding ? 0 : 1)
                    .allowsHitTesting(!browser.peekLanding)
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
    }

    /// Solid Look ground under the page, with a thin in-chrome control bar.
    private var panel: some View {
        let shape = RoundedRectangle(cornerRadius: browser.peekLanding ? 0 : 10, style: .continuous)
        return VStack(spacing: 0) {
            chrome
            Rectangle().fill(Palette.hairline).frame(height: 1)
            ZStack {
                // Opaque plate under the page even when WebKit holds the first
                // frame at alpha 0 — never see through to the dimmed tab.
                // Use WebStage directly (not Page): `tab.peeking` keeps the main
                // stage from claiming this same view while the overlay holds it.
                Palette.ground
                if browser.prefs.usesSpaces {
                    Spaces.chromeWash(browser.space.wash)
                        .allowsHitTesting(false)
                }
                WebStage(page: tab.isBlank ? nil : tab.web)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .clipShape(shape)
        .overlay(shape.strokeBorder(Palette.hairline, lineWidth: 1))
        .shadow(color: .black.opacity(browser.peekLanding ? 0.06 : 0.22), radius: browser.peekLanding ? 8 : 28, y: browser.peekLanding ? 2 : 10)
    }

    /// Traffic-light-ish controls inside the panel — close leading, promote trailing.
    private var chrome: some View {
        HStack(spacing: 10) {
            Button(action: { browser.closePeek() }) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Palette.ink.opacity(0.85))
                    .frame(width: 14, height: 14)
                    .background(Circle().fill(Color(nsColor: .systemRed).opacity(0.85)))
            }
            .buttonStyle(.plain)
            .help("Close (esc)")

            Text(tab.title.isEmpty ? (tab.address.map { Address.pretty($0) } ?? "Peek") : tab.title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Palette.ink)
                .lineLimit(1)

            Spacer(minLength: 8)

            if tab.loading {
                Ring()
            }

            Button(action: { browser.keepPeek() }) {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Palette.ink)
                    .frame(width: 28, height: 22)
                    .background(Palette.hover.opacity(0.9), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
            .buttonStyle(.plain)
            .help("Open as a tab")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Palette.ground)
        .opacity(browser.peekLanding ? 0 : 1)
    }
}
