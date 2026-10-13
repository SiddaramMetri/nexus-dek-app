import Foundation

/// FIFO async mutex with a non-blocking `tryLock`. Serializes brew mutations
/// (the Rust `BrewLock`) without parking a thread while a long install runs.
public actor AsyncMutex {
    private var locked = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    public init() {}

    public func lock() async {
        if !locked { locked = true; return }
        await withCheckedContinuation { waiters.append($0) }
    }

    public func tryLock() -> Bool {
        if locked { return false }
        locked = true
        return true
    }

    public func unlock() {
        if waiters.isEmpty { locked = false } else { waiters.removeFirst().resume() }
    }

    public var isLocked: Bool { locked }

    public func withLock<T: Sendable>(_ body: @Sendable () async throws -> T) async rethrows -> T {
        await lock()
        defer { unlock() }
        return try await body()
    }
}

/// Small lock-protected box for state touched from several tasks.
public final class Locked<Value>: @unchecked Sendable {
    private var value: Value
    private let lock = NSLock()

    public init(_ value: Value) { self.value = value }

    public func with<T>(_ body: (inout Value) throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body(&value)
    }

    public var snapshot: Value { with { $0 } }
}
