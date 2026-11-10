import WebKit
import XCTest

@testable import Agello

extension ProbeScenarioTests {
  /// One request of the quality bench: what it asks, and how it's sent.
  struct BenchCase {
    var id: String
    var prompt: String
    var search = false
    var think = true
    /// The reply should be a web page to load and try.
    var webApp = false
    /// The reply should hold a code block.
    var code = false
  }

  static let benchCases: [BenchCase] = [
    BenchCase(
      id: "calculator-search",
      prompt: "Create a beautiful calculator app for mobile in a single self contained html file",
      search: true, webApp: true, code: true),
    BenchCase(
      id: "todo",
      prompt: "Write a to-do list web app in one HTML file: add, edit, complete and delete tasks, saved in localStorage, comfortable on a phone.",
      webApp: true, code: true),
    BenchCase(
      id: "swiftui-search",
      prompt: "Write a SwiftUI view for iOS that lists notes with swipe to delete, pull to refresh, and a search field. Use the current APIs.",
      search: true, code: true),
    BenchCase(
      id: "python",
      prompt: "Write a Python script that downloads a CSV file from a URL given on the command line, prints the average of a column named in a second argument, and handles network and parsing errors cleanly.",
      code: true),
    BenchCase(id: "facts-search", prompt: "What changed in Swift 6.2?", search: true),
    BenchCase(
      id: "explain",
      prompt: "Explain step by step how HTTPS keeps a connection private, for someone who knows no cryptography."),
    BenchCase(
      id: "email",
      prompt: "Write a polite email to my landlord asking to fix a leaking kitchen faucet this week, with a subject line.",
      think: false),
    BenchCase(
      id: "trip-search",
      prompt: "Plan a 3-day winter trip to Montreal with mostly indoor activities and a budget table.",
      search: true),
    BenchCase(id: "ttl-cache", prompt: threePartCodingPrompt, code: true),
  ]

  /// A three-part coding evaluation the maintainer ran on the iPhone (2026-11-09): a long prompt
  /// (about 3.8K tokens with the preamble) whose reply holds three code blocks and runs to about
  /// 4K tokens with Think. Judged whole when all three parts are there and the code runs.
  static let threePartCodingPrompt = #"""
    You are being evaluated on coding ability. Complete all three parts. Use Python 3.10+ and the standard library only (pytest is allowed for Part 3). Put each part's code in its own complete code block that runs as-is.

    ## Part 1 — Implement a TTL + LRU cache

    Write a class `TTLCache` with this interface:

    - `TTLCache(capacity: int, clock: Callable[[], float] = time.monotonic)`
      - Raise `ValueError` if capacity < 1.
      - All time checks must use `clock()` so tests can inject a fake clock.
    - `set(key, value, ttl: float | None = None) -> None`
      - `ttl` is the number of seconds until expiry. `None` means the entry never expires. Raise `ValueError` if ttl is not None and ttl <= 0.
      - Setting an existing key replaces its value and ttl and marks it most recently used.
      - When a new key is inserted into a full cache, first remove all expired entries. If the cache is still full, evict the least recently used entry.
    - `get(key, default=None)`
      - Return the value if the key exists and has not expired, and mark it most recently used. Otherwise return `default`.
      - An entry is expired when `clock() >= its expiry time`. Remove an expired entry when you encounter it.
    - `delete(key) -> bool`: return True only if a live (non-expired) entry was removed.
    - `__len__()`: return the number of non-expired entries.
    - `__contains__(key)`: return True if the key is live. It must NOT change recency.

    `get`, `delete` and `__contains__` must be O(1) average. `set` must be O(1) average when no eviction is needed. In one or two sentences, state the time complexity of your eviction path and of `__len__`.

    ## Part 2 — Find and fix the bugs

    The function below should meet this spec:
    - Input: a list of `(start, end)` tuples of numbers.
    - Output: a new list of merged tuples, sorted by start.
    - Intervals that overlap must be merged. Intervals that only touch, like `(1, 3)` and `(3, 5)`, must also be merged.
    - The input list must not be modified.
    - Empty input returns `[]`.
    - Raise `ValueError` if any interval has start > end.

    ```python
    def merge_intervals(intervals):
        intervals.sort()
        merged = [intervals[0]]
        for start, end in intervals[1:]:
            last_start, last_end = merged[-1]
            if start < last_end:
                merged[-1] = (last_start, end)
            else:
                merged.append((start, end))
        return merged
    ```

    List every bug you find, one line each, with an input that triggers it. Then give the corrected function.

    ## Part 3 — Tests

    Write a pytest file for your Part 1 `TTLCache`, and assume Part 1 is saved as `ttl_cache.py`. Use a fake clock, not `time.sleep`. Cover at least these cases:
    - LRU eviction order
    - TTL expiry exactly at the boundary
    - expired entries being evicted before LRU ones
    - overwriting a key
    - `__contains__` not affecting recency
    - invalid arguments

