// WindowArranger.app — the "กดดูง่าย" viewer (Nat 2026-07-15).
// One job: open the fleet's single web face in a real Mac window.
// Same routing as the :8900 signpost page: census local when it answers,
// the configured WA_CENSUS_URL when it doesn't. No Accessibility, no yabai,
// no state — the menubar app + server keep doing the real work.
import AppKit
import WebKit

let LOCAL_PROBE = "http://127.0.0.1:8899/api/state"
let LOCAL_URL = "http://127.0.0.1:8899/"
// Fallback when the companion census app is not answering. Defaults to this
// machine's own UI; set WA_CENSUS_URL to point at a companion instead.
let PUBLIC_URL = ProcessInfo.processInfo.environment["WA_CENSUS_URL"]
    ?? "http://127.0.0.1:8900/legacy"

final class ViewerDelegate: NSObject, NSApplicationDelegate, WKNavigationDelegate {
    var window: NSWindow!
    let web = WKWebView(frame: .zero)

    func applicationDidFinishLaunching(_ note: Notification) {
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1280, height: 860),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false
        )
        window.title = "Oracle Display 🎭"
        window.minSize = NSSize(width: 640, height: 480)
        window.center()
        window.setFrameAutosaveName("WindowArrangerViewer")
        web.navigationDelegate = self
        window.contentView = web
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        loadBestURL()
    }

    func loadBestURL() {
        let req = URLRequest(url: URL(string: LOCAL_PROBE)!, timeoutInterval: 1.2)
        URLSession.shared.dataTask(with: req) { _, resp, err in
            let ok = err == nil && (resp as? HTTPURLResponse)?.statusCode == 200
            let target = ok ? LOCAL_URL : PUBLIC_URL
            DispatchQueue.main.async {
                self.web.load(URLRequest(url: URL(string: target)!))
            }
        }.resume()
    }

    // A dead local census mid-session (laptop moved off the LAN, service down)
    // shouldn't strand the window on an error page — fall over to the public URL.
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        if webView.url?.absoluteString.hasPrefix("http://127.0.0.1") == true {
            webView.load(URLRequest(url: URL(string: PUBLIC_URL)!))
        }
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        self.webView(webView, didFail: navigation, withError: error)
    }

    @objc func reload(_ sender: Any?) { loadBestURL() }

    func applicationShouldTerminateAfterLastWindowClosed(_ app: NSApplication) -> Bool { true }
}

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let delegate = ViewerDelegate()
app.delegate = delegate

// Minimal main menu so ⌘Q / ⌘W / ⌘R / copy-paste behave like a real app.
let main = NSMenu()
let appItem = NSMenuItem(); main.addItem(appItem)
let appMenu = NSMenu()
appMenu.addItem(NSMenuItem(title: "Reload", action: #selector(ViewerDelegate.reload(_:)), keyEquivalent: "r"))
appMenu.addItem(.separator())
appMenu.addItem(NSMenuItem(title: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w"))
appMenu.addItem(NSMenuItem(title: "Quit Oracle Display", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
appItem.submenu = appMenu
let editItem = NSMenuItem(); main.addItem(editItem)
let editMenu = NSMenu(title: "Edit")
editMenu.addItem(NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
editMenu.addItem(NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
editMenu.addItem(NSMenuItem(title: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))
editItem.submenu = editMenu
app.mainMenu = main

app.run()
