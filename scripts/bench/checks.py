"""The bench's answer checks, by case (the cases are in AgelloUITests/BenchCases.swift).

Shared by scripts/bench-report.py (the iPhone bench) and scripts/cli-report.py (the Mac command
line), so a reply gets the same verdict wherever it was written: web apps are loaded and pressed
(webapp-check.swift), Swift is type-checked against the iOS SDK, Python is compiled or run
against the specs in ttl-cache/, and facts are looked for.

    verdict, failed = checks.judge("todo", 1, reply_text)

The reply's code is the model's: it runs in a throwaway folder, isolated from this environment.
"""
import json, os, re, shutil, subprocess, sys, tempfile

root = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))


def pytest_python():
    """A Python with pytest: this one, or a small environment under build/, kept between runs."""
    probe = subprocess.run([sys.executable, "-c", "import pytest"], capture_output=True)
    if probe.returncode == 0:
        return sys.executable
    venv = os.path.join(root, "build", "bench-venv")
    python = os.path.join(venv, "bin", "python")
    if not os.path.exists(python):
        subprocess.run([sys.executable, "-m", "venv", venv], capture_output=True)
        subprocess.run([python, "-m", "pip", "install", "-q", "pytest"], capture_output=True)
    probe = subprocess.run([python, "-c", "import pytest"], capture_output=True)
    return python if probe.returncode == 0 else None


def run_pytest(python, work, target):
    result = subprocess.run(
        [python, "-I", "-m", "pytest", "-q", "--no-header", "-p", "no:cacheprovider", target],
        cwd=work, capture_output=True, text=True, timeout=180)
    lines = [line for line in result.stdout.strip().split("\n") if line.strip()]
    summary = lines[-1] if lines else result.stderr.strip()[-200:]
    passed = int((re.search(r"(\d+) passed", summary) or [0, 0])[1])
    failed = int((re.search(r"(\d+) failed", summary) or [0, 0])[1]) + int((re.search(r"(\d+) error", summary) or [0, 0])[1])
    return {
        "passed": passed, "failed": failed, "summary": summary,
        "failures": [line[:200] for line in lines if line.startswith(("FAILED", "ERROR"))],
    }


def check_ttl_cache(reply):
    """The three-part coding case: every part there, and the code run against the spec."""
    blocks = re.findall(r"```python\n(.*?)```", reply, re.S)
    verdict = {
        "partsNamed": [bool(re.search(rf"Part {n}", reply)) for n in (1, 2, 3)],
        "pythonBlocks": len(blocks),
    }
    cache = next((block for block in blocks if "class TTLCache" in block), None)
    merge = next((block for block in blocks if "def merge_intervals" in block), None)
    tests = next((block for block in blocks if "def test_" in block), None)
    verdict["found"] = {"TTLCache": bool(cache), "merge_intervals": bool(merge), "tests": bool(tests)}
    python = pytest_python()
    if python is None:
        verdict["code"] = "not run: no pytest on this Mac"
        return verdict
    specs = os.path.join(root, "scripts", "bench", "ttl-cache")
    # The reply's code is the model's: run in a throwaway folder, isolated from this environment.
    work = tempfile.mkdtemp(prefix="agello-bench-")
    try:
        if cache:
            open(os.path.join(work, "ttl_cache.py"), "w").write(cache)
            shutil.copy(os.path.join(specs, "spec_ttl_cache.py"), os.path.join(work, "test_spec.py"))
            verdict["part1AgainstSpec"] = run_pytest(python, work, "test_spec.py")
            if tests:
                open(os.path.join(work, "test_own.py"), "w").write(tests)
                verdict["part3OwnTests"] = run_pytest(python, work, "test_own.py")
        if merge:
            open(os.path.join(work, "merge.py"), "w").write("from typing import *\n" + merge)
            shutil.copy(os.path.join(specs, "spec_merge.py"), os.path.join(work, "test_merge.py"))
            verdict["part2AgainstSpec"] = run_pytest(python, work, "test_merge.py")
    finally:
        shutil.rmtree(work, ignore_errors=True)
    return verdict


def html_document(reply):
    """The first HTML document in a reply, fenced or not."""
    lower = reply.lower()
    start = min((i for i in (lower.find("<!doctype html"), lower.find("<html")) if i >= 0), default=-1)
    if start < 0:
        return None
    end = lower.find("</html>", start)
    return reply[start:end + 7] if end >= 0 else reply[start:].split("`")[0]


def check_webapp(kind):
    """The reply holds a web app: load it and try it (scripts/bench/webapp-check.swift)."""
    def check(reply):
        html = html_document(reply)
        if html is None:
            return {"webApp": {"found": False}}
        work = tempfile.mkdtemp(prefix="agello-bench-")
        try:
            page = os.path.join(work, "app.html")
            open(page, "w").write(html)
            result = subprocess.run(
                ["swift", os.path.join(root, "scripts", "bench", "webapp-check.swift"), page, kind],
                capture_output=True, text=True, timeout=180)
            line = (result.stdout.strip().split("\n") or [""])[-1]
            return {"webApp": json.loads(line) if line.startswith("{") else {"found": True, "error": result.stderr.strip()[-200:]}}
        except (subprocess.TimeoutExpired, ValueError) as error:
            return {"webApp": {"found": True, "error": str(error)[:200]}}
        finally:
            shutil.rmtree(work, ignore_errors=True)
    return check


