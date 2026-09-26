#if canImport(Security)
import AgentsKitCore
import Foundation

/// Asking the provider whether a credential works, when it is saved (043, FR-011, R9):
/// Anthropic for Claude's, Google for Gemini's (046), OpenAI for Codex's (047).
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
    /// Google's list of models: free, and 200 for a key that works. The key goes in a
    /// header, never the URL, so no proxy log can keep it.
    public static let geminiEndpoint = URL(string: "https://generativelanguage.googleapis.com/v1beta/models?pageSize=1")!

    /// OpenAI's list of models: free, and 200 for a key that works, 401 for one that does not.
    public static let openAIEndpoint = URL(string: "https://api.openai.com/v1/models")!

    let session: URLSession
    let timeout: TimeInterval

    public init(session: URLSession = .shared, timeout: TimeInterval = 10) {
        self.session = session
        self.timeout = timeout
    }

    public func check(_ secret: Secret) async -> Answer {
        let request = Self.request(for: secret, timeout: timeout)
        let provider = switch secret.kind {
        case .geminiAPIKey: "Google"
        case .openAIAPIKey: "OpenAI"
        case .oauthToken, .apiKey: "Anthropic"
        }
        do {
            let (data, response) = try await session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            switch status {
            case 200: return .works
            case 401, 403: return .refused(Self.message(data) ?? "\(provider) refused it.")
            // Google answers a key it does not know with 400 and `API_KEY_INVALID`.
            case 400 where Self.isInvalidKey(data): return .refused(Self.message(data) ?? "Google refused it.")
            default: return .cannotCheck("\(provider) answered \(status).")
            }
        } catch {
            return .cannotCheck(error.localizedDescription)
        }
    }

    static func request(for secret: Secret, timeout: TimeInterval = 10) -> URLRequest {
        switch secret.kind {
        case .apiKey, .oauthToken:
            var request = URLRequest(url: endpoint, timeoutInterval: timeout)
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            if secret.kind == .apiKey {
                request.setValue(secret.reveal(), forHTTPHeaderField: "x-api-key")
            } else {
                request.setValue("Bearer \(secret.reveal())", forHTTPHeaderField: "Authorization")
                request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
            }
            return request
        case .geminiAPIKey:
            var request = URLRequest(url: geminiEndpoint, timeoutInterval: timeout)
            request.setValue(secret.reveal(), forHTTPHeaderField: "x-goog-api-key")
            return request
        case .openAIAPIKey:
            var request = URLRequest(url: openAIEndpoint, timeoutInterval: timeout)
            request.setValue("Bearer \(secret.reveal())", forHTTPHeaderField: "Authorization")
            return request
        }
    }

    static func isInvalidKey(_ data: Data) -> Bool {
        String(decoding: data, as: UTF8.self).contains("API_KEY_INVALID")
    }

    /// The `error.message` of the provider's error body, which is a sentence. Anthropic,
    /// Google and OpenAI all put it there.
    static func message(_ data: Data) -> String? {
        struct Body: Decodable { struct E: Decodable { var message: String }; var error: E }
        return (try? JSONDecoder().decode(Body.self, from: data))?.error.message
    }
}
#endif
