// Loads a web app a bench reply wrote and tries it, as a user would on first open
// (docs/HARNESS.md; moved from the device probe in H2).
//
// Usage: swift scripts/bench/webapp-check.swift FILE.html [calculator|todo]
// Prints one JSON object: JavaScript errors, buttons found, and for a calculator the display
// after 7 × 8 =, for a to-do list whether a task typed in and added shows up.
//
// The page is the model's output: it runs in WebKit's own sandboxed process, offscreen, with a
// throwaway data store, at a web origin (a page without one can't use localStorage).
import AppKit
import WebKit

let arguments = CommandLine.arguments
guard arguments.count >= 2, let html = try? String(contentsOfFile: arguments[1], encoding: .utf8) else {
  print(#"{"found": false}"#)
  exit(2)
}
let kind = arguments.count > 2 ? arguments[2] : ""

NSApplication.shared.setActivationPolicy(.prohibited)
let configuration = WKWebViewConfiguration()
configuration.websiteDataStore = .nonPersistent()
configuration.userContentController.addUserScript(
  WKUserScript(
    source: "window.__errors = []; window.addEventListener('error', e => window.__errors.push(String(e.message)));",
    injectionTime: .atDocumentStart, forMainFrameOnly: true))
let view = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 844), configuration: configuration)
view.loadHTMLString(html, baseURL: URL(string: "https://bench.agello.invalid/"))

func spin(_ seconds: Double) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }
func evaluate(_ script: String) -> Any? {
  var result: Any?
  var done = false
  view.evaluateJavaScript(script) { value, _ in
    result = value
    done = true
  }
  var waited = 0.0
  while !done, waited < 5 {
    spin(0.05)
    waited += 0.05
  }
  return result
}

var waited = 0.0
while view.isLoading, waited < 8 {
  spin(0.1)
  waited += 0.1
}
spin(0.5)

var result: [String: Any] = ["found": true, "htmlCharacters": html.count]
result["buttons"] = evaluate("document.querySelectorAll('button, [onclick], .btn, .key').length") ?? -1
if kind == "calculator" {
  result["seven-times-eight"] =
    evaluate(
      """
      (() => {
        const all = [...document.querySelectorAll('button, [onclick], .btn, .key, [data-value]')];
        const find = labels => all.find(b => labels.includes((b.dataset.value || b.textContent || '').trim()));
        const keys = [['7'], ['×', '*', 'x', 'X'], ['8'], ['=']].map(find);
        if (keys.some(k => !k)) return 'missing keys';
        keys.forEach(k => k.click());
        const shown = document.body.innerText + ' '
          + [...document.querySelectorAll('input, output, textarea')].map(e => e.value).join(' ');
        return shown.includes('56') ? 'shows 56' : 'no 56';
      })()
      """) ?? "script failed"
}
if kind == "todo" {
  result["add-task"] =
    evaluate(
      """
      (() => {
        const input = document.querySelector('input[type=text], input:not([type]), textarea');
        if (!input) return 'no input';
        input.value = 'Buy oat milk';
        input.dispatchEvent(new Event('input', { bubbles: true }));
        const button = [...document.querySelectorAll('button')].find(b => /add/i.test(b.textContent + b.id + b.className))
          || document.querySelector('button');
        if (button) button.click();
        else input.dispatchEvent(new KeyboardEvent('keydown', { key: 'Enter', bubbles: true }));
        return document.body.innerText.includes('Buy oat milk') ? 'task shows' : 'task missing';
      })()
      """) ?? "script failed"
}
result["jsErrors"] = evaluate("window.__errors") ?? []
let data = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
print(String(decoding: data, as: UTF8.self))
