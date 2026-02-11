import SwiftUI
import WebKit
import Foundation

struct WebConsoleView: NSViewRepresentable {
    @ObservedObject var themeBinder: ThemeBinder
    let lines: [String]

    class Coordinator: NSObject, WKNavigationDelegate {
        var parent: WebConsoleView
        var lastLineCount: Int = 0
        var lastThemeKey: String = ""
        var isReady: Bool = false
        var didFailLoad: Bool = false
        var pendingLines: [String] = []
        var pendingThemeKey: String = ""

        init(parent: WebConsoleView) {
            self.parent = parent
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            isReady = true
            didFailLoad = false
            parent.updateThemeColors(in: webView)
            parent.setAllLines(pendingLines, in: webView)
            lastLineCount = pendingLines.count
            lastThemeKey = pendingThemeKey
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            didFailLoad = true
            isReady = false
            parent.loadFallback(into: webView, reason: "加载失败：\(error.localizedDescription)")
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            didFailLoad = true
            isReady = false
            parent.loadFallback(into: webView, reason: "初始化失败：\(error.localizedDescription)")
        }

        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            didFailLoad = true
            isReady = false
            parent.loadFallback(into: webView, reason: "Web 渲染进程已终止，正在恢复")
            parent.load(into: webView)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.preferences.javaScriptEnabled = true
        if #available(macOS 11.0, *) {
            config.defaultWebpagePreferences.allowsContentJavaScript = true
        }
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.setValue(false, forKey: "drawsBackground")
        webView.wantsLayer = true
        if let bg = nsColorFromTheme(token: themeBinder.resolvedColorToken("panel"), fallback: NSColor.windowBackgroundColor) {
            webView.layer?.backgroundColor = bg.cgColor
        }
        webView.navigationDelegate = context.coordinator
        loadFallback(into: webView, reason: "正在初始化 Web 控制台")
        load(into: webView)
        context.coordinator.lastLineCount = 0
        context.coordinator.lastThemeKey = themeSignature()
        context.coordinator.isReady = false
        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {
        context.coordinator.parent = self
        let signature = themeSignature()
        context.coordinator.pendingThemeKey = signature
        context.coordinator.pendingLines = lines

        guard context.coordinator.isReady else { return }

        if context.coordinator.lastThemeKey != signature {
            context.coordinator.lastThemeKey = signature
            updateThemeColors(in: nsView)
            if let bg = nsColorFromTheme(token: themeBinder.resolvedColorToken("panel"), fallback: NSColor.windowBackgroundColor) {
                nsView.layer?.backgroundColor = bg.cgColor
            }
        }

        if lines.count < context.coordinator.lastLineCount {
            setAllLines(lines, in: nsView)
        } else if lines.count > context.coordinator.lastLineCount {
            let newLines = Array(lines.dropFirst(context.coordinator.lastLineCount))
            appendLines(newLines, in: nsView)
        }
        context.coordinator.lastLineCount = lines.count
    }

    private func load(into webView: WKWebView) {
        let background = cssColor(token: themeBinder.resolvedColorToken("panel"), fallback: "#111111")
        let foreground = cssColor(token: themeBinder.resolvedColorToken("text"), fallback: "#E6EEF5")
        let html = """
        <!doctype html>
        <html>
        <head>
          <meta charset="utf-8" />
          <meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'; script-src 'unsafe-inline';" />
          <style>
            :root { --bg: \(background); --fg: \(foreground); }
            html, body { margin: 0; padding: 0; width: 100%; min-height: 100%; background: var(--bg); color: var(--fg); }
            body { padding: 12px; font: 12px Menlo, monospace; box-sizing: border-box; }
            pre { margin: 0; white-space: pre-wrap; word-break: break-word; }
          </style>
          <script>
            function setLines(lines) {
              const pre = document.getElementById('log');
              pre.textContent = lines.join('\\n');
              window.scrollTo(0, document.body.scrollHeight);
            }
            function appendLines(lines) {
              if (!lines || lines.length === 0) return;
              const pre = document.getElementById('log');
              if (!pre.textContent) {
                pre.textContent = lines.join('\\n');
              } else {
                pre.textContent += '\\n' + lines.join('\\n');
              }
              window.scrollTo(0, document.body.scrollHeight);
            }
            function setTheme(bg, fg) {
              document.documentElement.style.setProperty('--bg', bg);
              document.documentElement.style.setProperty('--fg', fg);
            }
          </script>
        </head>
        <body>
          <pre id=\"log\"></pre>
        </body>
        </html>
        """
        webView.loadHTMLString(html, baseURL: nil)
    }

