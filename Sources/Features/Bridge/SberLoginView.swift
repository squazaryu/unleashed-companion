import SwiftUI
import WebKit

/// In-app Sber login. Loads Sber's official OAuth page in a WKWebView (with the
/// Russian Trusted CA injected so it loads even without the device profile),
/// captures the `companionapp://host?code=…` redirect, and exchanges the code for
/// tokens. Credentials are entered only on Sber's page; the app reads just the
/// redirect URL.
struct SberLoginView: View {
    var onResult: (Bool) -> Void          // true = token saved
    @Environment(\.dismiss) private var dismiss
    @State private var status = "Opening Sber login…"
    @State private var exchanging = false
    private let auth = SberCloudClient.makeAuthSession()

    var body: some View {
        NavigationStack {
            ZStack {
                SberAuthWebView(session: auth, onCode: handleCode, onError: handleError)
                if exchanging {
                    Color(.systemBackground).opacity(0.85).ignoresSafeArea()
                    VStack(spacing: 10) { ProgressView(); Text(status) }
                }
            }
            .navigationTitle("Log in with Sber")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { onResult(false); dismiss() }
                }
            }
        }
        .interactiveDismissDisabled(exchanging)
    }

    private func handleCode(_ code: String) {
        exchanging = true; status = "Exchanging code for token…"
        Task {
            do {
                try await SberCloudClient.shared.completeLogin(code: code, verifier: auth.verifier)
                await MainActor.run { onResult(true); dismiss() }
            } catch {
                await MainActor.run { status = "Login failed: \(error.localizedDescription)"; exchanging = false }
            }
        }
    }

    private func handleError(_ message: String) {
        status = "Login error: \(message)"
    }
}

struct SberAuthWebView: UIViewRepresentable {
    let session: SberAuthSession
    var onCode: (String) -> Void
    var onError: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> WKWebView {
        let web = WKWebView(frame: .zero)
        web.navigationDelegate = context.coordinator
        web.load(URLRequest(url: session.url))
        return web
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKNavigationDelegate {
        let parent: SberAuthWebView
        private var handled = false
        init(_ parent: SberAuthWebView) { self.parent = parent }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            guard let url = navigationAction.request.url else { decisionHandler(.allow); return }
            if url.scheme == "companionapp" {
                decisionHandler(.cancel)
                guard !handled else { return }
                handled = true
                let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
                if let code = items?.first(where: { $0.name == "code" })?.value {
                    parent.onCode(code)
                } else if let err = items?.first(where: { $0.name == "error" })?.value {
                    parent.onError(err)
                } else {
                    parent.onError("no code in redirect")
                }
                return
            }
            decisionHandler(.allow)
        }

        // Trust Sber's Russian-CA hosts (system store doesn't).
        func webView(_ webView: WKWebView, didReceive challenge: URLAuthenticationChallenge,
                     completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
            let (disposition, credential) = SberTrustDelegate.resolve(challenge)
            completionHandler(disposition, credential)
        }
    }
}
