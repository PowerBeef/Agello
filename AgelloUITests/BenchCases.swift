import Foundation

/// One request of the bench (docs/HARNESS.md): what it asks and how it's sent.
struct BenchCase {
  var id: String
  var prompt: String
  var think = true
  /// Think's budget on the Mac command line (`agello bench`). The app's is fixed at 4,096 since
  /// 2026-11-11, so the iPhone bench sets nothing. nil leaves the tool's default.
  var thinkingBudget: Int? = 4_096
  var search = false
  /// The longest the reply may take before the case counts as stuck.
  var timeout: TimeInterval = 300

  /// Sent after the first reply, one at a time, typed into the composer.
  var followUps: [String] = []
  /// Extra launch arguments, for what the driver can't do by hand (a file from the system picker).
  var launchArguments: [String] = []

  /// The quality bench (eight requests as users send them, once probe 24 of the device tests),
  /// the three-part coding prompt, and two flows: a Search follow-up and a file with a follow-up.
  /// `scripts/bench-report.py` holds each case's checks, by `id`.
  static let all = [
    BenchCase(
      id: "calculator-search",
      prompt: "Create a beautiful calculator app for mobile in a single self contained html file", search: true),
    BenchCase(
      id: "todo",
      prompt: "Write a to-do list web app in one HTML file: add, edit, complete and delete tasks, saved in localStorage, comfortable on a phone."),
    BenchCase(
      id: "swiftui-search",
      prompt: "Write a SwiftUI view for iOS that lists notes with swipe to delete, pull to refresh, and a search field. Use the current APIs.",
      search: true),
    BenchCase(
      id: "python",
      prompt: "Write a Python script that downloads a CSV file from a URL given on the command line, prints the average of a column named in a second argument, and handles network and parsing errors cleanly."),
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
      prompt: "Plan a 3-day winter trip to Montreal with mostly indoor activities and a budget table.", search: true),
    BenchCase(id: "ttl-cache", prompt: Prompts.threePartCoding),
    // The follow-up that was searched as the runner-up's time (2026-11-10): the margin is 6 min 26 s.
    BenchCase(
      id: "followup-search", prompt: "Who won the 2026 Tour de France?", think: false, search: true,
      followUps: ["By how many minutes?"]),
    // A 60-page report from the app's sample (`--uitest-sample-report`): section 23 is about water
    // quality, inspected by district 4.
    BenchCase(
      id: "file-report", prompt: "Summarize this report in a few bullet points.", think: false,
      followUps: ["What is section 23 about, and which district inspected it?"],
      launchArguments: ["--uitest-sample-report"]),
  ]

  enum Prompts {
    /// A three-part coding evaluation the maintainer ran on the iPhone (2026-11-09): about 3.8K
    /// tokens in, about 4.5K out with Think. Judged by `scripts/bench/ttl-cache/`.
    static let threePartCoding = #"""
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
  }
}
