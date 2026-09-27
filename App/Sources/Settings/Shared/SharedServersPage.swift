import AgentsKit
import SwiftUI

/// Frames C and D: the person's servers from `~/.agents/mcp.json`, the app's own, and
/// those set up only in one runtime's own config, so "why does Codex have this and Claude
/// not" has an answer. Env and header values are never here, only their names (FR-023).
struct SharedServersPage: View {
    let snapshot: DaemonAPI.SharedSnapshot
    @State private var chosenID: String?

    private var mcp: DaemonAPI.MCP { snapshot.mcp }

    var body: some View {
        HStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    SharedPageHeader(title: "MCP servers", path: mcp.file) {
                        Button("Edit mcp.json") { SharedFiles.open(mcp.file) }.buttonStyle(.paper)
                    }
                    if let problem = mcp.problem { ProblemBanner(problem: problem, file: mcp.file) }
                    if !mcp.servers.isEmpty {
                        SharedSectionLabel("Yours · every agent the app starts")
                        ForEach(mcp.servers) { row($0, id: "mine/\($0.name)") }
                    } else if mcp.problem == nil {
                        Text("No servers of your own yet. Each one in ~/.agents/mcp.json goes to every agent the app starts.")
                            .appText(.fine).foregroundStyle(.secondary)
                    }
                    SharedSectionLabel("From the app · always there, always wins a name")
                    ForEach(mcp.app) { row($0, id: "app/\($0.name)") }
                    if !mcp.runtimeOnly.isEmpty {
                        SharedSectionLabel("Only in one agent’s own config · not shared")
                        ForEach(mcp.runtimeOnly) { RuntimeOnlyRow(server: $0, runtime: name(of: $0.runtimeID)) }
                    }
                }
                .padding(20)
            }
            .frame(width: 440)
            Divider()
            if let (server, isApp) = chosen {
                ServerDetail(server: server, isApp: isApp, file: mcp.file, runtimes: snapshot.runtimes)
            } else {
                Text("Choose a server").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private var chosen: (DaemonAPI.Server, Bool)? {
        if let id = chosenID {
            if let mine = mcp.servers.first(where: { "mine/\($0.name)" == id }) { return (mine, false) }
            if let app = mcp.app.first(where: { "app/\($0.name)" == id }) { return (app, true) }
        }
        if let first = mcp.servers.first { return (first, false) }
        return mcp.app.first.map { ($0, true) }
    }

    private func name(of runtimeID: String) -> String {
        snapshot.runtimes.first { $0.id == runtimeID }?.name ?? runtimeID
    }

    private func row(_ server: DaemonAPI.Server, id: String) -> some View {
        let isChosen = chosenID.map { $0 == id } ?? (chosen.map { $0.0.name == server.name } ?? false)
        return SharedRow(chosen: isChosen,
                         label: "\(server.name), \(server.transport)\(server.clash.isEmpty ? "" : ", clash"). \(ReachDots.spoken(snapshot.runtimes, server.reach))",
                         action: { chosenID = id }) {
            HStack(spacing: 8) {
                Text(server.name).fontWeight(.semibold).lineLimit(1).fixedSize()
                SharedChip(text: server.transport)
                Text(server.summary).appText(.code).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                if !server.clash.isEmpty { SharedChip(text: "clash", tone: .attention) }
                Spacer(minLength: 6)
                ReachDots(runtimes: snapshot.runtimes, reach: server.reach)
            }
        }
    }
}

/// Frame D: `mcp.json` can't be read. Said once, here and on the overview, never a modal.
private struct ProblemBanner: View {
    let problem: DaemonAPI.Problem
    let file: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: "exclamationmark.triangle").tinted(.attention)
            VStack(alignment: .leading, spacing: 4) {
                Text("mcp.json can’t be read" + (problem.line.map { ", line \($0)" } ?? "") + ": " + problem.message)
                    .fontWeight(.semibold)
                Text("Agents are starting without your servers until it’s fixed.")
                    .appText(.fine).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Edit mcp.json") { SharedFiles.open(file) }.buttonStyle(.paper)
        }
        .padding(12)
        .background(SharedInk.attention.opacity(0.10), in: RoundedRectangle(cornerRadius: 9))
        .accessibilityElement(children: .contain)
    }
}

private struct RuntimeOnlyRow: View {
    let server: DaemonAPI.RuntimeOnlyServer
    let runtime: String

    var body: some View {
        HStack(spacing: 8) {
            Text(server.name).fontWeight(.semibold).lineLimit(1).fixedSize()
            Text("In \(SharedFiles.tilde(server.file)), for \(runtime) only")
                .foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 6)
            Button("Reveal") { SharedFiles.reveal(server.file) }.buttonStyle(.paper)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .paperRaised(in: RoundedRectangle(cornerRadius: Paper.Radius.card))
    }
}

private struct ServerDetail: View {
    let server: DaemonAPI.Server
    let isApp: Bool
    let file: String
    let runtimes: [DaemonAPI.RuntimeName]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(server.name).appText(.reading).fontWeight(.semibold)
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                SharedFact(label: server.transport == "stdio" ? "Runs" : "At", value: server.summary, code: true)
                if !server.envNames.isEmpty {
                    SharedFact(label: "Env", value: server.envNames.map { "\($0) ••••••" }.joined(separator: "\n"), code: true)
                }
                if !server.headerNames.isEmpty {
                    SharedFact(label: "Headers", value: server.headerNames.map { "\($0) ••••••" }.joined(separator: "\n"), code: true)
                }
            }
            SharedSectionLabel("Reach")
            SharedReachList(runtimes: runtimes, reach: server.reach)
            Text(isApp ? "The app’s own tools: finishing a turn, showing a file, leasing the screen and the rest. Every agent the app starts has them."
                       : "Terminal sessions you start yourself don’t get these, only agents the app starts.")
                .appText(.fine).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Spacer()
            if !isApp {
                Button("Edit mcp.json") { SharedFiles.open(file) }.buttonStyle(.paper)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
