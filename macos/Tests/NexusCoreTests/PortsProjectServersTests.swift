import Foundation
import Testing
@testable import NexusCore

@Suite struct PortsProjectServersTests {
    /// docklyt's real scripts: `dev` runs Next + an agent via concurrently.
    static let docklyt: [String: String] = [
        "dev": #"concurrently --names next,agent --prefix-colors cyan,magenta "next dev --port 3000" "node agent/index.js""#,
        "dev:next": "next dev --port 3000",
        "agent": "node agent/index.js",
        "build": "next build",
        "start": "next start",
        "lint": "next lint",
    ]

    @Test func splitsConcurrentlyIntoTheDedicatedScripts() {
        let s = ProjectServers.servers(scripts: Self.docklyt, dir: "/u/docklyt", runner: "pnpm")
            .sorted { $0.role < $1.role }
        #expect(s.count == 2)
        #expect(s[0].role == .frontend && s[0].framework == "Next.js" && s[0].port == 3000 && s[0].script == "dev:next")
        #expect(s[1].role == .backend && s[1].entry == "agent/index.js" && s[1].port == nil && s[1].script == "agent")
        #expect(s[0].launchLabel == "pnpm dev:next")
        #expect(s[1].name == "agent/index.js")
    }

    @Test func plainDevScriptAndProductionStartSkipped() {
        let s = ProjectServers.servers(scripts: ["dev": "vite", "start": "vite preview", "build": "vite build"],
                                       dir: "/u/web", runner: "npm")
        #expect(s.map(\.command) == ["vite"])
        #expect(s[0].port == 5173 && s[0].role == .frontend && s[0].launchLabel == "npm run dev")
    }

    @Test func startOnlyProjectsStillCount() {
        let s = ProjectServers.servers(scripts: ["start": "PORT=4000 node server.js"], dir: "/u/api", runner: "yarn")
        #expect(s.count == 1)
        #expect(s[0].port == 4000 && s[0].role == .backend && s[0].entry == "server.js")
    }

    @Test func runPAndReferencedScripts() {
        let s = ProjectServers.servers(
            scripts: ["dev": "run-p dev:web dev:api", "dev:web": "next dev -p 3001", "dev:api": "nest start --watch",
                      "typecheck": "tsc --watch"],
            dir: "/u/mono", runner: "pnpm")
        #expect(Set(s.map(\.script)) == ["dev:web", "dev:api"])
        #expect(s.first { $0.script == "dev:web" }?.port == 3001)
        #expect(s.first { $0.script == "dev:api" }?.framework == "NestJS")
    }

    @Test func buildAndLintAreNotServers() {
        #expect(ProjectServers.servers(scripts: ["dev": "tsc --watch", "dev:css": "tailwindcss -w"], dir: "/u/x", runner: "npm").isEmpty)
    }

