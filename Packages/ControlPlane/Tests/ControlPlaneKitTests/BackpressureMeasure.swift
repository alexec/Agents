import AgentsKit
import AgentsKitCore
@testable import ControlDial
@testable import ControlPlaneKit
import Darwin
import Foundation
import NIOCore
import Testing

/// The numbers for #167, not a check: one copy of the service on loopback, a real host behind
/// a real uplink, 20 paired clients that read everything and one that stops reading, and a
/// flood of host notifications. Run with `AGENTS_MEASURE_167=1`; it prints a line per number
/// and writes them to `/tmp/167-measure-<AGENTS_MEASURE_LABEL>.json`.
@Suite("Backpressure, measured (#167)", .serialized, .timeLimit(.minutes(5)),
       .enabled(if: ProcessInfo.processInfo.environment["AGENTS_MEASURE_167"] == "1"))
struct BackpressureMeasure {
    static let fastClients = 20
    static let events = 10_000
    static let padding = 2_000

    final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var lines = 0
        private var bytes = 0
        func add(_ line: String) { lock.withLock { lines += 1; bytes += line.utf8.count } }
        var count: Int { lock.withLock { lines } }
        var total: Int { lock.withLock { bytes } }
    }

    /// The host's uplink, counted as it writes.
    final class CountingTransport: LineTransport, ReasonedClose, @unchecked Sendable {
        let base: PrefixReader
        let written: Counter
        init(_ base: PrefixReader, counting written: Counter) { self.base = base; self.written = written }
        func write(line: String) throws { written.add(line); try base.write(line: line) }
        func lines() -> AsyncThrowingStream<String, any Error> { base.lines() }
        func close() { base.close() }
        func close(code: UInt16, reason: String) { base.close(code: code, reason: reason) }
    }

    final class Box<T>: @unchecked Sendable {
        private let lock = NSLock()
        private var value: T
        init(_ value: T) { self.value = value }
        var now: T { get { lock.withLock { value } } set { lock.withLock { value = newValue } } }
    }

    static func footprint() -> Int {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? Int(info.phys_footprint) : 0
    }

    static func buffered(_ socket: WebSocketLineTransport) -> Int {
        guard socket.channel.isActive else { return 0 }
        return (try? socket.channel.getOption(ChannelOptions.bufferedWritableBytes).wait()) ?? 0
    }

    @Test func twentyClientsReadingAndOneThatStops() async throws {
        let t = ControlServiceTests()
        let running = try await t.start()
        defer { Task { await running.service.stop() } }

        // The host.
        let key = ControlAgreement.generate()
        let announced = try await t.use(try await running.service.codes.issue(.host).text, at: running.url,
                                        method: DaemonAPI.Method.hostsAnnounce, params: try JSONValue.encoding(
            DaemonAPI.HostAnnounce(publicKey: key.publicKey, name: "devbox", platform: "Linux arm64", version: "1",
                                   machineID: "linux-1")))
        let host = try #require(try announced.decode(DaemonAPI.Admitted.self).host)
        let server = DaemonServer(url: URL(fileURLWithPath: "/tmp/unused-\(UUID()).sock")) { _, _, _ in .success(["ok": true]) }
        let hostKey = try ControlAuth.hostKey(privateKey: key.privateKey, peer: t.control.publicKey, host: host)
        // Counted across redials: an uplink that falls behind may be dropped and dialled again.
        let uplinkWritten = Counter()
        let dials = Counter()
        let uplinkSocket = Box<WebSocketLineTransport?>(nil)
        let url = running.url
        let control = t.control
        let uplink = ControlUplink(server: server, hello: DaemonAPI.HostHello(host: host, version: "1", platform: "Linux arm64",
                                                                             machineID: "linux-1")) {
            let socket = try await ControlDial.connect(url)
            // As `ControlJoin.hostDial` sets it, where it can be set (#167).
            socket.outboundLimit = WebSocketLineTransport.uplinkOutboundLimit
            uplinkSocket.now = socket
            let joined = try await ControlAuth.join(socket, origin: ControlAuth.origin(url)!, as: .init(
                identity: .host(host), key: hostKey, kind: "host", controlKey: control.publicKey)).transport
            dials.add("")
            return CountingTransport(joined, counting: uplinkWritten)
        }
        uplink.start()
        defer { uplink.stop() }
        await eventually { await running.service.router.state(of: host)?.isOnline == true }

        // The clients: each asks the host one thing, so it speaks the wrapped wire, then
        // counts what it hears.
        func joinClient() async throws -> (WebSocketLineTransport, PrefixReader) {
            let (_, _, credentials) = try await t.pairedClient(at: url, code: try await running.service.codes.issue(.client).text,
                                                               kind: .iPhone)
            let socket = try await ControlDial.connect(url)
            let reader = try await ControlAuth.join(socket, origin: ControlAuth.origin(url)!, as: credentials).transport
            let ping = try JSONRPCCodec.encode(.request(id: .number(1), method: DaemonAPI.Method.ping, params: nil))
            try reader.write(line: ControlWire.wrap(host: host, message: ping))
            _ = try #require(try await reader.next(within: 10))
            return (socket, reader)
        }
        var heard: [Counter] = []
        for _ in 0..<Self.fastClients {
            let (_, reader) = try await joinClient()
            let counter = Counter()
            heard.append(counter)
            Task { do { for try await line in reader.lines() { counter.add(line) } } catch {} }
        }
        let (slowSocket, _) = try await joinClient()
        try await slowSocket.channel.setOption(ChannelOptions.autoRead, value: false).get()
        await eventually { server.connectionCount == Self.fastClients + 1 }

        // Sampled while the flood runs.
        let baseline = Self.footprint()
        let peakFootprint = Box(baseline)
        let peakPlaneQueue = Box(0)
        let peakUplinkQueue = Box(0)
        let sampling = Box(true)
        let service = running.service
        let sampler = Task.detached {
            while sampling.now {
                peakFootprint.now = max(peakFootprint.now, Self.footprint())
                let plane = service.sockets.all.map(Self.buffered).max() ?? 0
                peakPlaneQueue.now = max(peakPlaneQueue.now, plane)
                if let socket = uplinkSocket.now { peakUplinkQueue.now = max(peakUplinkQueue.now, Self.buffered(socket)) }
                try? await Task.sleep(for: .milliseconds(20))
            }
        }

        let before = uplinkWritten.count
        let beforeBytes = uplinkWritten.total
        let dialsBefore = dials.count
        let pad = String(repeating: "x", count: Self.padding)
        let started = Date()
        for index in 0..<Self.events {
            server.broadcast(DaemonAPI.Notification.agentChanged, ["n": .int(index), "pad": .string(pad)])
        }
        let deadline = Date().addingTimeInterval(180)
        while Date() < deadline, heard.contains(where: { $0.count < Self.events }) {
            try await Task.sleep(for: .milliseconds(50))
        }
        let delivered = Date().timeIntervalSince(started)
        try await Task.sleep(for: .seconds(3))
        sampling.now = false
        _ = await sampler.value
        let settledFootprint = Self.footprint()
        let settledPlaneQueue = running.service.sockets.all.map(Self.buffered).max() ?? 0
        let uplinkLines = uplinkWritten.count - before
        let uplinkBytes = uplinkWritten.total - beforeBytes

        let mb = { (bytes: Int) in (Double(bytes) / 1_048_576 * 10).rounded() / 10 }
        let numbers: [String: JSONValue] = [
            "events": .int(Self.events),
            "fastClients": .int(Self.fastClients),
            "uplinkLinesPerEvent": .double(Double(uplinkLines) / Double(Self.events)),
            "uplinkMBTotal": .double(mb(uplinkBytes)),
            "uplinkRedials": .int(dials.count - dialsBefore),
            "fastClientsHeardAll": .bool(heard.allSatisfy { $0.count >= Self.events }),
            "fastMinHeard": .int(heard.map(\.count).min() ?? 0),
            "secondsToDeliver": .double((delivered * 10).rounded() / 10),
            "slowClientClosedByPlane": .bool(await running.service.router.sessionCount == Self.fastClients),
            "peakFootprintGrowthMB": .double(mb(peakFootprint.now - baseline)),
            "settledFootprintGrowthMB": .double(mb(settledFootprint - baseline)),
            "peakPlaneQueueMB": .double(mb(peakPlaneQueue.now)),
            "settledPlaneQueueMB": .double(mb(settledPlaneQueue)),
            "peakUplinkQueueMB": .double(mb(peakUplinkQueue.now)),
        ]
        for (key, value) in numbers.sorted(by: { $0.key < $1.key }) { print("167-measure \(key) = \(value)") }
        let label = ProcessInfo.processInfo.environment["AGENTS_MEASURE_LABEL"] ?? "run"
        let data = try JSONEncoder().encode(JSONValue.object(numbers))
        try data.write(to: URL(fileURLWithPath: "/tmp/167-measure-\(label).json"))
    }
}
