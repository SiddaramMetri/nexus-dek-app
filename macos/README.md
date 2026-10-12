# Nexus Console — native macOS (Swift)

A native SwiftUI + AppKit rewrite of the Tauri app in the repo root. No web view,
no Node or Rust at runtime. It uses Apple frameworks plus one small package,
[SwiftTerm](https://github.com/migueldeicaza/SwiftTerm), for the terminal.

- macOS 14+
- Builds with the Command Line Tools alone; full Xcode isn't needed.
- Settings, managed services and session history are read from the same
  `~/Library/Application Support/com.vss.nexusconsole/` files the Tauri build
  wrote, so switching over keeps everything.

## Commands

```bash
cd macos
./scripts/build-app.sh          # → build/Nexus Console.app (release, -Osize, stripped, ad-hoc signed)
./scripts/build-app.sh --open   # build and launch
./scripts/test.sh               # NexusCore unit tests (Swift Testing)
swift build --build-system native   # debug build of the executable
```

## Layout

```
Sources/NexusCore/        pure logic, no UI imports, unit-tested
  Core/                   Proc (subprocess runner), AppError + Confirmer, Paths,
                          Journal, JSONStore, parsers, validation, formatters
  Brew/                   Brew runner + error classification, services (cached
                          list, start/stop, install, search), packages, reconcile,
                          terminal command allowlist
  Ports/                  lsof/ps listing, kill
  Doctor/                 Finding/Probe model, probe registry, system/browser/
                          ollama/deep-scan probes, VSCode probes and fixes
  Archiver/               Claude chat archiver
  Settings/               persisted models (same JSON shape as the Tauri store)
Sources/NexusConsole/     the app
  App/                    main, AppDelegate (window, hide-on-close, quit), AppModel
                          (state + services poll + sessions), StatusBar (menu bar),
                          Scheduler (tray automation), RootView/WelcomeView
  UI/                     shared native components, ViewState alias
  Features/<Tab>/         one folder per tab, plus Terminal/
Tests/NexusCoreTests/     Swift Testing suites; Fixtures/ is captured real command output
Support/Info.plist        bundle metadata (version is taken from ../package.json)
```

## Rules carried over from the Tauri app

- **Never build a shell string.** Use `Proc.run(tool, [args])`. Formula and tap
  names go through `Validate`. Every brew call sets `HOMEBREW_NO_AUTO_UPDATE=1`.
- **brew mutations hold `brew.lock`.** The services poll uses `tryLock` and serves
  the last known list while a mutation runs. Every write invalidates the services cache.
- **Confirms live in NexusCore.** Destructive functions take a `Confirmer` and call
  `confirmer.require(...)` before mutating, so the UI can't skip the prompt. The app
  supplies a native `NSAlert` sheet.
- **Doctor probes are read-only and never wake a daemon.** Every `Finding` carries
  an honest `Tag`. Mutations are journaled to `~/claude-history-archive/journal.jsonl`.

## Toolchain quirks (Command Line Tools only)

- Use `@ViewState`, not `@State`. The macOS 27 SDK declares `@State` as a macro whose
  plugin ships only with Xcode. `ViewState` is a typealias to the same property wrapper.
  Avoid `@Entry`/`@Previewable` for the same reason.
- Build with `--build-system native`. `scripts/test.sh` adds the Swift Testing paths
  that the default build system can't find without Xcode.
- SwiftTerm is pinned to 1.11.2. Later versions add Metal shaders, which need Xcode's
  `metal` compiler.
