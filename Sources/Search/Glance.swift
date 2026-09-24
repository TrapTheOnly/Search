import SwiftUI
import WebKit

// A short-lived page over the one you are on. Option-click a link, or Glance
// in a tab's menu: one web view, gone when you close it, never written to
// the session. Only one at a time.

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

/// The glance itself: a card over the page, the same white and hairline as
/// every other thing that rises here, with the three ways out along the top.
struct GlanceCard: View {
    @ObservedObject var browser: Browser
    @ObservedObject var glance: Glance

    var body: some View {
        ZStack {
            Color.black.opacity(0.10)
                .ignoresSafeArea()
                .onTapGesture { browser.closeGlance() }

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

                Rectangle().fill(Palette.hairline).frame(height: 1)

                WebStage(page: glance.web)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(maxWidth: 820, maxHeight: 560)
            .background(Palette.ground, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(Palette.hairline, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .shadow(color: .black.opacity(0.16), radius: 34, y: 12)
            .padding(28)
            .transition(.scale(scale: 0.97).combined(with: .opacity))
        }
        .transition(.opacity)
    }
}