def check_swift(reply):
    """Swift in the reply, type-checked against the iOS SDK."""
    blocks = re.findall(r"```swift\n(.*?)```", reply, re.S)
    if not blocks:
        return {"swift": "no Swift block"}
    work = tempfile.mkdtemp(prefix="agello-bench-")
    try:
        source = os.path.join(work, "reply.swift")
        open(source, "w").write("\n\n".join(blocks))
        result = subprocess.run(
            ["xcrun", "--sdk", "iphoneos", "swiftc", "-typecheck", "-target", "arm64-apple-ios27.0", "-swift-version", "5", source],
            capture_output=True, text=True, timeout=300)
        errors = sorted({line.split("error: ", 1)[1] for line in result.stderr.split("\n") if "error: " in line})
        return {"swift": {"errors": len(errors), "first": errors[:5]}}
    finally:
        shutil.rmtree(work, ignore_errors=True)


def check_python(reply):
    """Python in the reply, byte-compiled (not run)."""
    blocks = re.findall(r"```python\n(.*?)```", reply, re.S)
    if not blocks:
        return {"python": "no Python block"}
    work = tempfile.mkdtemp(prefix="agello-bench-")
    try:
        source = os.path.join(work, "reply.py")
        open(source, "w").write("\n\n".join(blocks))
        result = subprocess.run([sys.executable, "-I", "-m", "py_compile", source], capture_output=True, text=True)
        return {"python": "compiles" if result.returncode == 0 else "fails: " + result.stderr.strip().split("\n")[-1][:160]}
    finally:
        shutil.rmtree(work, ignore_errors=True)


def expect(*patterns):
    """The reply holds each pattern."""
    def check(reply):
        return {"expected": {pattern: bool(re.search(pattern, reply)) for pattern in patterns}}
    return check


# Each case's checks, one list per turn (cases are in AgelloUITests/BenchCases.swift).
CHECKS = {
    "calculator-search": [[check_webapp("calculator")]],
    "todo": [[check_webapp("todo")]],
    "swiftui-search": [[check_swift]],
    "python": [[check_python]],
    "facts-search": [[expect(r"\[\d+\]")]],
    "explain": [[expect(r"(?i)certificate|key")]],
    "email": [[expect(r"(?i)subject")]],
    "trip-search": [[expect(r"\|.*\|", r"(?i)montr[eé]al")]],
    "ttl-cache": [[check_ttl_cache]],
    "followup-search": [[expect(r"Poga[cč]ar", r"\[\d+\]")], [expect(r"\b6\s*(minutes?|min\b|:|′|')")]],
    "file-report": [[], [expect(r"(?i)water quality", r"(?i)district\s*4|\b4\b")]],
}


def failed_checks(verdict):
    """The names of a verdict's failed checks, for the summary."""
    failed = []
    for pattern, found in verdict.get("expected", {}).items():
        if not found:
            failed.append(f"missing /{pattern}/")
    app = verdict.get("webApp")
    if app is not None:
        if not app.get("found"):
            failed.append("no web app in the reply")
        if app.get("jsErrors"):
            failed.append(f"{len(app['jsErrors'])} JavaScript errors")
        if app.get("seven-times-eight", "shows 56") != "shows 56":
            failed.append(f"7 × 8: {app['seven-times-eight']}")
        if app.get("add-task", "task shows") != "task shows":
            failed.append(f"add a task: {app['add-task']}")
        if app.get("error"):
            failed.append(f"web check: {app['error']}")
    if isinstance(verdict.get("swift"), dict) and verdict["swift"]["errors"]:
        failed.append(f"{verdict['swift']['errors']} Swift errors")
    if isinstance(verdict.get("swift"), str) or (isinstance(verdict.get("python"), str) and verdict["python"] != "compiles"):
        failed.append(verdict.get("swift") if isinstance(verdict.get("swift"), str) else verdict["python"])
    for key, label in (("part1AgainstSpec", "Part 1"), ("part2AgainstSpec", "Part 2"), ("part3OwnTests", "its own tests")):
        if verdict.get(key, {}).get("failed"):
            failed.append(f"{label}: {verdict[key]['failed']} failed")
    return failed


def fences_closed(reply):
    """Whether every code block that opens also closes."""
    return len([line for line in reply.split("\n") if line.strip().startswith("```")]) % 2 == 0


def judge(case_id, turn, reply):
    """A turn's verdict and the names of its failed checks. `turn` counts from 1."""
    verdict = {}
    checks = CHECKS.get(case_id, [])
    for check in checks[turn - 1] if turn <= len(checks) else []:
        verdict.update(check(reply))
    failed = failed_checks(verdict) + ([] if fences_closed(reply) else ["a code block isn't closed"])
    return verdict, failed
