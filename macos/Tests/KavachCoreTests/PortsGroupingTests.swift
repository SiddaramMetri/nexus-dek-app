import Foundation
import Testing
@testable import KavachCore

@Suite struct PortsGroupingTests {
    // MARK: - Framework matcher

    @Test(arguments: [
        ("node /p/node_modules/.bin/next dev", "Next.js"),
        ("next-server (v14.2.3)", "Next.js"),
        ("node /p/node_modules/.bin/vite --port 5173", "Vite"),
        ("node /p/node_modules/.bin/nuxi dev", "Nuxt"),
        ("node /p/node_modules/.bin/astro dev", "Astro"),
        ("node /p/node_modules/.bin/remix-serve build/index.js", "Remix"),
        ("node /p/node_modules/.bin/nest start --watch", "NestJS"),
        ("node /p/node_modules/.bin/ng serve", "Angular"),
        ("node /p/node_modules/.bin/webpack-dev-server", "webpack-dev-server"),
        ("node /p/node_modules/.bin/storybook dev -p 6006", "Storybook"),
        ("python manage.py runserver 0.0.0.0:8000", "Django"),
        ("/p/.venv/bin/python /p/.venv/bin/uvicorn app.main:app --reload", "FastAPI"),
        ("python -m uvicorn main:app", "FastAPI"),
        ("gunicorn app:app -b :8000", "Gunicorn"),
        ("python -m flask run", "Flask"),
        ("/usr/bin/python3 -m http.server 8000", "Python http.server"),
        ("/Users/me/.local/bin/jupyter-lab --no-browser", "Jupyter"),
        ("ruby bin/rails server", "Rails"),
        ("puma 6.4.0 (tcp://localhost:3000) [shop]", "Puma"),
        ("/usr/local/bin/beam.smp -- -extra phx.server", "Phoenix"),
        ("hugo server -D", "Hugo"),
        ("go run ./cmd/api", "Go"),
        ("/var/folders/x/go-build123/b001/exe/api", "Go"),
        ("java -jar target/app.jar --spring-boot", "Spring Boot"),
        ("java -jar app.jar", "Java"),
        ("php artisan serve", "Laravel"),
        ("php -S localhost:8000", "PHP server"),
        ("node /p/node_modules/.bin/tsx watch src/index.ts", "tsx"),
        ("node /p/node_modules/.bin/ts-node src/main.ts", "ts-node"),
        ("bun run dev", "Bun"),
        ("deno run -A main.ts", "Deno · main.ts"),
        ("/Users/me/.nvm/versions/node/v22/bin/node /Users/me/api/server.js", "Node.js · server.js"),
        ("node", "Node.js"),
    ])
    func detectsFramework(_ cmd: String, _ expected: String) {
        #expect(PortFramework.detect(commandLine: cmd) == expected)
    }

    @Test func unknownCommandsHaveNoFramework() {
        #expect(PortFramework.detect(commandLine: "/opt/homebrew/bin/redis-server 127.0.0.1:6379") == nil)
        #expect(PortFramework.detect(commandLine: "python -m headroom.cli proxy") == nil)
        #expect(PortFramework.detect(commandLine: "") == nil)
    }

    @Test func wellKnownLabels() {
        #expect(PortFramework.wellKnownLabel(port: 5432) == "PostgreSQL")
        #expect(PortFramework.wellKnownLabel(port: 6379) == "Redis")
        #expect(PortFramework.wellKnownLabel(port: 11434) == "Ollama")
        #expect(PortFramework.wellKnownLabel(port: 9229) == "Node inspector")
        #expect(PortFramework.wellKnownLabel(port: 5173) == "Vite")
        #expect(PortFramework.wellKnownLabel(port: 49301) == nil)
    }

    // MARK: - Parsers

    @Test func parsesPsWithCommandLinesContainingSpaces() {
        let out = """
          752     1   0.0  12464 19:43 /usr/libexec/rapportd
         1361   817   0.4 141504 01:19:22 /Applications/Visual Studio Code.app/Contents/Frameworks/Code Helper (Plugin).app/Contents/MacOS/Code Helper (Plugin) --type=utility
         bad line
         9   1   x  1  1:00 nope
        """
        let procs = Ports.processes(out)
        #expect(procs.count == 2)
        #expect(procs[752]?.command == "/usr/libexec/rapportd")
        #expect(procs[1361]?.ppid == 817)
        #expect(procs[1361]?.sample == Parsers.PsSample(cpu: 0.4, rssBytes: 141_504 * 1024, uptimeSecs: 4762))
        #expect(procs[1361]?.command.hasSuffix("Code Helper (Plugin) --type=utility") == true)
    }

    @Test func parsesCwds() {
        let out = "p752\nfcwd\nn/\np5977\nfcwd\nn/Users/me/Documents/my proj\n"
        #expect(Ports.cwds(out) == [752: "/", 5977: "/Users/me/Documents/my proj"])
        #expect(Ports.cwds("") == [:])
    }

