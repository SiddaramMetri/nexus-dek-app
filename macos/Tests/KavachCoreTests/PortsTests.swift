import Foundation
import Testing
@testable import KavachCore

@Suite struct PortsTests {
    @Test func lsofArgsAddListenFilterOnlyWhenAsked() {
        #expect(Ports.lsofArgs(listeningOnly: true) == ["-nP", "-iTCP", "-FpcLtn", "-sTCP:LISTEN"])
        #expect(Ports.lsofArgs(listeningOnly: false) == ["-nP", "-iTCP", "-FpcLtn"])
    }

    @Test func dedupsIPv4AndIPv6OfSamePidPort() {
        let rows = Ports.dedup(Parsers.lsofFields(fixture("lsof-fields.txt")))
        var seen = Set<String>()
        #expect(rows.allSatisfy { seen.insert("\($0.pid):\($0.port)").inserted })
        // ControlCenter's *:7000 appears as IPv4 + IPv6 — one row, first (IPv4) wins.
        let cc = rows.filter { $0.pid == 620 && $0.port == 7000 }
        #expect(cc.count == 1)
        #expect(cc.first?.proto == "IPv4")
        #expect(rows.contains { $0.pid == 620 && $0.port == 5000 })
    }

    @Test func pidListIsSortedAndUnique() {
        let rows = [
            Parsers.LsofRow(pid: 99, command: "a", user: "u", proto: "IPv4", port: 1),
            Parsers.LsofRow(pid: 7, command: "b", user: "u", proto: "IPv4", port: 2),
            Parsers.LsofRow(pid: 99, command: "a", user: "u", proto: "IPv6", port: 3),
        ]
        #expect(Ports.pidList(rows) == "7,99")
        #expect(Ports.pidList([]) == "")
    }

    @Test func enrichesWithPsSamples() {
        let rows = [
            Parsers.LsofRow(pid: 99615, command: "redis-server", user: "me", proto: "IPv4", port: 6379),
            Parsers.LsofRow(pid: 4242, command: "ghost", user: "me", proto: "IPv6", port: 80),
        ]
        let ports = Ports.enrich(rows, samples: Parsers.ps(fixture("ps-stats.txt")))
        #expect(ports[0].memoryBytes == 2160 * 1024)
        #expect(ports[0].cpu == 0.0)
        #expect(ports[0].id == "99615-6379")
        #expect(ports[1].cpu == nil && ports[1].memoryBytes == nil)
    }

    @Test func refusesSystemAndSelfPids() {
        #expect(throws: AppError.forbidden("refusing to signal pid < 2")) { try Ports.guardTarget(pid: 1, selfPid: 500) }
        #expect(throws: AppError.forbidden("refusing to signal pid < 2")) { try Ports.guardTarget(pid: 0, selfPid: 500) }
        #expect(throws: AppError.forbidden("refusing to signal pid < 2")) { try Ports.guardTarget(pid: -1, selfPid: 500) }
        #expect(throws: AppError.forbidden("refusing to kill \(AppInfo.name)")) { try Ports.guardTarget(pid: 500, selfPid: 500) }
        #expect(throws: Never.self) { try Ports.guardTarget(pid: 501, selfPid: 500) }
    }

    @Test func killGuardsRunBeforeAnySignal() async {
        // Real call, but both targets are rejected before kill(2) is reached.
        await #expect(throws: AppError.forbidden("refusing to signal pid < 2")) {
            try await Ports.kill(pid: 1, force: true, sudo: false)
        }
        await #expect(throws: AppError.forbidden("refusing to kill \(AppInfo.name)")) {
            try await Ports.kill(pid: getpid(), force: false, sudo: true)
        }
    }

    @Test func adminScriptInterpolatesOnlySignalAndPid() {
        #expect(Ports.adminScript(pid: 4242, force: false)
            == #"do shell script "/bin/kill -TERM 4242" with administrator privileges"#)
        #expect(Ports.adminScript(pid: 4242, force: true)
            == #"do shell script "/bin/kill -KILL 4242" with administrator privileges"#)
    }

    @Test func searchMatchesCommandPortPidUser() {
        let ports = [
            PortInfo(pid: 99615, command: "redis-server", user: "me", port: 6379, proto: "IPv4"),
            PortInfo(pid: 1, command: "launchd", user: "root", port: 80, proto: "IPv6"),
        ]
        #expect(Ports.filter(ports, query: "").count == 2)
        #expect(Ports.filter(ports, query: "REDIS").map(\.pid) == [99615])
        #expect(Ports.filter(ports, query: "6379").map(\.pid) == [99615])
        #expect(Ports.filter(ports, query: " 9961 ").map(\.pid) == [99615])
        #expect(Ports.filter(ports, query: "root").map(\.pid) == [1])
        #expect(Ports.filter(ports, query: "nothing").isEmpty)
        #expect(ports[1].isSystem && !ports[0].isSystem)
    }
}
