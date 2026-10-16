import AgentsKit
import AgentsKitCore
import Foundation

/// The control plane's channels (#1012): how each is set, its secrets, and the one running.
/// Only Slack for now (#1009). Settings answers `channels/get` and `channels/set` here.
///
/// What is set lives in the store (`control.json`); the tokens live in the secrets folder,
/// `~/.agents-secrets/channels.env` (#1035), and are written, never read back.
public actor Channels: ChannelHandling {
    public struct Hooks: Sendable {
        public var settings: @Sendable () async -> ChannelSettings?
        public var save: @Sendable (ChannelSettings) async throws -> Void
        /// Every client hears `control/channelsChanged`.
        public var changed: @Sendable (DaemonAPI.ChannelsState) async -> Void
        /// A Slack channel for these tokens and member; tests give a fake Slack.
        public var slack: @Sendable (SlackChannel.Tokens, String) -> any NeedsChannel

        public init(settings: @escaping @Sendable () async -> ChannelSettings?,
                    save: @escaping @Sendable (ChannelSettings) async throws -> Void,
                    changed: @escaping @Sendable (DaemonAPI.ChannelsState) async -> Void,
                    slack: @escaping @Sendable (SlackChannel.Tokens, String) -> any NeedsChannel) {
            self.settings = settings
            self.save = save
            self.changed = changed
            self.slack = slack
        }
    }

    public static let fileName = "channels.env"
    static let appTokenName = "SLACK_APP_TOKEN"
    static let botTokenName = "SLACK_BOT_TOKEN"

    private let hooks: Hooks
    private let secrets: URL
    public let desk: ChannelDesk
    private var running: (channel: any NeedsChannel, tokens: SlackChannel.Tokens, member: String)?
    private var status = DaemonAPI.SlackState.off
    private var detail: String?

    /// `home` holds `.agents-secrets/channels.env`: the person's home for the control plane
    /// on their Mac or a server, a scratch set-up's own folder otherwise.
    public init(secretsHome home: URL, desk: ChannelDesk, hooks: Hooks) {
        secrets = PersonalSecrets.url(home: home, file: Self.fileName)
        self.desk = desk
        self.hooks = hooks
    }

    public func state() async -> DaemonAPI.ChannelsState {
        let slack = await hooks.settings()?.slack ?? SlackChannelSettings()
        let env = SecretsEnv.load(from: secrets)
        return .init(slack: .init(enabled: slack.enabled, memberID: slack.memberID,
                                  appTokenSet: env.value(of: Self.appTokenName)?.isEmpty == false,
                                  botTokenSet: env.value(of: Self.botTokenName)?.isEmpty == false,
                                  status: status, detail: detail))
    }

    public func set(_ request: DaemonAPI.ChannelsSet) async throws -> DaemonAPI.ChannelsState {
        if let change = request.slack {
            var slack = await hooks.settings()?.slack ?? SlackChannelSettings()
            if let member = change.memberID?.trimmingCharacters(in: .whitespacesAndNewlines) {
                guard member.isEmpty || SlackChannelSettings.isMemberID(member) else {
                    throw JSONRPCError(code: JSONRPCError.invalidParams,
                                       message: "That isn’t a Slack member ID. In Slack, open your profile, then ⋯ ▸ Copy member ID: it starts with U.")
                }
                slack.memberID = member
            }
            if let enabled = change.enabled { slack.enabled = enabled }
            if change.appToken != nil || change.botToken != nil {
                try saveTokens(app: change.appToken, bot: change.botToken)
            }
            try await hooks.save(ChannelSettings(slack: slack))
        }
        await apply()
        let now = await state()
        await hooks.changed(now)
        return now
    }

    /// Tokens written, trimmed; an empty one taken away. Each is checked for its kind, so a
    /// bot token pasted in the app token's place is said at once.
    private func saveTokens(app: String?, bot: String?) throws {
        var env: SecretsEnv
        do {
            env = try SecretsEnv.loadForChange(from: secrets)
        } catch {
            throw JSONRPCError(code: DaemonAPI.Failure.notPermitted,
                               message: "\(secrets.path) could not be read, so nothing was written to it. Check its permissions.")
        }
        for (name, value, prefix) in [(Self.appTokenName, app, "xapp-"), (Self.botTokenName, bot, "xoxb-")] {
            guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines) else { continue }
            if value.isEmpty {
                env.remove(name)
            } else {
                guard value.hasPrefix(prefix), !value.contains(where: \.isWhitespace) else {
                    throw JSONRPCError(code: JSONRPCError.invalidParams,
                                       message: "A Slack \(prefix == "xapp-" ? "app" : "bot") token starts with \(prefix).")
                }
                env.set(name, value: value)
            }
        }
        try env.save(to: secrets)
    }

    /// Slack running as set: started, restarted with new tokens or member, or stopped.
    public func apply() async {
        let slack = await hooks.settings()?.slack ?? SlackChannelSettings()
        let env = SecretsEnv.load(from: secrets)
        let app = env.value(of: Self.appTokenName) ?? "", bot = env.value(of: Self.botTokenName) ?? ""
        var wanted: (tokens: SlackChannel.Tokens, member: String)?
        var why: String?
        if slack.enabled {
            if app.isEmpty || bot.isEmpty {
                why = "Set both Slack tokens."
            } else if !SlackChannelSettings.isMemberID(slack.memberID) {
                why = "Set your Slack member ID."
            } else {
                wanted = (SlackChannel.Tokens(app: app, bot: bot), slack.memberID)
            }
        }
        if let running, let wanted, running.tokens.app == wanted.tokens.app, running.tokens.bot == wanted.tokens.bot,
           running.member == wanted.member {
            return
        }
        if let running {
            await running.channel.stop()
            await desk.use(nil)
            self.running = nil
        }
        guard let wanted else {
            await report(why == nil ? DaemonAPI.SlackState.off : DaemonAPI.SlackState.failed, why)
            return
        }
        let channel = hooks.slack(wanted.tokens, wanted.member)
        running = (channel, wanted.tokens, wanted.member)
        await desk.use(channel)
        let desk = self.desk
        await channel.start(heard: { reply in await desk.heard(reply) },
                            status: { [weak self] status in await self?.heard(status, from: channel) })
    }

    public func stop() async {
        await running?.channel.stop()
        running = nil
        await desk.use(nil)
    }

    private func heard(_ change: ChannelStatus, from channel: any NeedsChannel) async {
        guard running?.channel === channel else { return }
        switch change {
        case .connecting: await report(DaemonAPI.SlackState.connecting, nil)
        case .connected: await report(DaemonAPI.SlackState.connected, nil)
        case .failed(let words): await report(DaemonAPI.SlackState.failed, words)
        }
    }

    private func report(_ status: String, _ detail: String?) async {
        guard status != self.status || detail != self.detail else { return }
        self.status = status
        self.detail = detail
        await hooks.changed(await state())
    }
}
