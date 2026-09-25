#if canImport(Security)
import AgentsKitCore
import Foundation

/// Asking Anthropic whether a Claude credential works, when it is saved (043, FR-011, R9).
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

    public static let endpoint = URL(string: "https://api.anthropic.com/v1/models?limit=1")!

    let session: URLSession
    let timeout: TimeInterval

    public init(session: URLSession = .shared, timeout: TimeInterval = 10) {
        self.session = session
        self.timeout = timeout
    }

    public func check(_ secret: Secret) async -> Answer {
        var request = URLRequest(url: Self.endpoint, timeoutInterval: timeout)
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        switch secret.kind {
        case .apiKey:
            request.setValue(secret.reveal(), forHTTPHeaderField: "x-api-key")
        case .oauthToken:
            request.setValue("Bearer \(secret.reveal())", forHTTPHeaderField: "Authorization")
            request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        }
        do {
            let (data, response) = try await session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            switch status {
            case 200: return .works
            case 401, 403: return .refused(Self.message(data) ?? "Anthropic refused it.")
            default: return .cannotCheck("Anthropic answered \(status).")
            }
        } catch {
            return .cannotCheck(error.localizedDescription)
        }
    }

    /// The `error.message` of Anthropic's error body, which is a sentence.
    static func message(_ data: Data) -> String? {
        struct Body: Decodable { struct E: Decodable { var message: String }; var error: E }
        return (try? JSONDecoder().decode(Body.self, from: data))?.error.message
    }
}
#endif
