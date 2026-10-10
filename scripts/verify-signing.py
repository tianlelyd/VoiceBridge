#!/usr/bin/env python3
"""Validate real Debug/Release bundles; retain a repeatable JSON report."""
import json
import pathlib
import plistlib
import subprocess
import sys


def run(*args):
    return subprocess.run(args, check=True, capture_output=True, timeout=30)


products = pathlib.Path(sys.argv[1]).resolve()
report = pathlib.Path(sys.argv[2]).resolve()
results = {}
for configuration in ("Debug", "Release"):
    app = products / configuration / "VoiceBridge.app"
    run("codesign", "--verify", "--deep", "--strict", str(app))
    signature = run("codesign", "-dvv", str(app)).stderr.decode()
    requirement_output = run("codesign", "-dr", "-", str(app))
    requirement = (requirement_output.stdout + requirement_output.stderr).decode()
    requirement = next(line.removeprefix("designated => ") for line in requirement.splitlines() if line.startswith("designated => "))
    entitlements = plistlib.loads(run("codesign", "-d", "--entitlements", ":-", str(app)).stdout)
    with (app / "Contents/Info.plist").open("rb") as stream:
        info = plistlib.load(stream)
    results[configuration] = {
        "path": str(app),
        "signature": signature,
        "requirement": requirement,
        "entitlements": entitlements,
        "bundle_id": info["CFBundleIdentifier"],
    }

checks = {
    "developer_id": all("Authority=Developer ID Application: YanDong Li (97ZLXJHDD3)" in item["signature"] for item in results.values()),
    "bundle_id": all(item["bundle_id"] == "app.doodto.VoiceBridge" for item in results.values()),
    "same_requirement": results["Debug"]["requirement"] == results["Release"]["requirement"],
    "debug_attach_allowed": results["Debug"]["entitlements"].get("com.apple.security.get-task-allow") is True,
    "release_attach_disallowed": not results["Release"]["entitlements"].get("com.apple.security.get-task-allow", False),
}
report.parent.mkdir(parents=True, exist_ok=True)
report.write_text(json.dumps({"checks": checks, "bundles": results}, indent=2) + "\n")
print(json.dumps(checks, indent=2))
print(f"Report: {report}")
sys.exit(0 if all(checks.values()) else 1)
