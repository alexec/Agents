import Foundation
import Testing
@testable import AgentsKitCore

/// The web remote is typed against what a person's connection may ask, and none of an
/// agent's tools (071, research R6; one grant since #111).
@Suite("Web signatures")
struct WebSignaturesTests {
    typealias Rows = DaemonAPI.WebSignatures

    @Test func everyHostRequestIsOneADeviceMayMakeAndNoAgentTool() {
        let requests = Rows.rows.filter { $0.kind == .hostRequest }.map(\.method)
        #expect(requests.filter { !ConnectionRole.device.allows($0) } == [])
        let tools = ConnectionRole.agentMethods.subtracting(ConnectionRole.strangerMethods)
        #expect(Set(requests).isDisjoint(with: tools), "an agent's tool: \(Set(requests).intersection(tools))")
    }

    /// Every method name in `DaemonAPI.Method`, read from its source.
    static let everyMethod: [String] = {
        let source = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/AgentsKitCore/Daemon/DaemonAPI.swift")
        guard let text = try? String(contentsOf: source, encoding: .utf8),
              let start = text.range(of: "public enum Method {"),
              let end = text.range(of: "public enum Notification {") else { return [] }
        let body = String(text[start.upperBound..<end.lowerBound])
        let pattern = try! NSRegularExpression(pattern: #"static let \w+ = "([^"]+)""#)
        return pattern.matches(in: body, range: NSRange(body.startIndex..., in: body)).compactMap {
            Range($0.range(at: 1), in: body).map { String(body[$0]) }
        }
    }()

    @Test func noMethodIsListedTwice() {
        let methods = Rows.rows.map(\.method)
        #expect(methods.count == Set(methods).count)
    }

    @Test func notificationsAreNotRequests() {
        let notifications = Set(Rows.rows.filter { $0.kind == .hostNotification || $0.kind == .controlNotification }
            .map(\.method))
        #expect(notifications.isDisjoint(with: Set(Self.everyMethod)))
        #expect(notifications.contains(DaemonAPI.Notification.agentEntry))
    }

    /// The page branches a session as the window does, and opens the new one by its id (#342).
    @Test func thePageBranchesASession() {
        #expect(Rows.rows.contains { $0.method == DaemonAPI.Method.agentsFork && $0.kind == .hostRequest
            && $0.params == DaemonAPI.AgentRequest.self && $0.result == UUID.self })
    }

    /// The page offers a sign-in on its own connection, as the Remote does (#344).
    @Test func thePageOffersASignIn() {
        let rows = Rows.rows
        #expect(rows.contains { $0.method == DaemonAPI.Method.credentialsOffer && $0.kind == .hostRequest
            && $0.params == DaemonAPI.CredentialsOffer.self })
    }

    /// The page asks what the host could not read and hears it change, as the window does (#223).
    @Test func thePageAsksAndHearsStoreNotes() {
        let rows = Rows.rows
        #expect(rows.contains { $0.method == DaemonAPI.Method.storeNotes && $0.kind == .hostRequest
            && $0.result == DaemonAPI.StoreNotes.self })
        #expect(rows.contains { $0.method == DaemonAPI.Notification.storeNotesChanged && $0.kind == .hostNotification
            && $0.params == DaemonAPI.StoreNotes.self })
    }
}
