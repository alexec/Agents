#if canImport(CryptoKit)
import CryptoKit
import Foundation
import Testing
@testable import AgentsKitCore

/// Requests checked end to end (#3492): the keys, MACs and signatures are Go's
/// (`Fixtures/lock/channel.json`, from TestTheChannelVectors, which the web page's
/// lockChannel.test.mjs reads too), and a host's link opens a channel to a machine of its lock,
/// MACs each call, and takes an answer only with the machine's MAC.
@Suite("Lock channel")
struct LockChannelTests {
    struct Request: Decodable {
        var method: String
        var params: String
        var lock: DaemonAPI.LockSignature
    }

    struct Vectors: Decodable {
        var clientKey: Data
        var hello: DaemonAPI.LockHello
        var clientEphemeralPrivate: Data
        var machineKey: Data
        var reply: DaemonAPI.LockHelloReply
        var machineEphemeralPrivate: Data
        var clientSends: Data
        var machineSends: Data
        var message: String
        var sealed: String
        var answer: String
        var answerSealed: String
        var request: Request
    }

    static func vectors() throws -> Vectors {
        let url = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Fixtures/lock/channel.json")
        return try JSONDecoder().decode(Vectors.self, from: Data(contentsOf: url))
    }

    @Test func gosHellosKeysMACsAndSignedRequestCheckHere() throws {
        let v = try Self.vectors()
        #expect(LockChannel.verify(v.clientKey, LockChannel.clientHelloData(v.hello.ephemeral), v.hello.sig))
        #expect(LockChannel.verify(v.machineKey, LockChannel.machineHelloData(v.hello.ephemeral, v.reply.ephemeral, v.clientKey), v.reply.sig))
        let mine = try P256.KeyAgreement.PrivateKey(rawRepresentation: v.clientEphemeralPrivate)
        let shared = try mine.sharedSecretFromKeyAgreement(with: P256.KeyAgreement.PublicKey(x963Representation: v.reply.ephemeral))
        let keys = LockChannel.keys(shared, clientEphemeral: v.hello.ephemeral, machineEphemeral: v.reply.ephemeral)
        #expect(keys.client.withUnsafeBytes { Data($0) } == v.clientSends)
        #expect(keys.machine.withUnsafeBytes { Data($0) } == v.machineSends)
        #expect(LockChannel.Channel(send: keys.client, hear: keys.machine, sent: 41).seal(v.message) == v.sealed)
        let answers = LockChannel.Channel(send: keys.client, hear: keys.machine)
        #expect(try answers.open(v.answerSealed) == v.answer)
        #expect(throws: LockChannel.Failure.replayed) { try answers.open(v.answerSealed) }
        #expect(throws: LockChannel.Failure.badMAC) { try LockChannel.Channel(send: keys.client, hear: keys.machine).open(v.sealed) }
        let data = LockChannel.requestData(to: v.request.lock.to ?? "", at: v.request.lock.at, method: v.request.method, params: v.request.params)
        #expect(LockChannel.verify(v.request.lock.key, data, v.request.lock.sig))
    }

    /// A machine's end of a host's link, in memory: what the client wrote, and lines to send it.
    final class Machine: LineTransport, @unchecked Sendable {
        private let lock = NSLock()
        private var written: [String] = []
        let stream: AsyncThrowingStream<String, any Error>
        let say: AsyncThrowingStream<String, any Error>.Continuation

        init() {
            var c: AsyncThrowingStream<String, any Error>.Continuation!
            stream = AsyncThrowingStream(bufferingPolicy: .unbounded) { c = $0 }
            say = c
        }

        func write(line: String) throws { lock.withLock { written.append(line) } }
        func lines() -> AsyncThrowingStream<String, any Error> { stream }
        func close() { say.finish() }

        func line(_ i: Int) async -> String {
            for _ in 0..<200 {
                if let line = lock.withLock({ written.count > i ? written[i] : nil }) { return line }
                try? await Task.sleep(for: .milliseconds(10))
            }
            Issue.record("no line \(i)")
            return ""
        }
    }

    struct Fixed: DaemonLink {
        let machine: Machine
        func transport() async throws -> any LineTransport { machine }
    }

