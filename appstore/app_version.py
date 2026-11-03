#!/usr/bin/env python3
"""Prints the app's version: MARKETING_VERSION in the Xcode project of the checked-out branch. Every build
configuration must carry the same one."""
import os, re, sys

PROJECT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "FM1Hub.xcodeproj", "project.pbxproj")


def app_version():
    found = set(re.findall(r"\bMARKETING_VERSION = \"?([^\";\n]+)\"?;", open(PROJECT, encoding="utf-8").read()))
    if len(found) != 1:
        sys.exit(f"MARKETING_VERSION in {PROJECT}: expected one value, found {', '.join(sorted(found)) or 'none'}")
    return found.pop()


if __name__ == "__main__":
    print(app_version())
