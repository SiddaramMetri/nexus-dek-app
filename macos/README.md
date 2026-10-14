# Kavach Console — native macOS (Swift)

A native SwiftUI + AppKit rewrite of the Tauri app in the repo root. No web view,
no Node or Rust at runtime. It uses Apple frameworks plus one small package,
[SwiftTerm](https://github.com/migueldeicaza/SwiftTerm), for the terminal.

- macOS 14+
- Builds with the Command Line Tools alone; full Xcode isn't needed.
- Data lives in `~/Library/Application Support/com.vss.kavachconsole/`. On first
  launch it copies settings, services and history from the old
  `com.vss.nexusconsole/` folder (the Tauri build's), so switching keeps everything.

## Commands

```bash
cd macos
./scripts/build-app.sh          # → build/Kavach Console.app (release, -Osize, stripped, ad-hoc signed)
./scripts/build-app.sh --open   # build and launch
./scripts/build-app.sh --zip    # also build/Kavach-Console.zip, ready for a GitHub release
./scripts/test.sh               # KavachCore unit tests (Swift Testing)
swift build --build-system native   # debug build of the executable
```

## Layout

```
Sources/KavachCore/        pure logic, no UI imports, unit-tested
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
Sources/KavachConsole/     the app
  App/                    main, AppDelegate (window, hide-on-close, quit), AppModel
                          (state + services poll + sessions), StatusBar (menu bar),
                          Scheduler (tray automation), RootView/WelcomeView
  UI/                     shared native components, ViewState alias
  Features/<Tab>/         one folder per tab, plus Terminal/
Tests/KavachCoreTests/     Swift Testing suites; Fixtures/ is captured real command output
Support/Info.plist        bundle metadata (version is taken from ../package.json)
```

## Guard (screen lock + keep awake)

Inspired by [Locksee](https://github.com/tejaskh3/Locksee) by tejaskh3. This is our own
implementation built on public Apple APIs; no Locksee code is used.

- **Lock** (⌃⌘L by default, a Carbon global hotkey, no permission needed). A shield window
  sits on every display at `CGShieldingWindowLevel`, and a session `CGEventTap` swallows
  keyboard, media keys and, optionally, trackpad gestures. The cursor still moves, and clicks
  land on the shield. Unlock is Touch ID, embedded in the shield with `LAAuthenticationView`,
  or the Mac password, checked through Open Directory. While the password field is open, only
  plain typing gets through (`LockKeys`); ⌘/⌃ shortcuts and F-keys are always swallowed.
- **Fails closed.** Without Accessibility the tap can't be installed, so it refuses to lock.
  It's a hands-off lock for short breaks, not a security boundary (the macOS lock is ⌃⌘Q).
- **Keep awake** uses IOPM assertions (idle system sleep, plus display sleep if you ask for it).
  It runs in timed sessions and stops at a low-battery cutoff when on battery. A closed lid
  still sleeps.
- **Signing.** Accessibility is tied to the code signature, and every ad-hoc build has a new
  one, so you have to re-allow it after each rebuild. A self-signed identity named
  "Kavach Dev", or `KAVACH_SIGN_ID`, keeps the permission (see `scripts/build-app.sh`).

## Rules carried over from the Tauri app

- **Never build a shell string.** Use `Proc.run(tool, [args])`. Formula and tap
  names go through `Validate`. Every brew call sets `HOMEBREW_NO_AUTO_UPDATE=1`.
- **brew mutations hold `brew.lock`.** The services poll uses `tryLock` and serves
  the last known list while a mutation runs. Every write invalidates the services cache.
- **Confirms live in KavachCore.** Destructive functions take a `Confirmer` and call
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
