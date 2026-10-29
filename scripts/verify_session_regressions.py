#!/usr/bin/env python3
"""Prove that each session regression test rejects its corresponding bug.

Only an isolated temporary package is modified. The checkout, installed app,
running helpers, login agents, and actual macOS lock state remain untouched.
"""
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile


ROOT = Path(__file__).resolve().parents[1]
LOGS = ROOT / ".build/session-regression-proof"
CORE_ONLY = "--core-only" in sys.argv[1:]
if not CORE_ONLY and os.environ.get("CI") not in ("true", "1") and os.environ.get("AURAFLOW_DEDICATED_TEST_SESSION") != "1":
    raise SystemExit("Video/window regression proof requires a dedicated macOS test session (AURAFLOW_DEDICATED_TEST_SESSION=1). Use --core-only for noninteractive Dock checks.")
if CORE_ONLY:
    LOGS = LOGS / "core-only"
LOGS.mkdir(parents=True, exist_ok=True)
ENV = os.environ.copy()
XCODE = Path("/Applications/Xcode.app/Contents/Developer")
if "DEVELOPER_DIR" not in ENV and XCODE.is_dir():
    ENV["DEVELOPER_DIR"] = str(XCODE)
SWIFT = subprocess.check_output(["xcrun", "--find", "swift"], env=ENV, text=True).strip()
SDK = subprocess.check_output(["xcrun", "--sdk", "macosx", "--show-sdk-path"], env=ENV, text=True).strip()
AGENT = Path("Sources/AuraWallpaperAgent/main.swift")
BRIDGE = Path("Sources/AuraWallpaperNativeBridge/NativeLockScreenWallpaperBridge.swift")
AUTOSTART = Path("Sources/AuraWallpaperCore/AutostartManager.swift")
PROVIDER = Path("Sources/AuraWallpaperCore/AerialProviderController.swift")
CASES = [
    ("issue1", "issue1PreparedHelperNeverRelocksAfterStaleShowsOrLateRecovery", BRIDGE),
    ("issue2", "issue2LoginStartsDecodedAnimationInsteadOfLeavingCachedStillFrame", AGENT),
    ("issue3", "issue3UnlockResumesDecodedAnimationAfterSystemSuspendsDesktopPlayer", AGENT),
    ("issue4", "issue4LockScreenWaitsForPreparedSecureSurfaceAfterLogin", BRIDGE),
    ("issue5", "issue5LoginCheckboxDoesNotStopRestartOrPauseCurrentWallpaper", AUTOSTART),
    ("issue6", "wallpaperRefreshNeverTerminatesDock", PROVIDER),
]
if CORE_ONLY:
    CASES = CASES[-1:]
TEST_FILTER = "DockRefreshRegressionTests" if CORE_ONLY else "WallpaperSessionRegressionTests|NativeLockScreenSessionRegressionTests|DockRefreshRegressionTests"


def replace_once(source, old, new):
    assert source.count(old) == 1, f"Regression injection point changed: {old!r}"
    return source.replace(old, new, 1)


def reintroduce_bug(issue, source):
    if issue == "issue6":
        original = '("/usr/bin/pkill", ["-x", "legacyScreenSaver"]),'
        return replace_once(source, original, original + '\n            ("/usr/bin/killall", ["Dock"]),')
    if issue == "issue1":
        source, count = re.subn(r"(?:self\.)?sessionIsLocked\(\) == true", "true", source)
        assert count >= 3, "Native session confirmation boundaries changed"
        return source
    if issue == "issue2":
        source = replace_once(source, "lastCommandID = previousCommand?.id", "lastCommandID = nil")
        return replace_once(source, "lastCommandOperationID = previousCommand?.operationID", "lastCommandOperationID = nil")
    if issue == "issue3":
        return replace_once(source, "showWindows(forceOrder: true)\n                applyPlaybackRate()",
            "showWindows(forceOrder: true)\n                // Regression: never resume the suspended Desktop player.")
    if issue == "issue5":
        return replace_once(source, "try store.removeLaunchAtLogin()", "try store.disableLaunchAgent()")
    return replace_once(source, "restartSaverWhenReady = true\n        presentationQueue.request(locked: true)",
        "startSystemScreenSaverNow()\n        restartSaverWhenReady = false\n        presentationQueue.request(locked: true)")


def run(package, name, test_filter):
    log = LOGS / f"{name}.log"
    with log.open("w") as output:
        result = subprocess.run([SWIFT, "test", "--package-path", str(package), "--sdk", SDK,
            "--no-parallel", "--filter", test_filter], env=ENV,
            stdout=output, stderr=subprocess.STDOUT, timeout=300)
    return result.returncode, log.read_text()


report = []
with tempfile.TemporaryDirectory(prefix="AuraSessionRegressionProof-") as temporary:
    package = Path(temporary) / "macOSApp"
    shutil.copytree(ROOT / "macOSApp", package, ignore=shutil.ignore_patterns(".build", ".swiftpm"))
    originals = {path: (package / path).read_text() for _, _, path in CASES}
    code, output = run(package, "baseline", TEST_FILTER)
    assert code == 0 and all(name in output for _, name, _ in CASES), LOGS / "baseline.log"
    print(f"Baseline: all {len(CASES)} regression tests pass.", flush=True)
    for issue, name, path in CASES:
        for original_path, source in originals.items():
            (package / original_path).write_text(source)
        (package / path).write_text(reintroduce_bug(issue, originals[path]))
        code, output = run(package, issue, name)
        detected = (code == 1 and "recorded an issue" in output and "failed after" in output
            and not re.search(r"unexpected signal|Program crashed|Fatal error|Signal \d+:", output))
        assert detected, f"{issue} did not reject the reintroduced bug: {LOGS / (issue + '.log')}"
        report.append({"issue": issue, "test": name, "reintroduced_bug_detected": True})
        print(f"{issue}: reintroduced bug rejected by its test.", flush=True)
    for path, source in originals.items():
        (package / path).write_text(source)
    code, output = run(package, "restored", TEST_FILTER)
    assert code == 0 and "passed after" in output, LOGS / "restored.log"
    print(f"Restored code: all {len(CASES)} regression tests pass again.", flush=True)
(LOGS / "report.json").write_text(json.dumps(report, indent=2) + "\n")
