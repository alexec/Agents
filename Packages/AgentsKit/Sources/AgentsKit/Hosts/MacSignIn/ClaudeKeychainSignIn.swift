#if canImport(Network) && canImport(Security)
import Foundation

/// Claude's own sign-in on this Mac (056, research R5): the Keychain item `claude` keeps,
/// read the way `claude` writes it, with `/usr/bin/security`, so no prompt is raised. The
/// app only ever reads it. It never writes, renews or deletes it (R6).
///
/// A read costs about 17 ms (T016), so the token is kept until a minute before it expires;
/// a failed read is remembered for a few seconds, so Settings drawing a line does not start
/// a process each time.
public final class ClaudeKeychainSignIn: MacSignInSource, @unchecked Sendable {
    /// What a server's Claude starts with: shaped like a subscription token, so Claude sends
    /// the subscription's headers, and worth nothing anywhere but through the relay.
    public static let standInToken = "sk-ant-oat01-agents-relay-standin"

    /// The item's text, or the reason there is none.
    public typealias Reader = @Sendable () throws -> Data
    /// Asks the Mac's own Claude to renew its sign-in, however it does (R6); returns when it
    /// has finished or given up. The item is read again afterwards either way.
    public typealias Renewer = @Sendable () async -> Void

    private let read: Reader
    private let renewer: Renewer
    private var renewing: Task<Void, Never>?
    private let now: @Sendable () -> Date
    private let lock = NSLock()
    private var cached: (token: MacSignInToken, expires: Date)?
    private var failed: (at: Date, why: MacSignInFailure)?

    public init(service: String, renewer: @escaping Renewer = ClaudeKeychainSignIn.askTheMacsClaude) {
        read = { try Self.readKeychain(service: service) }
        now = { Date() }
        self.renewer = renewer
    }

    init(reader: @escaping Reader, now: @escaping @Sendable () -> Date = { Date() },
         renewer: @escaping Renewer = {}) {
        read = reader
        self.now = now
        self.renewer = renewer
    }

    public var isSignedIn: Bool { (try? current()) != nil }

    /// Why this Mac cannot lend its sign-in right now, or nil when it can.
    public var whyNot: MacSignInFailure? {
        do { _ = try current(); return nil } catch let failure as MacSignInFailure { return failure } catch { return .unreadable }
    }

    public func current() throws -> MacSignInToken {
        lock.lock()
        defer { lock.unlock() }
        let now = now()
        if let cached, now < cached.expires.addingTimeInterval(-60) { return cached.token }
        if let failed, now.timeIntervalSince(failed.at) < 5 { throw failed.why }
        return try fresh(at: now)
    }

    /// `stale` was refused. Whatever the Keychain holds now is read afresh: if the Mac's own
    /// Claude renewed it already, that is used and nothing is spent. Otherwise the Mac's
    /// Claude is asked to renew it, once however many requests are waiting, and the item is
    /// read again. The app never renews or writes the item itself (D4, R6).
    public func renew(after stale: MacSignInToken) async throws -> MacSignInToken {
        if let token = try? lock.withLock({ try fresh(at: now()) }), token.access != stale.access { return token }
        let task = lock.withLock { () -> Task<Void, Never> in
            if let renewing { return renewing }
            let made = Task { [renewer] in await renewer() }
            renewing = made
            return made
        }
        await task.value
        lock.withLock { if renewing == task { renewing = nil } }
        let token = try lock.withLock { try fresh(at: now()) }
        guard token.access != stale.access else { throw MacSignInFailure.renewalRefused(401) }
        return token
    }

    /// The command the Mac's own Claude is asked to renew with (research R6, measured by
    /// T035): Claude checks its sign-in on the way and renews one near or past its expiry.
    public static let renewArguments = ["auth", "status"]

    /// Run the Mac's own `claude`, found on the login shell's PATH, with `renewArguments`,
    /// and give up after 30 seconds.
    public static let askTheMacsClaude: Renewer = {
        let environment = LoginShellPath.environment()
        let path = (environment["PATH"] ?? "/usr/bin:/bin").split(separator: ":").map(String.init)
        guard let claude = path.map({ URL(fileURLWithPath: $0).appendingPathComponent("claude") })
            .first(where: { FileManager.default.isExecutableFile(atPath: $0.path) }) else { return }
        let process = Process()
        process.executableURL = claude
        process.arguments = renewArguments
        process.environment = environment
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            let once = OnceFlag()
            process.terminationHandler = { _ in if once.take() { done.resume() } }
            do { try process.run() } catch { if once.take() { done.resume() }; return }
            DispatchQueue.global().asyncAfter(deadline: .now() + 30) {
                if process.isRunning { process.terminate() }
            }
        }
    }

    public func standIn() throws -> String { Self.standInToken }

    /// Read, parse and remember. Called with the lock held.
    private func fresh(at now: Date) throws -> MacSignInToken {
        do {
            let (token, expires) = try Self.parse(try read())
            cached = (token, expires)
            failed = nil
            return token
        } catch {
            let why = error as? MacSignInFailure ?? .unreadable
            cached = nil
            failed = (now, why)
            throw why
        }
    }

    /// The item as `claude` writes it: `claudeAiOauth.accessToken`, `expiresAt` in
    /// milliseconds, and `scopes`, which must include inference (D3).
    static func parse(_ data: Data) throws -> (MacSignInToken, Date) {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw MacSignInFailure.unreadable
        }
        guard let oauth = object["claudeAiOauth"] as? [String: Any],
              let access = oauth["accessToken"] as? String, !access.isEmpty,
              (oauth["scopes"] as? [String] ?? []).contains("user:inference") else {
            throw MacSignInFailure.notSignedIn
        }
        let expires = (oauth["expiresAt"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue / 1000) }
            ?? .distantFuture
        return (MacSignInToken(access: access), expires)
    }

    /// `security find-generic-password -s <service> -w`: 44 is "no such item".
    static func readKeychain(service: String) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["find-generic-password", "-s", service, "-w"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        let done = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in done.signal() }
        do { try process.run() } catch { throw MacSignInFailure.unreadable }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        if done.wait(timeout: .now() + 10) == .timedOut {
            process.terminate()
            throw MacSignInFailure.unreadable
        }
        switch process.terminationStatus {
        case 0: return data
        case 44: throw MacSignInFailure.notSignedIn
        default: throw MacSignInFailure.unreadable
        }
    }
}
#endif
