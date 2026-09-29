#!/bin/zsh
# Builds and ad-hoc signs build/S2Client.app (sandboxed, network.client only).
set -e
cd "${0:A:h}"
rm -rf build && mkdir -p build/S2Client.app/Contents/MacOS

swiftc -O -o build/S2Client.app/Contents/MacOS/S2Client main.swift
cp Info.plist build/S2Client.app/Contents/Info.plist
codesign --force --sign - --entitlements S2Client.entitlements --options runtime build/S2Client.app
codesign -d --entitlements - build/S2Client.app
codesign -dv build/S2Client.app 2>&1 | grep -E "Identifier|Signature|flags"