    Keep explanations brief. The code is what will be judged.
    """#

  /// Probe 24: the quality bench. Realistic requests through the whole app (Search, Think, the
  /// on-device tools as users have them), each reply recorded in full (attachments
  /// `quality-<id>.md`) with cheap checks: finished or cut, code fenced and closed, citations with
  /// Search, and generated web apps loaded in a web view (JavaScript errors, and the calculator
  /// pressed through 7 × 8 =). For judging changes to prompts, Search and budgets; best on the
  /// Mac, where heat and battery don't slow it. `BENCH_ONLY=id,id` (`TEST_RUNNER_BENCH_ONLY`)
  /// runs some cases; `BENCH_REPEAT=n` runs each n times (live search changes between runs).
  func test24_QualityBench() async throws {
    try await requireLoadedModel()
    _ = try await harness.ensureDownloaded(ModelCatalog.embeddingGemma, timeout: 900)
    let only = ProcessInfo.processInfo.environment["BENCH_ONLY"].map { Set($0.split(separator: ",").map(String.init)) }
    let repeats = max(1, Int(ProcessInfo.processInfo.environment["BENCH_REPEAT"] ?? "") ?? 1)
    let runs = Self.benchCases.filter { only?.contains($0.id) ?? true }.flatMap { bench in
      (1...repeats).map { run -> BenchCase in
        var copy = bench
        if repeats > 1 { copy.id += "-\(run)" }
        return copy
      }
    }
    var rows: [[String: Any]] = []
    for bench in runs {
      appState.options.enableThinking = bench.think
      await appState.applyCurrentOptions()
      let exchange = await harness.ask(bench.prompt, in: harness.newThread(), webSearch: bench.search)
      let text = exchange.text
      let stats = exchange.reply?.stats
      let sources = exchange.reply?.parts.sources ?? []
      let fences = text.components(separatedBy: "\n").filter { $0.trimmingCharacters(in: .whitespaces).hasPrefix("```") }
      var row: [String: Any] = [
        "id": bench.id, "accepted": exchange.accepted, "seconds": exchange.seconds,
        "search": bench.search, "think": bench.think,
        "outputTokens": stats?.outputTokens ?? -1, "reachedLimit": stats?.reachedLimit ?? false,
        "answerCharacters": text.count, "reasoningCharacters": exchange.reply?.thought.count ?? 0,
        "sources": sources.map { "\($0.index) \($0.title) \($0.url ?? "")" },
        "citations": text.matches(of: /\[\d+\]/).count,
        "codeBlocks": fences.count / 2, "fencesClosed": fences.count.isMultiple(of: 2),
        "error": appState.generationError ?? "",
      ]
      if bench.webApp, let html = Self.htmlDocument(in: text) {
        row["webApp"] = await Self.tryWebApp(
          html, pressCalculator: bench.id.hasPrefix("calculator"), addTask: bench.id.hasPrefix("todo"))
      } else if bench.webApp {
        row["webApp"] = ["found": false]
      }
      rows.append(row)
      print("PROBE24 \(row)")
      let reply = "# \(bench.id)\n\n**Prompt:** \(bench.prompt)\n\n**Sources:**\n"
        + sources.map { "- [\($0.index)] \($0.title) \($0.url ?? "")" }.joined(separator: "\n")
        + "\n\n**Reasoning:**\n\n\(exchange.reply?.thought ?? "")\n\n**Reply:**\n\n\(text)\n"
      let attachment = XCTAttachment(data: Data(reply.utf8), uniformTypeIdentifier: "net.daringfireball.markdown")
      attachment.name = "quality-\(bench.id).md"
      attachment.lifetime = .keepAlways
      add(attachment)
      harness.record("probe24_quality_bench", ["rows": rows], in: self)
      XCTAssertTrue(exchange.accepted, "\(bench.id): \(appState.generationError ?? "rejected")")
    }
  }

  /// The first fenced HTML document in a reply, or one written without fences.
  static func htmlDocument(in reply: String) -> String? {
    let lower = reply.lowercased()
    guard let start = lower.range(of: "<!doctype html") ?? lower.range(of: "<html") else { return nil }
    let tail = reply[start.lowerBound...]
    if let end = tail.range(of: "</html>", options: .caseInsensitive) {
      return String(tail[..<end.upperBound])
    }
    return String(tail.prefix { $0 != "`" })
  }

  /// Loads `html` in an offscreen web view at a web origin (a page without one can't use
  /// localStorage) with a throwaway data store: JavaScript errors, buttons, for a calculator the
  /// display after pressing 7 × 8 = (by button text), for a to-do list whether a task typed in
  /// and added shows up.
  @MainActor
  static func tryWebApp(_ html: String, pressCalculator: Bool, addTask: Bool = false) async -> [String: Any] {
    let configuration = WKWebViewConfiguration()
    configuration.websiteDataStore = .nonPersistent()
    let catcher = WKUserScript(
      source: "window.__errors = []; window.addEventListener('error', e => window.__errors.push(String(e.message)));",
      injectionTime: .atDocumentStart, forMainFrameOnly: true)
    configuration.userContentController.addUserScript(catcher)
    let view = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 844), configuration: configuration)
    view.loadHTMLString(html, baseURL: URL(string: "https://bench.agello.invalid/"))
    for _ in 0..<50 where view.isLoading { try? await Task.sleep(for: .milliseconds(100)) }
    try? await Task.sleep(for: .milliseconds(500))
    var result: [String: Any] = ["found": true, "htmlCharacters": html.count]
    result["buttons"] = (try? await view.evaluateJavaScript("document.querySelectorAll('button, [onclick], .btn, .key').length")) ?? -1
    if pressCalculator {
      let press = """
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
        """
      result["seven-times-eight"] = (try? await view.evaluateJavaScript(press)) ?? "script failed"
    }
    if addTask {
      let add = """
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
        """
      result["add-task"] = (try? await view.evaluateJavaScript(add)) ?? "script failed"
    }
    result["jsErrors"] = (try? await view.evaluateJavaScript("window.__errors")) ?? []
    return result
  }
}
