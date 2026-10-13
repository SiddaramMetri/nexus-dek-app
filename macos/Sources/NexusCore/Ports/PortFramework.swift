import Foundation

/// Names the dev server behind a command line ("Next.js", "Django", …) and
/// labels well-known ports. Table-driven; first matching rule wins, so more
/// specific tools sit above the generic runtimes (Node, Java, Bun).
public enum PortFramework {
    /// Tokenized command line: raw tokens plus their lowercased basenames.
    struct Argv {
        let raw: [String]
        let names: [String]

        init(_ commandLine: String) {
            raw = commandLine.split(whereSeparator: \.isWhitespace).map(String.init)
            names = raw.map { ($0 as NSString).lastPathComponent.lowercased() }
        }

        /// `bin` appears as a token basename, optionally followed by one of `subs`.
        func has(_ bin: String, then subs: Set<String> = []) -> Bool {
            names.indices.contains { i in
                names[i] == bin && (subs.isEmpty || (i + 1 < names.count && subs.contains(names[i + 1])))
            }
        }

        /// `-m module` (python).
        func module(_ name: String) -> Bool {
            raw.indices.contains { i in raw[i] == "-m" && i + 1 < raw.count && raw[i + 1].lowercased() == name }
        }

        func contains(_ fragment: String) -> Bool { raw.contains { $0.lowercased().contains(fragment) } }

        /// First script-looking argument (`server.js`, `src/main.ts`).
        var script: String? {
            let exts = [".js", ".mjs", ".cjs", ".ts", ".mts"]
            return raw.dropFirst().first { t in !t.hasPrefix("-") && exts.contains { t.lowercased().hasSuffix($0) } }
                .map { ($0 as NSString).lastPathComponent }
        }
    }

    private struct Rule {
        let name: String
        let matches: (Argv) -> Bool
    }

    private static let devStart: Set<String> = ["dev", "start", "serve", "preview"]

    private static let rules: [Rule] = [
        Rule(name: "Storybook") { $0.names.contains { $0.contains("storybook") } },
        Rule(name: "Next.js") { $0.has("next", then: devStart) || $0.contains("next-server") || $0.contains("/next/dist/") },
        Rule(name: "Nuxt") { $0.has("nuxt") || $0.has("nuxi") },
        Rule(name: "Astro") { $0.has("astro", then: devStart) },
        Rule(name: "Remix") { $0.has("remix", then: devStart) || $0.has("remix-serve") },
        Rule(name: "Vite") { $0.has("vite") || $0.contains("/vite/bin/") },
        Rule(name: "Angular") { $0.has("ng", then: ["serve", "s"]) },
        Rule(name: "webpack-dev-server") { $0.has("webpack-dev-server") || $0.has("webpack", then: ["serve"]) },
        Rule(name: "NestJS") { $0.has("nest", then: ["start"]) || $0.contains("@nestjs") },
        Rule(name: "Jupyter") { $0.names.contains { $0.hasPrefix("jupyter") } },
        Rule(name: "Django") { $0.has("manage.py", then: ["runserver"]) },
        Rule(name: "FastAPI") { $0.has("uvicorn") || $0.module("uvicorn") || $0.has("fastapi") },
        Rule(name: "Gunicorn") { $0.has("gunicorn") || $0.module("gunicorn") },
        Rule(name: "Flask") { $0.has("flask") || $0.module("flask") },
        Rule(name: "Python http.server") { $0.module("http.server") || $0.module("simplehttpserver") },
        Rule(name: "Rails") { $0.has("rails", then: ["server", "s"]) },
        Rule(name: "Puma") { $0.names.contains { $0.hasPrefix("puma") } },
        Rule(name: "Phoenix") { $0.contains("phx.server") },
        Rule(name: "Hugo") { $0.has("hugo") },
        Rule(name: "Go") { $0.has("go", then: ["run"]) || $0.contains("/go-build") },
        Rule(name: "Spring Boot") { $0.contains("spring-boot") || $0.contains("bootrun") },
        Rule(name: "Java") { $0.has("java") },
        Rule(name: "Laravel") { $0.has("artisan", then: ["serve"]) },
        Rule(name: "PHP server") { $0.has("php", then: ["-s"]) },
        Rule(name: "ts-node") { $0.has("ts-node") || $0.has("ts-node-dev") },
        Rule(name: "tsx") { $0.has("tsx") },
        Rule(name: "Bun") { $0.has("bun") },
        Rule(name: "Deno") { $0.has("deno") },
        Rule(name: "Node.js") { $0.has("node") || $0.has("nodemon") },
    ]

    /// "Next.js", "Node.js · server.js", or nil when nothing matches.
    public static func detect(commandLine: String) -> String? {
        let argv = Argv(commandLine)
        guard !argv.raw.isEmpty, let rule = rules.first(where: { $0.matches(argv) }) else { return nil }
        if rule.name == "Node.js" || rule.name == "Bun" || rule.name == "Deno", let script = argv.script {
            return "\(rule.name) · \(script)"
        }
        return rule.name
    }

    // MARK: - Well-known ports

    static let wellKnown: [Int: String] = [
        22: "SSH", 80: "HTTP", 443: "HTTPS", 1433: "SQL Server", 2375: "Docker", 3000: "Dev server",
        3001: "Dev server", 3306: "MySQL", 4000: "Dev server", 4200: "Angular", 4321: "Astro", 5000: "Dev server",
        5173: "Vite", 5432: "PostgreSQL", 5672: "RabbitMQ", 6006: "Storybook", 6379: "Redis", 7000: "AirPlay",
        8000: "Dev server", 8080: "HTTP alternate", 8081: "HTTP alternate", 8443: "HTTPS alternate",
        8888: "Jupyter", 9000: "Dev server", 9200: "Elasticsearch", 9229: "Node inspector", 11211: "Memcached",
        11434: "Ollama", 15672: "RabbitMQ admin", 27017: "MongoDB",
    ]

    public static func wellKnownLabel(port: Int) -> String? { wellKnown[port] }
}
