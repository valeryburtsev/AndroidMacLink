import Foundation

/// Tries the way over the internet without the phone: two sockets on this computer find each
/// other through the real servers, one of them allowed nothing but the relay, and datagrams
/// are sent both ways. What it shows is that the servers take this code's requests: the
/// address question, the relay account's sign-in, permissions, channels and relayed data.
public enum IceSelfTest {
    /// - Returns: A line for the log; no address in it.
    public static func run(servers: NanoRelayServers, datagrams: Int = 40, size: Int = 1100) async -> String {
        let started = Date()
        let stun = await IceUDPSocket.resolve(servers.stun)
        let turn = await IceUDPSocket.resolve(servers.turn)
        guard stun != nil || turn != nil else { return "the servers could not be looked up" }
        guard let first = try? IceUDPSocket(toward: stun ?? turn), let second = try? IceUDPSocket(toward: stun ?? turn) else { return "no socket" }
        let account = IceAgent.Servers(stun: stun, turn: turn, username: servers.username, password: servers.password)
        var strict = IceAgent.Settings()
        strict.onlyRelayed = true
        let computer = IceAgent(socket: first, servers: account, settings: strict)
        let other = IceAgent(socket: second, role: .controlled, servers: account)
        await computer.gather()
        await other.gather()
        let own = await computer.local, theirs = await other.local
        let kinds = own.candidates.map { "\($0.kind)" }.joined(separator: ",")
        defer {
            Task {
                await computer.close()
                await other.close()
            }
        }
        guard own.candidates.contains(where: { $0.kind == .relay }) else { return "gathered \(kinds): no relay address, after \(elapsed(started))" }
        async let otherSide = try? other.connect(to: own)
        async let computerSide = try? computer.connect(to: theirs)
        guard let out = await computerSide, let back = await otherSide else {
            return "gathered \(kinds); no path through the relay, after \(elapsed(started))"
        }
        let chosen = await computer.selected?.name ?? "?"
        let payload = Data([0x80, 0x66] + (0..<max(2, size) - 2).map { UInt8(truncatingIfNeeded: $0) })
        async let there = count(back.incoming, expecting: datagrams)
        async let here = count(out.incoming, expecting: datagrams)
        for _ in 0..<datagrams {
            try? await out.send(payload)
            try? await back.send(payload)
            try? await Task.sleep(for: .milliseconds(5))
        }
        let arrived = await there, returned = await here
        return "gathered \(kinds); path \(chosen); \(arrived) of \(datagrams) datagrams of \(size) bytes arrived through the relay, \(returned) came back; \(elapsed(started))"
    }

    private static func elapsed(_ start: Date) -> String { String(format: "%.1f s", Date().timeIntervalSince(start)) }

    /// How many datagrams arrive within a few seconds.
    private static func count(_ stream: AsyncStream<Data>, expecting: Int) async -> Int {
        await withTaskGroup(of: Int.self) { group in
            let counter = Counter()
            group.addTask {
                for await _ in stream where await counter.add() >= expecting { break }
                return await counter.value
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(4))
                return await counter.value
            }
            let first = await group.next() ?? 0
            group.cancelAll()
            return first
        }
    }

    private actor Counter {
        var value = 0
        func add() -> Int {
            value += 1
            return value
        }
    }
}
