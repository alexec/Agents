#!/usr/bin/env swift
// Fill a scratch store with agents for 051's walks and measures.
//
//   scripts/seed-archived.swift --root /tmp/run-051 --count 3 --archived-days-ago 31 \
//       --transcript-bytes 2000000 [--live] [--project /tmp/run-051/project]
//
// Each agent is the real-sized fixture record (`archived-agent.json`, whose option and
// command lists are what make an archived record 24 KB) with a fresh id and dates, and a
// transcript of about the size asked for, made of valid entries. It prints the ids.
//
// Archived by default, `--archived-days-ago` back. `--live` writes a finished agent instead.
//
// It refuses any root under ~/Library: the real store is never a place to seed.

import Foundation

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("seed-archived: \(message)\n".utf8))
    exit(2)
}

func need<T>(_ value: T?, _ message: String) -> T {
    guard let value else { fail(message) }
    return value
}

var root: String?
var count = 1
var daysAgo = 31.0
var transcriptBytes = 20_000
var live = false
var project: String?

var arguments = CommandLine.arguments.dropFirst().makeIterator()
while let argument = arguments.next() {
    func value() -> String { need(arguments.next(), "\(argument) wants a value") }
    switch argument {
    case "--root": root = value()
    case "--count": count = need(Int(value()), "--count wants a number")
    case "--archived-days-ago": daysAgo = need(Double(value()), "--archived-days-ago wants a number")
    case "--transcript-bytes": transcriptBytes = need(Int(value()), "--transcript-bytes wants a number")
    case "--live": live = true
    case "--project": project = value()
    default: fail("unknown argument \(argument)")
    }
}

guard let root else { fail("--root is required") }
let rootURL = URL(filePath: root).standardizedFileURL
let library = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library").standardizedFileURL
guard !rootURL.path.hasPrefix(library.path) else { fail("refusing to seed under ~/Library: \(rootURL.path)") }

let fixture = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    .appending(path: "Packages/AgentsKit/Tests/AgentsKitTests/Fixtures/archived-agent.json")
guard let template = try? JSONSerialization.jsonObject(with: Data(contentsOf: fixture)) as? [String: Any] else {
    fail("could not read the fixture at \(fixture.path)")
}

let stamp: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f
}()

let projectFolder = URL(filePath: project ?? rootURL.appending(path: "project").path)
try? FileManager.default.createDirectory(at: projectFolder, withIntermediateDirectories: true)

let now = Date()
for index in 0 ..< count {
    let id = UUID()
    let archivedAt = now.addingTimeInterval(-daysAgo * 86_400 - Double(index))
    var record = template
    record["id"] = id.uuidString
    record["title"] = live ? "Seeded live agent \(index + 1)" : "Seeded archived agent \(index + 1)"
    record["cwd"] = projectFolder.absoluteString
    record["createdAt"] = stamp.string(from: archivedAt.addingTimeInterval(-3_600))
    record["lastActivityAt"] = stamp.string(from: live ? now : archivedAt)
    if live {
        record["state"] = "finished"
        record["endedReason"] = "endTurn"
        record["archivedReason"] = nil
        record["archivedAt"] = nil
    } else {
        record["state"] = "archived"
        record["archivedReason"] = "byUser"
        record["archivedAt"] = stamp.string(from: archivedAt)
    }

    let folder = rootURL.appending(path: "agents/\(id.uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let data = try JSONSerialization.data(withJSONObject: record, options: [.prettyPrinted, .sortedKeys])
    try data.write(to: folder.appending(path: "agent.json"))

    // Agent messages of about 2 KB each until the size is reached.
    var transcript = Data()
    let filler = String(repeating: "Seeded words for a transcript of the right size. ", count: 40)
    var line = 0
    while transcript.count < transcriptBytes {
        let entry: [String: Any] = [
            "at": stamp.string(from: archivedAt.addingTimeInterval(Double(line) - 1_800)),
            "id": UUID().uuidString,
            "kind": ["agentMessage": ["text": "\(line): \(filler)"]],
        ]
        transcript.append(try JSONSerialization.data(withJSONObject: entry, options: [.sortedKeys]))
        transcript.append(0x0A)
        line += 1
    }
    try transcript.write(to: folder.appending(path: "transcript.jsonl"))
    print(id.uuidString)
}
