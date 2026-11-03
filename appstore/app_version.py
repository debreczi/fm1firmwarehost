#!/usr/bin/env python3
"""Prints the app's version: MARKETING_VERSION of the app target in the Xcode project of the checked-out branch.
Every build configuration of the app must carry the same one; the test target's doesn't count."""
import os, re, sys

BUNDLE = "com.debreczi.fm1hub"
PROJECT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "FM1Hub.xcodeproj", "project.pbxproj")


def setting(block, key):
    m = re.search(rf"^\s*{key} = \"?([^\";\n]+)\"?;", block, re.M)
    return m.group(1) if m else None


def app_version():
    found = set()
    for block in re.findall(r"buildSettings = \{(.*?)\n\s*\};", open(PROJECT, encoding="utf-8").read(), re.S):
        if setting(block, "PRODUCT_BUNDLE_IDENTIFIER") == BUNDLE:
            found.add(setting(block, "MARKETING_VERSION") or "unset")
    if len(found) != 1 or "unset" in found:
        sys.exit(f"MARKETING_VERSION of {BUNDLE} in {PROJECT}: expected one value, "
                 f"found {', '.join(sorted(found)) or 'no configuration'}")
    return found.pop()


if __name__ == "__main__":
    print(app_version())
