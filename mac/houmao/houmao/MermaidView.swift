import SwiftUI
import WebKit

/// Read-only Mermaid renderer: a `WKWebView` that inlines the app-bundled
/// mermaid.js and renders the given diagram source. Used by the goal detail —
/// the document's ```mermaid block visualized. No interactivity: editing goes
/// through the document-bound chat, which rewrites the source.
struct MermaidView: NSViewRepresentable {
    let code: String

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        WKWebView()
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        // Reload only when the diagram actually changes — SwiftUI may call this on
        // unrelated parent updates, and reloading the ~3MB inlined page is costly.
        guard context.coordinator.lastCode != code else { return }
        context.coordinator.lastCode = code
        webView.loadHTMLString(Self.html(for: code), baseURL: nil)
    }

    final class Coordinator {
        var lastCode: String?
    }

    /// mermaid.js is a ~3MB bundled resource; read once and inline into the page
    /// so there is no file-URL subresource loading to worry about.
    private static let mermaidJS: String = {
        guard let url = Bundle.main.url(forResource: "mermaid.min", withExtension: "js"),
              let js = try? String(contentsOf: url, encoding: .utf8) else { return "" }
        return js
    }()

    private static func html(for code: String) -> String {
        let escaped = code
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
        return """
        <!DOCTYPE html>
        <html><head><meta charset="utf-8">
        <style>
          html, body { margin: 0; padding: 16px; font-family: -apple-system, system-ui, sans-serif; }
          #d { display: flex; justify-content: center; }
          .err { color: #b00020; font: 12px ui-monospace, monospace; white-space: pre-wrap; }
        </style></head>
        <body>
          <div id="d"><pre class="mermaid">\(escaped)</pre></div>
          <script>\(mermaidJS)</script>
          <script>
            try {
              mermaid.initialize({ startOnLoad: false, securityLevel: 'loose', theme: 'default' });
              mermaid.run();
            } catch (e) {
              document.getElementById('d').innerHTML =
                '<div class="err">' + (e && e.message ? e.message : 'render error') + '</div>';
            }
          </script>
        </body></html>
        """
    }
}
