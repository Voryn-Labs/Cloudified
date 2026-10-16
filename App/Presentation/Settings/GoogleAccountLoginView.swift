// MIT License
// Copyright (c) 2024 xob0t (PhotosBackup)
// Adapted from AccountConnectWebView.swift at the pinned PhotosBackup revision.
// See licenses/LICENSE-PhotosBackup.txt and dependencies/google-vendor.json.

#if os(iOS)
import SwiftUI
@preconcurrency import WebKit
import UIKit
import CloudifiedCore

/// Each presentation owns a fresh, memory-only browser session. No shared cookie import.
@MainActor
struct GoogleAccountLoginView: UIViewRepresentable {
    let active: Bool
    let onToken: (String) -> Void
    let onLoading: (Bool) -> Void
    let onFailure: (String, SafeFailure) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onToken: onToken, onLoading: onLoading, onFailure: onFailure)
    }
    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let view = WKWebView(frame: .zero, configuration: configuration)
        let version = UIDevice.current.systemVersion
        view.customUserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS \(version.replacingOccurrences(of: ".", with: "_")) like Mac OS X) " +
            "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/\(version) Mobile/15E148 Safari/604.1"
        view.navigationDelegate = context.coordinator
        view.allowsBackForwardNavigationGestures = true
        context.coordinator.attach(view, active: active)
        view.load(URLRequest(url: URL(string: "https://accounts.google.com/EmbeddedSetup")!))
        return view
    }
    func updateUIView(_ view: WKWebView, context: Context) { context.coordinator.setActive(active) }
    static func dismantleUIView(_ view: WKWebView, coordinator: Coordinator) {
        coordinator.stop()
        view.stopLoading(); view.navigationDelegate = nil
        // Clear only this new memory-only store, never Safari or another account's store.
        view.configuration.websiteDataStore.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(),
                                                      modifiedSince: .distantPast, completionHandler: {})
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate, WKHTTPCookieStoreObserver {
        private let onToken: (String) -> Void
        private let onLoading: (Bool) -> Void
        private let onFailure: (String, SafeFailure) -> Void
        private weak var view: WKWebView?
        private weak var store: WKHTTPCookieStore?
        private var timer: Timer?
        private var active = false
        private var stopped = false
        private var captured = false
        private var reading = false
        private let deadline = Date().addingTimeInterval(600)

        init(onToken: @escaping (String) -> Void, onLoading: @escaping (Bool) -> Void,
             onFailure: @escaping (String, SafeFailure) -> Void) {
            self.onToken = onToken; self.onLoading = onLoading; self.onFailure = onFailure
        }
        func attach(_ view: WKWebView, active: Bool) {
            self.view = view
            let store = view.configuration.websiteDataStore.httpCookieStore
            self.store = store; store.add(self)
            setActive(active)
        }
        func setActive(_ value: Bool) {
            active = value
            guard active, !stopped, !captured else { timer?.invalidate(); timer = nil; return }
            guard timer == nil else { return }
            // Upstream documents missed Set-Cookie observer callbacks. This bounded
            // foreground-only check supplements navigation/observer events; no busy loop.
            let timer = Timer(timeInterval: 0.75, repeats: true) { [weak self] _ in
                Task { @MainActor [weak self] in self?.checkCookie() }
            }
            RunLoop.main.add(timer, forMode: .common); self.timer = timer
        }
        func stop() {
            stopped = true; timer?.invalidate(); timer = nil
            store?.remove(self); store = nil
        }
        private func checkCookie() {
            guard !stopped, !captured, active, !reading else { return }
            guard Date() < deadline else {
                fail("Google sign-in timed out. Start a new sign-in session.", failure: SafeFailure(.timeout, domain: .google)); return
            }
            guard let store else { return }
            reading = true
            store.getAllCookies { [weak self] cookies in
                guard let self else { return }
                self.reading = false
                guard !self.stopped, !self.captured, self.active else { return }
                guard let cookie = cookies.first(where: {
                    $0.name == "oauth_token" && $0.domain.trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased() == "accounts.google.com" &&
                    $0.isSecure && !$0.value.isEmpty && $0.value.utf8.count <= 8192 && ($0.expiresDate == nil || $0.expiresDate! > Date())
                }) else { return }
                self.captured = true
                self.stop(); self.view?.stopLoading()
                // Only this credential reaches the existing verified exchange. Never log cookies/URLs.
                self.onToken(cookie.value)
            }
        }
        func cookiesDidChange(in cookieStore: WKHTTPCookieStore) { checkCookie() }
        func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) { onLoading(false); checkCookie() }
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { onLoading(false); checkCookie() }
        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) { onLoading(true) }
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { navigationFailed(error) }
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { navigationFailed(error) }
        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { fail("The Google sign-in page closed unexpectedly. Start again.") }
        private func navigationFailed(_ error: Error) {
            guard !stopped, !captured else { return }
            if (error as NSError).domain == NSURLErrorDomain && (error as NSError).code == NSURLErrorCancelled { return }
            let code = (error as NSError).code
            let isNetwork = (error as NSError).domain == NSURLErrorDomain
            let failure = isNetwork ? SafeFailure(code == NSURLErrorTimedOut ? .timeout : .connectivity,
                domain: .urlSession, code: code, cause: code == NSURLErrorNotConnectedToInternet ? .offline : .unknown) :
                SafeFailure(.authentication, domain: .google, code: code)
            fail("Could not load Google sign-in. Start again after checking the connection. Page error code: \(code).", failure: failure)
        }
        private func fail(_ message: String, failure: SafeFailure = SafeFailure(.authentication, domain: .google)) {
            guard !stopped, !captured else { return }
            stop(); view?.stopLoading(); onLoading(false); onFailure(message, failure)
        }
        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                     decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
            guard let url = action.request.url, url.scheme == "https", let host = url.host?.lowercased(),
                  ["google.com", "googleusercontent.com", "gstatic.com"].contains(where: { host == $0 || host.hasSuffix("." + $0) }) else {
                decisionHandler(.cancel)
                if action.targetFrame?.isMainFrame != false { fail("This sign-in requested an unsupported page. Cancel or start again; your account has not been linked by this page.") }
                return
            }
            // Keep sign-in in this isolated store, including a target=_blank continuation.
            if action.targetFrame == nil { decisionHandler(.cancel); webView.load(action.request); return }
            decisionHandler(.allow)
        }
    }
}
#endif
