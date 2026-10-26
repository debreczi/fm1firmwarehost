import Foundation

/// A queue of complete SysEx messages with one async reader at a time, and a timeout per read.
final class SysexQueue: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [[UInt8]] = []
    private var waiter: CheckedContinuation<[UInt8]?, Never>?
    private var generation = 0

    func push(_ message: [UInt8]) {
        lock.lock()
        if let w = waiter {
            waiter = nil
            lock.unlock()
            w.resume(returning: message)
            return
        }
        items.append(message)
        lock.unlock()
    }

    func drain() {
        lock.lock()
        items.removeAll()
        lock.unlock()
    }

    var isEmpty: Bool {
        lock.lock(); defer { lock.unlock() }
        return items.isEmpty
    }

    /// The next message, or nil after `timeout` seconds.
    func next(timeout: TimeInterval) async -> [UInt8]? {
        lock.lock()
        if !items.isEmpty {
            let m = items.removeFirst()
            lock.unlock()
            return m
        }
        // Only one reader is supported: a second reader cancels the first with nil.
        if let old = waiter {
            waiter = nil
            lock.unlock()
            old.resume(returning: nil)
            lock.lock()
        }
        generation += 1
        let gen = generation
        lock.unlock()

        return await withCheckedContinuation { (c: CheckedContinuation<[UInt8]?, Never>) in
            lock.lock()
            if !items.isEmpty {
                let m = items.removeFirst()
                lock.unlock()
                c.resume(returning: m)
                return
            }
            waiter = c
            lock.unlock()
            let ns = UInt64(max(0, timeout) * 1_000_000_000)
            Task.detached { [weak self] in
                try? await Task.sleep(nanoseconds: ns)
                self?.expire(gen)
            }
        }
    }

    private func expire(_ gen: Int) {
        lock.lock()
        guard gen == generation, let w = waiter else { lock.unlock(); return }
        waiter = nil
        lock.unlock()
        w.resume(returning: nil)
    }

    /// Wakes a pending reader with nil (the link is closing).
    func cancel() {
        lock.lock()
        let w = waiter
        waiter = nil
        generation += 1
        lock.unlock()
        w?.resume(returning: nil)
    }
}
