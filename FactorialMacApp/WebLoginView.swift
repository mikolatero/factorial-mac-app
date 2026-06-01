import SwiftUI
import WebKit

struct WebLoginView: NSViewRepresentable {
    let webView: WKWebView

    func makeNSView(context: Context) -> WKWebView {
        webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {
        if nsView.url == nil {
            nsView.load(URLRequest(url: URL(string: "https://app.factorialhr.com")!))
        }
    }
}
