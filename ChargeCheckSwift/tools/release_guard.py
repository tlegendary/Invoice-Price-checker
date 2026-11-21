#!/usr/bin/env python3
"""Fails (exit 1) if a release would ship with test-only settings.

  release_guard.py project.yml            the committed project file (checked on every push)
  release_guard.py path/to/Info.plist     a built app's Info.plist (checked after a release archive)

A release must not have: test mode (CCTestBuild), the beta bundle ID or name, or Google's public test ad IDs.
"""
import plistlib
import re
import sys

TEST_AD_PUBLISHER = "ca-app-pub-3940256099942544"   # Google's public test ads


def check_project(text):
    problems = []
    m = re.search(r"^\s*CCTestBuild:\s*(\S+)", text, re.M)
    if not m:
        problems.append("CCTestBuild is missing (it must be set to false)")
    elif m.group(1).lower() not in ("false", "no", "0"):
        problems.append(f"CCTestBuild is {m.group(1)} (must be false; only the beta build turns it on)")
    if re.search(r"PRODUCT_BUNDLE_IDENTIFIER:\s*\S*\.beta\b", text):
        problems.append("a beta bundle ID is committed")
    if re.search(r"CFBundleDisplayName:\s*CC Beta", text):
        problems.append("the beta name is committed")
    if TEST_AD_PUBLISHER in text:
        problems.append("Google's test ad ID is in the project")
    return problems


def check_plist(info):
    problems = []
    if info.get("CCTestBuild") not in (False, None, "NO", "false", 0):
        problems.append(f"CCTestBuild is {info.get('CCTestBuild')!r} in the built app")
    if str(info.get("CFBundleIdentifier", "")).endswith(".beta"):
        problems.append("the built app has the beta bundle ID")
    if str(info.get("CFBundleDisplayName", "")) == "CC Beta":
        problems.append("the built app has the beta name")
    if TEST_AD_PUBLISHER in str(info.get("GADApplicationIdentifier", "")):
        problems.append("the built app uses Google's test ad app ID")
    return problems


def main(paths):
    failed = False
    for path in paths:
        if path.endswith(".plist"):
            with open(path, "rb") as f:
                problems = check_plist(plistlib.load(f))
        else:
            with open(path, encoding="utf-8") as f:
                problems = check_project(f.read())
        for p in problems:
            print(f"RELEASE GUARD: {path}: {p}")
        failed = failed or bool(problems)
    if not failed:
        print("Release guard: OK (" + ", ".join(paths) + ")")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:] or ["project.yml"]))
