import Foundation

/// Output of a finished subprocess.
public struct ProcOutput: Sendable {
    public let status: Int32
    public let stdout: Data
    public let stderr: Data

    public var ok: Bool { status == 0 }
    public var out: String { String(decoding: stdout, as: UTF8.self) }
    public var err: String { String(decoding: stderr, as: UTF8.self) }
}

/// Subprocess runner. Always an executable + an argument array — never a shell
/// string, so nothing user-supplied can be interpreted by a shell.
public enum Proc {
    /// Where a Finder-launched app finds system tools (its PATH is minimal).
    static let searchPath = ["/usr/bin", "/bin", "/usr/sbin", "/sbin", "/opt/homebrew/bin", "/usr/local/bin"]

    /// Resolve a bare tool name (`lsof`) to an absolute path.
    public static func which(_ tool: String) -> String? {
        if tool.hasPrefix("/") { return FileManager.default.isExecutableFile(atPath: tool) ? tool : nil }
        return searchPath.lazy.map { "\($0)/\(tool)" }.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Run to completion off the calling thread. Throws only when the process
    /// can't be launched; a non-zero exit is reported in `status`.
    public static func run(
        _ tool: String,
        _ args: [String],
        env: [String: String] = [:],
        cwd: String? = nil
    ) async throws -> ProcOutput {
        guard let path = which(tool) else { throw AppError.notFound("\(tool) not found") }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = args
        if !env.isEmpty {
            process.environment = ProcessInfo.processInfo.environment.merging(env) { _, new in new }
        }
        if let cwd { process.currentDirectoryURL = URL(fileURLWithPath: cwd) }
        let outPipe = Pipe(), errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        process.standardInput = FileHandle.nullDevice

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<ProcOutput, Error>) in
                // Drain both pipes concurrently — a full pipe buffer would block the child.
                let group = DispatchGroup()
                nonisolated(unsafe) var outData = Data(), errData = Data()
                group.enter()
                DispatchQueue.global().async {
                    outData = outPipe.fileHandleForReading.readDataToEndOfFile(); group.leave()
                }
                group.enter()
                DispatchQueue.global().async {
                    errData = errPipe.fileHandleForReading.readDataToEndOfFile(); group.leave()
                }
                process.terminationHandler = { p in
                    group.notify(queue: .global()) {
                        cont.resume(returning: ProcOutput(status: p.terminationStatus, stdout: outData, stderr: errData))
                    }
                }
                do {
                    try process.run()
                } catch {
                    process.terminationHandler = nil
                    try? outPipe.fileHandleForWriting.close()
                    try? errPipe.fileHandleForWriting.close()
                    cont.resume(throwing: AppError.shell("\(tool): \(error.localizedDescription)"))
                }
            }
        } onCancel: {
            if process.isRunning { process.terminate() }
        }
    }

    /// stdout on success, nil on any failure — for read-only probes where a
    /// missing tool just means "couldn't check".
    public static func output(_ tool: String, _ args: [String]) async -> String? {
        guard let r = try? await run(tool, args), r.ok else { return nil }
        return r.out
    }

    /// stdout regardless of exit status (lsof exits 1 when nothing matches).
    public static func anyOutput(_ tool: String, _ args: [String]) async -> String {
        (try? await run(tool, args))?.out ?? ""
    }
}
