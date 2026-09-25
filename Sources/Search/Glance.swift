import SwiftUI
import WebKit

// A short-lived page over the one you are on. Option-click or force-press a
// link, or Glance in a tab's menu: one web view, gone when you close it, never
// written to the session. Only one at a time. Distinct from Peek (shift-click).

/// Where a glance is flying when Open or Split is pressed.
enum GlanceLanding: Equatable {
    case tab
    case split
}

@MainActor
final class Glance: NSObject, ObservableObject, WKNavigationDelegate, WKUIDelegate {
    let web: PageView
    @Published var title = ""
    @Published var address: URL?
    @Published var loading = false

    weak var browser: Browser?
    private var watch: [NSKeyValueObservation] = []

    init(url: URL, browser: Browser) {
        let view = PageView(frame: .zero, configuration: Web.configuration())
        view.allowsMagnification = true
        view.allowsBackForwardNavigationGestures = false
        // Keep force-press hit-testing on; PageView routes http(s) links to
        // Glance and suppresses WebKit's Quick Look / Reading List preview.
        view.allowsLinkPreview = true
        view.onForceLink = { [weak browser] url in browser?.glance(url) }
        view.holdForFirstFrame()
        if #available(macOS 13.3, *) { view.isInspectable = true }
        self.web = view
        self.browser = browser
        self.address = url
        super.init()
        view.navigationDelegate = self
        view.uiDelegate = self
        watch = [
            view.observe(\.title, options: [.new]) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.title = self?.web.title ?? "" }
            },
            view.observe(\.url, options: [.new]) { [weak self] _, _ in
                MainActor.assumeIsolated {
                    guard let fresh = self?.web.url, fresh.absoluteString != "about:blank" else { return }
                    self?.address = fresh
                }
            },
            view.observe(\.isLoading, options: [.new]) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.loading = self?.web.isLoading ?? false }
            },
        ]
        view.load(URLRequest(url: url))
    }

    /// The view and everything listening to it, gone. The next glance builds
    /// a fresh one.
    func discard() {
        watch = []
        browser = nil
        web.stopLoading()
        web.navigationDelegate = nil
        web.uiDelegate = nil
        web.removeFromSuperview()
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor action: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        guard let url = action.request.url, let scheme = url.scheme?.lowercased() else {
            decisionHandler(.allow)
            return
        }
        if action.navigationType == .linkActivated, ["http", "https"].contains(scheme) {
            let flags = action.modifierFlags
            if flags.contains(.command) || action.buttonNumber == 2 {
                browser?.open(url, foreground: flags.contains(.shift))
                decisionHandler(.cancel)
                return
            }
        }
        if ["http", "https", "about", "data", "blob"].contains(scheme) {
            decisionHandler(.allow)
        } else {
            NSWorkspace.shared.open(url)
            decisionHandler(.cancel)
        }
    }

    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for action: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        if let url = action.request.url { browser?.open(url, foreground: true) }
        return nil
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        (webView as? PageView)?.showFirstFrame()
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        (webView as? PageView)?.showFirstFrame()
    }
}

/// The glance itself: glass over the page, Look ground under the web view so
/// loading never flashes empty, with the three ways out along the top.
struct GlanceCard: View {
    @ObservedObject var browser: Browser
    @ObservedObject var glance: Glance

    private var landing: GlanceLanding? { browser.glanceLanding }

    var body: some View {
        ZStack {
            Color.black.opacity(landing == nil ? 0.10 : 0)
                .ignoresSafeArea()
                .onTapGesture { browser.closeGlance() }
                .allowsHitTesting(landing == nil)

            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Text(glance.title.isEmpty ? (glance.address.map { Address.pretty($0) } ?? "Glance") : glance.title)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Palette.ink)
                        .lineLimit(1)
                    if glance.loading { Ring() }
                    Spacer(minLength: 8)
                    Pill("Open") { browser.promoteGlance() }
                    Pill("Split") { browser.splitGlance() }
                    Door(icon: "xmark", help: "Close   esc") { browser.closeGlance() }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .opacity(landing == nil ? 1 : 0)

                Rectangle().fill(Palette.hairline).frame(height: 1)

                // Solid Look (and space wash) under the web view — glass chrome
                // around it, never a see-through hole while the first frame is held.
                ZStack {
                    Palette.ground
                    if browser.prefs.usesSpaces {
                        Spaces.chromeWash(browser.space.wash)
                    }
                    WebStage(page: glance.web)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(maxWidth: 820, maxHeight: 560)
            .background { glassChrome }
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(Palette.hairline.opacity(0.85), lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .shadow(color: .black.opacity(landing == nil ? 0.16 : 0.04), radius: landing == nil ? 34 : 10, y: landing == nil ? 12 : 4)
            .padding(28)
            .scaleEffect(landingScale, anchor: landingAnchor)
            .offset(y: landingOffset)
            .opacity(landing == nil ? 1 : 0)
            .allowsHitTesting(landing == nil)
            .transition(.asymmetric(
                insertion: .scale(scale: 0.96).combined(with: .opacity),
                removal: .scale(scale: 0.98).combined(with: .opacity)
            ))
        }
        .animation(Motion.settle, value: landing)
        .transition(.opacity)
    }

    /// Glass plate: opaque Look ground first, soft space wash, then a light
    /// material sheen so the card reads as glass without punching holes.
    private var glassChrome: some View {
        let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
        return ZStack {
            shape.fill(Palette.ground)
            if browser.prefs.usesSpaces {
                shape.fill(Spaces.chromeWash(browser.space.wash))
            }
            shape.fill(.ultraThinMaterial)
                .opacity(0.28)
        }
    }

    private var landingScale: CGFloat {
        switch landing {
        case .tab: return 0.12
        case .split: return 0.55
        case nil: return 1
        }
    }

    private var landingAnchor: UnitPoint {
        switch landing {
        case .tab: return .top
        case .split: return .trailing
        case nil: return .center
        }
    }

    private var landingOffset: CGFloat {
        switch landing {
        case .tab: return -120
        case .split: return 0
        case nil: return 0
        }
    }
}
