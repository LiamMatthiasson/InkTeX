// The note typeset as one document with KaTeX, in a small web view.

import SwiftUI
import WebKit

struct LatexView: UIViewRepresentable {
    var blocks: [DocBlock]

    func makeUIView(context: Context) -> WKWebView {
        let webView = WKWebView()
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        guard context.coordinator.shown != blocks else { return }
        context.coordinator.shown = blocks
        webView.loadHTMLString(Self.page(for: blocks), baseURL: nil)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var shown: [DocBlock]? = nil
    }

    static func page(for blocks: [DocBlock]) -> String {
        // ["d", latex] or ["p", "text", words, "math", latex, …]
        let encoded: [[String]] = blocks.map { block in
            switch block {
            case .display(let latex):
                ["d", latex]
            case .paragraph(let parts):
                ["p"] + parts.flatMap { part -> [String] in
                    switch part {
                    case .text(let text): ["text", text]
                    case .math(let latex): ["math", latex]
                    }
                }
            }
        }
        let data = (try? JSONEncoder().encode(encoded)) ?? Data("[]".utf8)
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
            body { margin: 0; padding: 22px 26px; background: transparent; color: #1C2B22;
                   font: 19px/1.6 KaTeX_Main, "Times New Roman", serif; }
            p { margin: 0 0 14px; }
            .display { margin: 12px 0 18px; }
            .katex-display { margin: 0; }
            .empty { color: #66746B; font: 16px -apple-system, sans-serif; }
          </style>
        </head>
        <body>
          <div id="doc"></div>
          <script>
            const blocks = \(jsString);
            const doc = document.getElementById('doc');
            if (blocks.length === 0) {
              doc.textContent = 'Write something on the paper.';
              doc.className = 'empty';
            }
            function math(latex, el, display) {
              try {
                katex.render(latex, el, { throwOnError: false, displayMode: display });
              } catch (e) {
                el.textContent = display ? latex : '$' + latex + '$';   // KaTeX didn't load (offline?)
              }
            }
            for (const block of blocks) {
              if (block[0] === 'd') {
                const el = document.createElement('div');
                el.className = 'display';
                doc.appendChild(el);
                math(block[1], el, true);
                continue;
              }
              const p = document.createElement('p');
              doc.appendChild(p);
              for (let i = 1; i < block.length; i += 2) {
                if (i > 1) p.appendChild(document.createTextNode(' '));
                if (block[i] === 'text') {
                  p.appendChild(document.createTextNode(block[i + 1]));
                } else {
                  const span = document.createElement('span');
                  p.appendChild(span);
                  math(block[i + 1], span, false);
                }
              }
            }
          </script>
        </body>
        </html>
        """
    }
}
