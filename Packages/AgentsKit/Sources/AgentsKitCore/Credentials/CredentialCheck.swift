#if canImport(Security)
import Foundation

/// Asking the provider whether a credential works, when it is saved (043, FR-011, R9).
/// No `CredentialKind` case takes one now that Gemini, the only kind Settings offered
/// (056), is retired (#3043); `check` can never be called with a real `Secret` (its kind
/// is uninhabited), so this always falls through to the provider-agnostic request below.
///
/// The window's, not a daemon's: the daemons have no network code. One free call, the
/// list of models, answered 200 for a credential that works and 401 for one that does not.
/// Anything else is "can't check right now", and the credential is kept anyway: the first
/// server agent to use it is the next check.
public struct CredentialCheck: Sendable {
    public enum Answer: Equatable, Sendable {
        case works
        case refused(String)
        case cannotCheck(String)
    }

    let session: URLSession
    let timeout: TimeInterval

    public init(session: URLSession = .shared, timeout: TimeInterval = 10) {
        self.session = session
        self.timeout = timeout
    }

    public func check(_ secret: Secret) async -> Answer {
        let request = Self.request(for: secret, timeout: timeout)
        do {
            let (data, response) = try await session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            switch status {
            case 200: return .works
            case 401, 403: return .refused(Self.message(data) ?? "It refused it.")
            default: return .cannotCheck("It answered \(status).")
            }
        } catch {
            return .cannotCheck(error.localizedDescription)
        }
    }

    static func request(for secret: Secret, timeout: TimeInterval = 10) -> URLRequest {
        switch secret.kind {}
    }

    /// The `error.message` of the provider's error body, which is a sentence.
    static func message(_ data: Data) -> String? {
        struct Body: Decodable { struct E: Decodable { var message: String }; var error: E }
        return (try? JSONDecoder().decode(Body.self, from: data))?.error.message
    }
}
#endif