    private func loadFallback(into webView: WKWebView, reason: String) {
        let background = cssColor(token: themeBinder.resolvedColorToken("panel"), fallback: "#111111")
        let foreground = cssColor(token: themeBinder.resolvedColorToken("text"), fallback: "#E6EEF5")
        let muted = cssColor(token: themeBinder.resolvedColorToken("textMuted"), fallback: "#9BA7B4")
        let escapedReason = reason.replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
        let escapedLogs = lines.joined(separator: "\n")
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
        let html = """
        <!doctype html>
        <html>
        <head>
          <meta charset="utf-8" />
          <style>
            html, body { margin: 0; padding: 0; width: 100%; min-height: 100%; background: \(background); color: \(foreground); }
            body { padding: 12px; box-sizing: border-box; font: 12px Menlo, monospace; }
            .hint { color: \(muted); margin-bottom: 8px; font-size: 11px; }
            pre { margin: 0; white-space: pre-wrap; word-break: break-word; }
          </style>
        </head>
        <body>
          <div class="hint">Web 渲染器回退模式：\(escapedReason)</div>
          <pre>\(escapedLogs)</pre>
        </body>
        </html>
        """
        webView.loadHTMLString(html, baseURL: nil)
    }

    private func cssColor(token: String?, fallback: String) -> String {
        guard let token, let rgba = rgbaFromThemeHex(token) else { return fallback }
        if rgba.a >= 0.999 {
            return String(format: "#%02X%02X%02X", rgba.r, rgba.g, rgba.b)
        }
        return String(format: "rgba(%d,%d,%d,%.3f)", rgba.r, rgba.g, rgba.b, rgba.a)
    }

    private func rgbaFromThemeHex(_ hex: String) -> (r: Int, g: Int, b: Int, a: Double)? {
        var string = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        if string.count == 6 { string = "FF" + string } // AARRGGBB (match ThemeBinder)
        guard string.count == 8, let int = UInt64(string, radix: 16) else { return nil }
        let a = Double((int & 0xFF000000) >> 24) / 255.0
        let r = Int((int & 0x00FF0000) >> 16)
        let g = Int((int & 0x0000FF00) >> 8)
        let b = Int(int & 0x000000FF)
        return (r: r, g: g, b: b, a: a)
    }

    private func nsColorFromTheme(token: String?, fallback: NSColor) -> NSColor? {
        guard let token, let rgba = rgbaFromThemeHex(token) else { return fallback }
        return NSColor(calibratedRed: CGFloat(rgba.r) / 255.0,
                       green: CGFloat(rgba.g) / 255.0,
                       blue: CGFloat(rgba.b) / 255.0,
                       alpha: CGFloat(rgba.a))
    }

    private func themeSignature() -> String {
        let background = cssColor(token: themeBinder.resolvedColorToken("panel"), fallback: "#111111")
        let foreground = cssColor(token: themeBinder.resolvedColorToken("text"), fallback: "#E6EEF5")
        return "\(background)|\(foreground)"
    }

    private func updateThemeColors(in webView: WKWebView) {
        let background = cssColor(token: themeBinder.resolvedColorToken("panel"), fallback: "#111111")
        let foreground = cssColor(token: themeBinder.resolvedColorToken("text"), fallback: "#E6EEF5")
        let js = "setTheme(\\\"\(background)\\\", \\\"\(foreground)\\\");"
        webView.evaluateJavaScript(js, completionHandler: nil)
    }

    private func setAllLines(_ lines: [String], in webView: WKWebView) {
        let payload = jsArrayPayload(lines)
        let js = "setLines(\(payload));"
        webView.evaluateJavaScript(js, completionHandler: nil)
    }

    private func appendLines(_ newLines: [String], in webView: WKWebView) {
        let payload = jsArrayPayload(newLines)
        let js = "appendLines(\(payload));"
        webView.evaluateJavaScript(js, completionHandler: nil)
    }

    private func jsArrayPayload(_ lines: [String]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: lines, options: []),
              let json = String(data: data, encoding: .utf8) else {
            return "[]"
        }
        return json
    }
}