    /// The person's lock with this device and the machine m-1, and the machine's key.
    static func lockWithMachine() throws -> (LockChannel.Signer, P256.Signing.PrivateKey) {
        let device = LockSigningKey.ephemeral()
        let machine = P256.Signing.PrivateKey()
        let root = try MachineLock.sign(DaemonAPI.LockBody(kind: .root, person: "sam", key: device.publicKey), after: nil, with: device)
        var state = try MachineLock.check([root])
        let add = try MachineLock.sign(DaemonAPI.LockBody(kind: .addMachine, person: "sam", key: machine.publicKey.x963Representation,
                                                          sealingKey: machine.publicKey.x963Representation, id: "m-1"), after: state, with: device)
        state = try MachineLock.check([root, add])
        return (LockChannel.Signer(key: device, state: state), machine)
    }

    /// The machine's answer to a hello, and its side of the channel.
    static func answer(_ hello: DaemonAPI.LockHello, as machine: P256.Signing.PrivateKey) throws -> (DaemonAPI.LockHelloReply, LockChannel.Channel) {
        let ephemeral = P256.KeyAgreement.PrivateKey()
        let raw = ephemeral.publicKey.x963Representation
        let sig = try machine.signature(for: LockChannel.machineHelloData(hello.ephemeral, raw, hello.key)).rawRepresentation
        let shared = try ephemeral.sharedSecretFromKeyAgreement(with: P256.KeyAgreement.PublicKey(x963Representation: hello.ephemeral))
        let keys = LockChannel.keys(shared, clientEphemeral: hello.ephemeral, machineEphemeral: raw)
        return (DaemonAPI.LockHelloReply(key: machine.publicKey.x963Representation, ephemeral: raw, sig: sig),
                LockChannel.Channel(send: keys.machine, hear: keys.client))
    }

