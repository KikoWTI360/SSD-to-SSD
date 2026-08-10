import Foundation

/// Pause/cancel gate shared by every worker thread.
///
/// The engine deliberately uses blocking POSIX I/O on GCD threads rather than Swift concurrency:
/// a handful of threads parked inside `read(2)` would otherwise starve the cooperative pool.
final class TransferGate: @unchecked Sendable {
    private let condition = NSCondition()
    private var paused = false
    private var cancelled = false

    var isPaused: Bool {
        condition.lock()
        defer { condition.unlock() }
        return paused
    }

    var isCancelled: Bool {
        condition.lock()
        defer { condition.unlock() }
        return cancelled
    }

    func pause() {
        condition.lock()
        paused = true
        condition.broadcast()
        condition.unlock()
    }

    func resume() {
        condition.lock()
        paused = false
        condition.broadcast()
        condition.unlock()
    }

    func cancel() {
        condition.lock()
        cancelled = true
        paused = false
        condition.broadcast()
        condition.unlock()
    }

    /// Blocks while paused. Returns `false` once the transfer has been cancelled — callers must
    /// unwind promptly when that happens.
    @discardableResult
    func checkpoint() -> Bool {
        condition.lock()
        defer { condition.unlock() }
        while paused && !cancelled {
            condition.wait()
        }
        return !cancelled
    }
}

/// Recycles page-aligned I/O buffers so copying a million small files doesn't mean a million
/// multi-megabyte allocations.
final class BufferPool: @unchecked Sendable {
    private let size: Int
    private var available: [UnsafeMutableRawBufferPointer] = []
    private let lock = NSLock()

    init(size: Int) {
        self.size = max(64 * 1024, size)
    }

    var bufferSize: Int { size }

    func acquire() -> UnsafeMutableRawBufferPointer {
        lock.lock()
        let reused = available.popLast()
        lock.unlock()
        return reused ?? UnsafeMutableRawBufferPointer.allocate(byteCount: size, alignment: 4096)
    }

    func release(_ buffer: UnsafeMutableRawBufferPointer) {
        lock.lock()
        available.append(buffer)
        lock.unlock()
    }

    func withBuffer<T>(_ body: (UnsafeMutableRawBufferPointer) throws -> T) rethrows -> T {
        let buffer = acquire()
        defer { release(buffer) }
        return try body(buffer)
    }

    func drain() {
        lock.lock()
        let buffers = available
        available.removeAll()
        lock.unlock()
        for buffer in buffers { buffer.deallocate() }
    }

    deinit { drain() }
}
