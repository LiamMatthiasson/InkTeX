// Shows the document's lines as rendered math, one display equation per line, using
// KaTeX (the same library as the web version) inside a small embedded web view.

import SwiftUI
import WebKit

struct LatexView: UIViewRepresentable {
    var lines: [String]

    func makeUIView(context: Context) -> WKWebView {
        let webView = WKWebView()
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        // Only reload when the LaTeX actually changed
        guard context.coordinator.shown != lines else { return }
        context.coordinator.shown = lines
        webView.loadHTMLString(Self.page(for: lines), baseURL: nil)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var shown: [String]? = nil
    }

    /// A tiny web page that renders each line with KaTeX.
    static func page(for lines: [String]) -> String {
        // Turn the lines into a safe JavaScript array literal (handles quotes and backslashes)
        let data = (try? JSONEncoder().encode(lines)) ?? Data("[]".utf8)
        let jsString = String(decoding: data, as: UTF8.self)
            .replacingOccurrences(of: "</", with: "<\\/")   // can't end the <script> early

        return """
        <!DOCTYPE html>
        <html>
        <head>
          <meta name="viewport" content="width=device-width, initial-scale=1">
          <link rel="stylesheet" href="https://cdn.jsdelivr.net/npm/katex@0.16.11/dist/katex.min.css">
          <script src="https://cdn.jsdelivr.net/npm/katex@0.16.11/dist/katex.min.js"></script>
          <style>
            body { margin: 0; padding: 20px; background: transparent; color: #1F3A68;
                   font: 24px -apple-system, sans-serif; }
            .empty { color: #66746B; font-size: 16px; }
            .katex-display { margin: 0; text-align: left; }
            .line { padding: 6px 0; border-bottom: 1px solid #E3E8DB; }
          </style>
        </head>
        <body>
          <div id="math"></div>
          <script>
            const lines = \(jsString);
            const page = document.getElementById('math');
            if (lines.length === 0) {
              page.textContent = 'Write something on the paper.';
              page.className = 'empty';
            }
            for (const latex of lines) {
              const el = document.createElement('div');
              el.className = 'line';
              page.appendChild(el);
              try {
                katex.render(latex, el, { throwOnError: false, displayMode: true });
              } catch (e) {
                el.textContent = latex;   // KaTeX didn't load (offline?): show the code instead
              }
            }
          </script>
        </body>
        </html>
        """
    }
}
