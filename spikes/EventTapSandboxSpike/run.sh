#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"

# Compile, embedding Info.plist into the __TEXT __info_plist section.
# App Sandbox requires CFBundleIdentifier to create the container directory;
# without it the binary SIGTRAPs in _libsecinit_appsandbox before main() runs.
swiftc spike.swift -o spike \
    -Xlinker -sectcreate \
    -Xlinker __TEXT \
    -Xlinker __info_plist \
    -Xlinker Info.plist

# Sign with sandbox entitlements (ad-hoc).
# Not enabling hardened runtime — ad-hoc signed + hardened runtime + sandbox
# requires additional cs.allow-* entitlements we don't need for this test.
codesign --force --sign - --entitlements spike.entitlements spike

echo
echo "Binary built and sandbox-signed at: $(pwd)/spike"
echo
echo "NEXT STEPS:"
echo "  1. Open System Settings → Privacy & Security → Accessibility"
echo "  2. Add: $(pwd)/spike  (drag it in or use the + button)"
echo "  3. Toggle the switch ON for that entry"
echo "  4. Run: ./spike"
echo "  5. Press and release Left Ctrl, Left Option, Cmd, etc. for ~10s"
echo
echo "PASS criteria: you see 'flagsChanged: <number>' lines in output."
echo "FAIL criteria: 'FAIL: CGEvent.tapCreate returned nil' or no events appear."
