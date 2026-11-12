---
name: outside-code-is-not-built-here
description: Agents on this Mac are refused cloning and building or running outside code (a GitHub tool, a PyPI package) for a build step; data such as an npm tarball of SVGs is fine
metadata:
  type: project
---

Lane #4976 tried to build SwiftDraw (Zlib) from its tag and to run picosvg with uv to turn Lucide's SVGs into symbol templates; the permission classifier refused both as code from outside (2026-11-12). Downloading lucide-static's npm tarball and reading its SVGs as data was allowed.

**Why:** running unvetted outside code on Alex's Mac is a supply-chain risk.

**How to apply:** for a build-time conversion, first look for the platform library (CoreGraphics, Foundation's XMLParser, AppKit) and keep our own part small; say in the PR why the outside tool was not used. A pinned dependency the project already builds (SwiftPM, npm in Web/) is a different case.
