import AgentsKitCore
import AppKit
import AuthenticationServices
import SwiftUI

/// The person's agents' bot (#3858), under the GitHub row on Connectors: Make My Agents'
/// Bot… when there is none; else its name, where it is installed, Install on Repositories… and
/// Forget the Bot…. The host keeps the bot's key; this side sees only its name.
struct AgentsBotRow: View {
    @Environment(AppModel.self) private var model

    var host: MachineRef

    @State private var bot: DaemonAPI.ConnectionBot?
    @State private var making = false
    @State private var forgetting = false
    @State private var problem: String?

    var body: some View {
        HStack(spacing: 12) {
            ConnectorMark(letters: "B")
            VStack(alignment: .leading, spacing: 2) {
                Text(ConnectorSetupWords.Bot.title).appText(.supporting).fontWeight(.semibold)
                Text(problem ?? bot.map(ConnectorSetupWords.Bot.note) ?? "\u{2026}").appText(.fine)
                    .tinted(problem == nil ? .none : .failure)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if problem == nil, let keyOn = bot.flatMap(ConnectorSetupWords.Bot.keyOn) {
                    Text(keyOn).appText(.fine).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            if let bot, bot.made {
                if let install = bot.installURL {
                    Button(ConnectorSetupWords.Bot.installButton) { open(install) }.buttonStyle(.link).appText(.fine)
                }
                Button(ConnectorSetupWords.Bot.removeButton) { forgetting = true }
                    .buttonStyle(.paper).appText(.fine).tinted(.failure)
            } else if bot != nil {
                Button(ConnectorSetupWords.Bot.makeButton) { making = true }.buttonStyle(.paper).appText(.fine)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .task { await load() }
        .sheet(isPresented: $making) {
            MakeAgentsBotSheet(host: host) { made in bot = made; Task { await load() } }
        }
        .confirmationDialog(ConnectorSetupWords.Bot.removeTitle, isPresented: $forgetting, titleVisibility: .visible) {
            Button("Forget", role: .destructive) { Task { await forget() } }
        } message: {
            Text(ConnectorSetupWords.Bot.removeMessage)
        }
    }

    private func load() async {
        switch await model.agentsBot(on: host) {
        case .success(let b): bot = b; problem = nil
        case .failure(let failure): problem = failure.words
        }
    }

    private func forget() async {
        if case .failure(let failure) = await model.removeAgentsBot(on: host) { problem = failure.words; return }
        if let app = bot?.appURL { open(app) }
        await load()
    }

    private func open(_ address: String) {
        guard let url = URL(string: address) else { return }
        NSWorkspace.shared.open(url) // store-ok: github.com in the browser, not a path
    }
}

/// Make your agents' bot (#3858): the Connect Linear sheet's shape, for GitHub's App manifest
/// flow. Continue on github.com asks the host for the manifest and opens the hand-back site's
/// manifest page in an authentication session; that page posts it to GitHub, the person chooses
/// Create GitHub App, and the code comes back to agents://oauth/callback. The host takes the key.
struct MakeAgentsBotSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.webAuthenticationSession) private var session

    var host: MachineRef
    var onMade: (DaemonAPI.ConnectionBot) -> Void = { _ in }

    private enum Step: Equatable {
        case asking, waiting, finishing
        case failed(String)
    }

    @State private var step: Step = .asking
    @State private var isPublic = false

    private typealias Words = ConnectorSetupWords.Bot

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 12) {
                    ConnectorMark(letters: "B", filled: true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(Words.sheetTitle).appText(.reading).fontWeight(.semibold)
                        Text(Words.notMade).appText(.fine).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Text("The bot will be able to").appText(.fine).fontWeight(.semibold).foregroundStyle(.secondary)
                    .textCase(.uppercase)
                VStack(spacing: 0) {
                    ForEach(Array(Words.abilities.enumerated()), id: \.offset) { index, ability in
                        if index > 0 { Divider() }
                        Text(ability).appText(.supporting)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 12).padding(.vertical, 8)
                    }
                }
                .paperRaised(in: RoundedRectangle(cornerRadius: 8))
                Text(Words.never).appText(.fine).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Toggle(Words.publicToggle, isOn: $isPublic).appText(.supporting).disabled(step != .asking)
                Text(Words.publicHelp).appText(.fine).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                status
            }
            .padding(20)
            Divider()
            HStack(spacing: 8) {
                Text(Words.keyNote).appText(.fine).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button("Cancel") { dismiss() }.buttonStyle(.paper).keyboardShortcut(.cancelAction)
                switch step {
                case .asking:
                    Button(Words.continueButton) { Task { await start() } }
                        .buttonStyle(.paperProminent).keyboardShortcut(.defaultAction)
                case .failed:
                    Button("Try Again") { Task { await start() } }.buttonStyle(.paperProminent)
                default:
                    EmptyView()
                }
            }
            .padding(.horizontal, 20).padding(.vertical, 12)
        }
        .frame(width: 500)
        .paperSheet()
    }

    @ViewBuilder private var status: some View {
        switch step {
        case .asking:
            EmptyView()
        case .waiting, .finishing:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(step == .waiting ? Words.waiting : Words.finishing).appText(.fine)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Paper.accent.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
        case .failed(let why):
            Text(why).appText(.fine).tinted(.failure).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func start() async {
        step = .waiting
        let started: DaemonAPI.ConnectionBotStart
        switch await model.startAgentsBot(public: isPublic, on: host) {
        case .success(let s): started = s
        case .failure(let problem): step = .failed(problem.words); return
        }
        guard let address = started.formURL else { step = .failed("The machine gave no manifest to post."); return }
        let callback: URL
        do {
            callback = try await session.authenticate(
                using: address, callback: .customScheme(DaemonAPI.ConnectionSignInCompleteRequest.callbackScheme),
                preferredBrowserSession: nil, additionalHeaderFields: [:])
        } catch let error as ASWebAuthenticationSessionError where error.code == .canceledLogin {
            step = .asking
            return
        } catch {
            step = .failed(error.localizedDescription)
            return
        }
        guard let request = DaemonAPI.ConnectionBotCompleteRequest(callback: callback) else {
            step = .failed("GitHub came back with no answer. Try again.")
            return
        }
        step = .finishing
        switch await model.completeAgentsBot(request, on: host) {
        case .failure(let problem):
            step = .failed(problem.words)
        case .success(let bot) where !bot.made:
            step = .failed(bot.message ?? "GitHub did not make the bot. Try again.")
        case .success(let bot):
            onMade(bot)
            dismiss()
        }
    }
}