    @Test func aCallToAMachineOfTheLockGoesOnAChannelAndItsAnswerIsTakenOnlyWithItsMAC() async throws {
        let (signer, machineKey) = try Self.lockWithMachine()
        let machine = Machine()
        let link = LockedLink(Fixed(machine: machine), host: MachineRef(rawValue: "m-1")) { signer }
        let opening = Task { try await link.transport() }
        guard case .request(let helloID, let method, let params?)? = try? JSONRPCCodec.decode(line: await machine.line(0)) else {
            Issue.record("no hello")
            return
        }
        #expect(method == "lock/hello")
        let (reply, channel) = try Self.answer(try params.decode(DaemonAPI.LockHello.self), as: machineKey)
        machine.say.yield(try JSONRPCCodec.encode(.success(id: helloID, result: try JSONValue.encoding(reply))))
        let transport = try await opening.value
        var heard = transport.lines().makeAsyncIterator()

        try transport.write(line: try JSONRPCCodec.encode(.request(id: .number(1), method: "folders/list", params: .object([:]))))
        let sent = await machine.line(1)
        #expect(LockChannel.sealed(sent))
        guard case .request(.number(1), "folders/list", _)? = try? JSONRPCCodec.decode(line: try channel.open(sent)) else {
            Issue.record("not the request: \(sent)")
            return
        }
        // The control plane answers in the machine's name: not taken.
        machine.say.yield(#"{"id":1,"jsonrpc":"2.0","result":[{"forged":true}]}"#)
        guard case .failure(_, let error) = try JSONRPCCodec.decode(line: try #require(try await heard.next())) else {
            Issue.record("a forged answer was taken")
            return
        }
        #expect(error.code == DaemonAPI.Failure.notInLock)

        // The machine's own answer is taken, without its MAC.
        try transport.write(line: try JSONRPCCodec.encode(.request(id: .number(2), method: "folders/list", params: .object([:]))))
        _ = try channel.open(await machine.line(2))
        machine.say.yield(channel.seal(#"{"id":2,"jsonrpc":"2.0","result":[]}"#))
        #expect(try await heard.next() == #"{"id":2,"jsonrpc":"2.0","result":[]}"#)

        // What the machine says unasked is taken only with its MAC (#3541): the control plane
        // shows a card the machine did not raise, and changes one it did; neither is taken.
        machine.say.yield(#"{"jsonrpc":"2.0","method":"agent/changed","params":{"id":"forged"}}"#)
        machine.say.yield(channel.seal(#"{"jsonrpc":"2.0","method":"agent/changed","params":{"id":"realer"}}"#)
            .replacingOccurrences(of: "realer", with: "forged"))
        machine.say.yield(channel.seal(#"{"jsonrpc":"2.0","method":"agent/changed","params":{"id":"real"}}"#))
        #expect(try await heard.next() == #"{"jsonrpc":"2.0","method":"agent/changed","params":{"id":"real"}}"#)
        // The control plane's own notifications are not the machine's.
        machine.say.yield(#"{"jsonrpc":"2.0","method":"control/cutOff","params":{}}"#)
        #expect(try await heard.next() == #"{"jsonrpc":"2.0","method":"control/cutOff","params":{}}"#)
        transport.close()
    }

    @Test func withNoChannelAPromptGoesSignedForItsMachine() async throws {
        let (signer, _) = try Self.lockWithMachine()
        let machine = Machine()
        let link = LockedLink(Fixed(machine: machine), host: MachineRef(rawValue: "m-1")) { signer }
        let opening = Task { try await link.transport() }
        guard case .request(let helloID, _, _)? = try? JSONRPCCodec.decode(line: await machine.line(0)) else { return }
        machine.say.yield(try JSONRPCCodec.encode(.failure(id: helloID, error: JSONRPCError(code: -32090, message: "That machine is offline."))))
        let transport = try await opening.value
        try transport.write(line: try JSONRPCCodec.encode(.request(id: .number(1), method: "agents/prompt",
                                                                   params: .object(["agentID": .string("A"), "text": .string("go <b>/")]))))
        let sent = await machine.line(1)
        let object = try #require(try JSONValue.parse(Data(sent.utf8)).objectValue)
        let signature = try #require(try object["lock"]?.decode(DaemonAPI.LockSignature.self))
        let params = try #require(sent.range(of: #""params":"#).map { sent[$0.upperBound...] })
        let text = String(params.prefix(upTo: try #require(params.range(of: #","lock":"#)).lowerBound))
        #expect(signature.to == "m-1")
        #expect(LockChannel.verify(signature.key, LockChannel.requestData(to: "m-1", at: signature.at, method: "agents/prompt", params: text), signature.sig))
        transport.close()
    }

    /// A transport opened before the machine held its lock (#3642): the machine refuses its next
    /// request, and the transport opens a channel then, so the request after it is sealed.
    @Test func aMachineThatTookItsLockAfterTheTransportOpenedGetsAChannelAtItsFirstRefusal() async throws {
        let (signer, machineKey) = try Self.lockWithMachine()
        let machine = Machine()
        let link = LockedLink(Fixed(machine: machine), host: MachineRef(rawValue: "m-1")) { signer }
        let opening = Task { try await link.transport() }
        guard case .request(let firstHello, _, _)? = try? JSONRPCCodec.decode(line: await machine.line(0)) else {
            Issue.record("no hello")
            return
        }
        machine.say.yield(try JSONRPCCodec.encode(.failure(id: firstHello, error: JSONRPCError(code: -32601, message: "This machine holds no lock yet."))))
        let transport = try await opening.value
        var heard = transport.lines().makeAsyncIterator()

        try transport.write(line: try JSONRPCCodec.encode(.request(id: .number(1), method: "folders/list", params: .object([:]))))
        #expect(!LockChannel.sealed(await machine.line(1)))
        // The machine took its lock: it refuses the request, and a hello goes again.
        machine.say.yield(try JSONRPCCodec.encode(.failure(id: .number(1), error: JSONRPCError(code: DaemonAPI.Failure.notInLock,
                                                                                                 message: "not signed"))))
        guard case .failure(_, let refused) = try JSONRPCCodec.decode(line: try #require(try await heard.next())) else {
            Issue.record("the refusal was not passed on")
            return
        }
        #expect(refused.code == DaemonAPI.Failure.notInLock)
        guard case .request(let helloID, "lock/hello", let params?)? = try? JSONRPCCodec.decode(line: await machine.line(2)) else {
            Issue.record("no hello again")
            return
        }
        #expect(helloID != firstHello)
        let (reply, channel) = try Self.answer(try params.decode(DaemonAPI.LockHello.self), as: machineKey)
        machine.say.yield(try JSONRPCCodec.encode(.success(id: helloID, result: try JSONValue.encoding(reply))))

        // Wait until the channel is made from the answer, then the next request is sealed.
        var sent = ""
        for id in 2..<200 {
            try transport.write(line: try JSONRPCCodec.encode(.request(id: .number(id), method: "folders/list", params: .object([:]))))
            sent = await machine.line(id + 1)
            if LockChannel.sealed(sent) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(LockChannel.sealed(sent))
        guard case .request(_, "folders/list", _)? = try? JSONRPCCodec.decode(line: try channel.open(sent)) else {
            Issue.record("not the request: \(sent)")
            return
        }
        transport.close()
    }

    @Test func aDeviceNotInItsLockCallsMachinesAsBefore() async throws {
        let machine = Machine()
        let link = LockedLink(Fixed(machine: machine), host: MachineRef(rawValue: "m-1")) { nil }
        let transport = try await link.transport()
        #expect(transport is Machine)
    }
}
#endif