    @Test func classifyFillsDetailsAndFallsBackToArgv0() {
        let home = URL(fileURLWithPath: "/nonexistent-home")
        let ports = [
            PortInfo(pid: 3431, command: "ollama", user: "me", port: 11434, proto: "IPv4"),
            PortInfo(pid: 900, command: "redis-server", user: "me", port: 6379, proto: "IPv4"),
        ]
        let procs: [Int32: Ports.PsProcess] = [
            3431: .init(ppid: 3251, sample: .init(cpu: 0, rssBytes: 1, uptimeSecs: 2),
                        command: "/Applications/Ollama.app/Contents/Resources/ollama serve"),
            900: .init(ppid: 1, sample: .init(cpu: 0, rssBytes: 1, uptimeSecs: 2),
                       command: "/opt/homebrew/opt/redis/bin/redis-server 127.0.0.1:6379"),
        ]
        let out = Ports.classify(ports, procs: procs, cwds: [3431: "/"], exePaths: [:], home: home)
        #expect(out[0].owner == .app(bundlePath: "/Applications/Ollama.app"))
        #expect(out[0].executablePath == "/Applications/Ollama.app/Contents/Resources/ollama")
        #expect(out[0].ppid == 3251 && out[0].cwd == "/")
        #expect(out[1].owner == .other)
        #expect(out[1].framework == nil)
    }

    // MARK: - Sections

    private func port(_ pid: Int32, _ command: String, _ port: Int, _ owner: PortOwner, ppid: Int32? = nil,
                      framework: String? = nil) -> PortInfo {
        PortInfo(pid: pid, command: command, user: "me", port: port, proto: "IPv4", ppid: ppid, owner: owner,
                 framework: framework)
    }

    private var snapshot: PortsSnapshot {
        let vscode = PortOwner.app(bundlePath: "/Applications/Visual Studio Code.app")
        let api = PortOwner.project(root: "/Users/me/Documents/api")
        return PortsSnapshot(ports: [
            port(822, "ControlCenter", 7000, .system),
            port(822, "ControlCenter", 5000, .system),
            port(752, "rapportd", 49152, .system),
            port(1360, "Code Helper", 49301, vscode),
            port(1361, "Code Helper (Plugin)", 49300, vscode),
            port(1361, "Code Helper (Plugin)", 55731, vscode),
            port(1362, "Code Helper (Plugin)", 41222, vscode),
            port(1144, "node", 3000, api, framework: "Next.js"),
            port(1150, "node", 9229, api),
            port(2000, "python3.12", 8000, .project(root: "/Users/me/zeta")),
            port(900, "redis-server", 6379, .other),
            port(901, "postgres", 5432, .other, ppid: 899),
            port(950, "mystery", 30001, .other),
        ], branches: ["/Users/me/Documents/api": "main"])
    }

    private let brew: [Int32: String] = [900: "redis", 899: "postgresql@16"]

    @Test func groupsByOwner() {
        let s = PortSections.build(snapshot, brewServices: brew, home: "/Users/me")
        #expect(s.portCount == 13)
        #expect(s.projects.map(\.title) == ["api", "zeta"])
        let api = s.projects[0]
        #expect(api.subtitle == "~/Documents/api")
        #expect(api.branch == "main")
        #expect(api.ports.map(\.port) == [3000, 9229])
        #expect(api.pids == [1144, 1150])
        #expect(s.apps.count == 1)
        #expect(s.apps[0].title == "Visual Studio Code")
        #expect(s.apps[0].ports.map(\.port) == [41222, 49300, 49301, 55731])
        #expect(s.system.map(\.title) == ["AirPlay Receiver", "Handoff & Continuity"])
        #expect(s.system[0].ports.map(\.port) == [5000, 7000])
        #expect(s.system[0].subtitle?.hasPrefix("Ports 5000 and 7000") == true)
        #expect(s.other.map(\.title) == ["postgres", "redis-server", "mystery"])
        #expect(s.other.map(\.brewService) == ["postgresql@16", "redis", nil])
    }

    @Test func searchFiltersPortsAndDropsEmptyGroups() {
        let byPort = PortSections.build(snapshot, brewServices: brew, query: "3000", home: "/Users/me")
        #expect(byPort.portCount == 1)
        #expect(byPort.projects.map(\.title) == ["api"])
        #expect(byPort.projects[0].ports.map(\.port) == [3000])
        #expect(byPort.apps.isEmpty && byPort.system.isEmpty && byPort.other.isEmpty)

        // Without an exact hit a numeric prefix matches ports; a pid only ever exactly.
        #expect(PortSections.build(snapshot, query: "300", home: "/Users/me").portCount == 2)
        #expect(PortSections.build(snapshot, query: "1361", home: "/Users/me").apps.first?.ports.count == 2)
        #expect(PortSections.build(snapshot, query: "136", home: "/Users/me").isEmpty)

        let byApp = PortSections.build(snapshot, query: " visual ", home: "/Users/me")
        #expect(byApp.portCount == 4 && byApp.apps.count == 1)
        #expect(PortSections.build(snapshot, query: "next.js", home: "/Users/me").portCount == 1)
        #expect(PortSections.build(snapshot, query: "API", home: "/Users/me").projects.first?.ports.count == 2)
        #expect(PortSections.build(snapshot, query: "airplay", home: "/Users/me").system.count == 1)
        #expect(PortSections.build(snapshot, query: "postgresql", home: "/Users/me").portCount == 1)
        #expect(PortSections.build(snapshot, brewServices: brew, query: "redis", home: "/Users/me").portCount == 1)
        #expect(PortSections.build(snapshot, query: "nothing-here", home: "/Users/me").isEmpty)
    }

    @Test func abbreviatesHome() {
        #expect(PortSections.abbreviate("/Users/me/a/b", home: "/Users/me") == "~/a/b")
        #expect(PortSections.abbreviate("/Users/me", home: "/Users/me") == "~")
        #expect(PortSections.abbreviate("/Users/meme/x", home: "/Users/me") == "/Users/meme/x")
    }

    @Test func emptySnapshot() {
        let s = PortSections.build(PortsSnapshot(ports: [], branches: [:]))
        #expect(s.isEmpty && s.projects.isEmpty)
    }
}
