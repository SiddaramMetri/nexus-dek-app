import Foundation

/// Who holds the state DBs, and the confirmed force-quit.
enum VSCodeProcess {
    /// SIGTERM grace (VSCode flushes state + hot-exit backups here), then the
    /// short wait after SIGKILL for the kernel to drop the file handles.
    static let termGrace: Duration = .seconds(8)
    static let killGrace: Duration = .seconds(4)
    static let quitPoll: Duration = .milliseconds(300)

    /// Every live process running out of the VSCode bundle — main app + helpers.
    /// Matched on the executable path from `ps`, not `pgrep -f`: pgrep can't read
    /// the main `Contents/MacOS/Code` process's argv on macOS.
    static func vscodePids() async -> [String] {
        parseVSCodePids(await Proc.anyOutput("ps", ["-axo", "pid=,comm="]))
    }

    /// `ps -axo pid=,comm=` lines → pids of VSCode-bundle processes.
    static func parseVSCodePids(_ ps: String) -> [String] {
        ps.split(whereSeparator: \.isNewline)
            .filter { $0.contains("/Visual Studio Code.app/") }
            .compactMap { $0.split(whereSeparator: \.isWhitespace).first.map(String.init) }
    }

    /// `lsof -t` pids ∩ VSCode pids. Whole-token compare — "634041" is not "63404".
    static func anyHolderIsVSCode(_ lsof: String, vscodePids: [String]) -> Bool {
        lsof.split(whereSeparator: \.isWhitespace).contains { vscodePids.contains(String($0)) }
    }

    /// Is **VSCode** holding a state.vscdb open? Holders ∩ VSCode processes —
    /// our own scan's read-only handles (or a passing mdworker) must not count,
    /// or the force-quit would "fail" with nothing left to kill. Anything else
    /// with the file open is left to VACUUM's SQLITE_BUSY backstop.
    /// Fails open if lsof is missing — the same backstop covers it.
    static func stateDBsInUse() async -> Bool {
        let dbs = VSCodeProbes.allStateDBs()
        guard !dbs.isEmpty else { return false }
        let lsof = await Proc.anyOutput("lsof", ["-t", "--"] + dbs.map(\.path))
        return anyHolderIsVSCode(lsof, vscodePids: await vscodePids())
    }

    static func signal(_ sig: String, _ pids: [String]) async {
        guard !pids.isEmpty else { return }
        _ = try? await Proc.run("kill", [sig] + pids)
    }

    /// True once nothing VSCode holds the DBs open, false if the deadline passes.
    static func waitReleased(_ timeout: Duration) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while true {
            if !(await stateDBsInUse()) { return true }
            if ContinuousClock.now >= deadline { return false }
            try? await Task.sleep(for: quitPoll)
        }
    }

    /// Close VSCode for real. SIGTERM first so it flushes state and hot-exit
    /// backups; SIGKILL only for whatever ignores that — a modal "save your
    /// changes?" sheet must not veto a force quit the user confirmed.
    static func forceQuit() async throws {
        await signal("-TERM", await vscodePids())
        if await waitReleased(termGrace) { return }
        await signal("-KILL", await vscodePids())
        if await waitReleased(killGrace) { return }
        throw AppError.forbidden("Something is still holding the VSCode databases open. Close it and try again.")
    }
}
