import AppKit
import WebKit

// 🖥 "กดดูง่าย" (Nat 2026-07-15) — the fleet's ONE web face in a real window,
// openable from the tray menu. Same routing as the :8900 signpost page:
// census local when it answers, the configured WA_CENSUS_URL when it doesn't.
final class DashboardWindowController: NSObject, WKNavigationDelegate {
    static let shared = DashboardWindowController()

    private static let localProbe = "http://127.0.0.1:8899/api/state"
    private static let localURL = "http://127.0.0.1:8899/"
    // Fallback when the companion census app is not answering. Defaults to this
    // machine's own UI; set WA_CENSUS_URL to point at a companion instead. It
    // used to hardcode one specific external dashboard, which sent every other
    // user to a site about somebody else's fleet.
    private static let publicURL = ProcessInfo.processInfo.environment["WA_CENSUS_URL"]
        ?? "http://127.0.0.1:8900/legacy"

    private var window: NSWindow?
    private let web = WKWebView(frame: .zero)

    func show() {
        if window == nil {
            let w = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 1280, height: 860),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered, defer: false
            )
            w.title = "Oracle Display 🎭"
            w.minSize = NSSize(width: 640, height: 480)
            w.isReleasedWhenClosed = false // controller owns it; reopen must work
            w.setFrameAutosaveName("OracleDisplayWindow")
            web.navigationDelegate = self
            w.contentView = web
            w.center()
            window = w
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        loadBestURL()
    }

    private func loadBestURL() {
        let req = URLRequest(url: URL(string: Self.localProbe)!, timeoutInterval: 1.2)
        URLSession.shared.dataTask(with: req) { [weak self] _, resp, err in
            let ok = err == nil && (resp as? HTTPURLResponse)?.statusCode == 200
            let target = ok ? Self.localURL : Self.publicURL
            DispatchQueue.main.async {
                self?.web.load(URLRequest(url: URL(string: target)!))
            }
        }.resume()
    }

    // A dead local census mid-session shouldn't strand the window on an error
    // page — fall over to the public URL.
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        if webView.url?.absoluteString.hasPrefix("http://127.0.0.1") == true {
            webView.load(URLRequest(url: URL(string: Self.publicURL)!))
        }
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        self.webView(webView, didFail: navigation, withError: error)
    }
}