    @Test func discoversSubAppsAndDjango() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("srv-\(UUID().uuidString)")
        try fm.createDirectory(at: root.appendingPathComponent("frontend"), withIntermediateDirectories: true)
        try fm.createDirectory(at: root.appendingPathComponent("backend"), withIntermediateDirectories: true)
        try fm.createDirectory(at: root.appendingPathComponent("frontend/node_modules/x"), withIntermediateDirectories: true)
        try Data(#"{"scripts":{"dev":"vite --port 5174"}}"#.utf8).write(to: root.appendingPathComponent("frontend/package.json"))
        try Data(#"{"scripts":{"dev":"next dev"}}"#.utf8).write(to: root.appendingPathComponent("frontend/node_modules/x/package.json"))
        try Data().write(to: root.appendingPathComponent("frontend/pnpm-lock.yaml"))
        try Data().write(to: root.appendingPathComponent("backend/manage.py"))

        let s = ProjectServers.discover(root: root.path)
        #expect(s.count == 2)  // node_modules is never read
        #expect(s[0].role == .frontend && s[0].port == 5174 && s[0].runner == "pnpm")
        #expect(s[1].framework == "Django" && s[1].port == 8000 && s[1].launchLabel == "python manage.py runserver")
    }

    @Test func matchesRunningProcessesByScriptThenPort() {
        let agent = DeclaredServer(dir: "/u/docklyt", script: "agent", command: "node agent/index.js", framework: nil,
                                   role: .backend, port: nil, runner: "pnpm", entry: "agent/index.js")
        let next = DeclaredServer(dir: "/u/docklyt", script: "dev:next", command: "next dev --port 3000",
                                  framework: "Next.js", role: .frontend, port: 3000, runner: "pnpm", entry: nil)
        let running = PortInfo(pid: 50740, command: "node", user: "me", port: 9876, proto: "IPv4",
                               commandLine: "/Users/me/.nvm/bin/node /u/docklyt/agent/index.js", cwd: "/")
        #expect(ProjectServers.matches(running, agent))
        #expect(!ProjectServers.matches(running, next))
        let nextRunning = PortInfo(pid: 9, command: "node", user: "me", port: 3000, proto: "IPv4")
        #expect(ProjectServers.matches(nextRunning, next))
    }

    @Test func launchCommandsAreValidated() throws {
        func s(_ script: String, _ runner: String) -> DeclaredServer {
            DeclaredServer(dir: "/u", script: script, command: "", framework: nil, role: .backend, port: nil,
                           runner: runner, entry: nil)
        }
        #expect(try ScriptLaunch.command(for: s("dev:next", "pnpm")) == "pnpm dev:next")
        #expect(try ScriptLaunch.command(for: s("dev", "npm")) == "npm run dev")
        #expect(throws: AppError.self) { try ScriptLaunch.command(for: s("dev; rm -rf ~", "pnpm")) }
        #expect(throws: AppError.self) { try ScriptLaunch.command(for: s("dev", "sh")) }
    }
}

@Suite struct PortsProjectServersFixTests {
    @Test func sameScriptFileDeclaredTwiceIsOneServer() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("dup-\(UUID().uuidString)")
        try fm.createDirectory(at: root.appendingPathComponent("agent"), withIntermediateDirectories: true)
        try Data(#"{"scripts":{"dev":"concurrently \"next dev --port 3000\" \"node agent/index.js\"","dev:next":"next dev --port 3000","agent":"node agent/index.js"}}"#.utf8)
            .write(to: root.appendingPathComponent("package.json"))
        try Data(#"{"scripts":{"start":"node index.js"}}"#.utf8).write(to: root.appendingPathComponent("agent/package.json"))
        let s = ProjectServers.discover(root: root.path)
        #expect(s.count == 2)
        #expect(s.filter { $0.entryPath?.hasSuffix("/agent/index.js") == true }.count == 1)
    }

    @Test func wholeProjectScriptsAreLaunchersNotRows() {
        let s = ProjectServers.servers(scripts: ["dev": "pnpm install && ./run.sh --dev"], dir: "/u/rl", runner: "pnpm")
        #expect(s.count == 1 && s[0].isLauncher)
        #expect(ProjectServers.isLauncher("docker compose up"))
        #expect(ProjectServers.isLauncher("turbo run dev"))
        #expect(!ProjectServers.isLauncher("next dev -p 3000"))

        let launcher = s[0]
        let snap = PortsSnapshot(ports: [], branches: [:], declared: ["/u/rl": [launcher]])
        _ = snap  // launchers are filtered out of slots in PortSections.build
        #expect(PortSections.slots(declared: [launcher].filter { !$0.isLauncher }, running: []).isEmpty)
    }

    @Test func globalToolsAreNamedAsTools() {
        let p = PortInfo(pid: 5977, command: "python3.12", user: "me", port: 8787, proto: "IPv4",
                         commandLine: "/Users/me/.local/share/uv/tools/headroom-ai/bin/python -m headroom.cli proxy --host 127.0.0.1",
                         executablePath: "/Users/me/.local/share/uv/tools/headroom-ai/bin/python3.12")
        #expect(PortSections.toolName(p) == "headroom")
        let slots = PortSections.slots(declared: [], running: [p])
        #expect(slots.first?.role == .tool && slots.first?.name == "headroom")
        let normal = PortInfo(pid: 1, command: "node", user: "me", port: 3000, proto: "IPv4",
                              commandLine: "/Users/me/.nvm/versions/node/v22/bin/node server.js")
        #expect(PortSections.toolName(normal) == nil)
    }
}
