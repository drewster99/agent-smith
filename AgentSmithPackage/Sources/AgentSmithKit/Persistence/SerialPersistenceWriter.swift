import Foundation
import os

/// Coalescing serial writer for snapshot-style persistence.
///
/// Each `enqueue(_:)` overwrites any prior un-drained snapshot, so a burst of
/// rapid enqueues collapses to at most a few writes. Snapshots are written in
/// strict FIFO order — never an older snapshot after a newer one — and a
/// completed `flush()` guarantees every snapshot enqueued before the flush call
/// has hit the closure.
///
/// Replaces the prior `Task.detached { await persistence.saveX(snapshot) }`
/// pattern, which captured snapshots on MainActor in deterministic order but
/// then raced into the persistence actor with no ordering guarantee. Under that
/// pattern an older snapshot could win the race and overwrite a newer one on
/// disk, and `flushPersistence()` couldn't actually drain in-flight writes.
public actor SerialPersistenceWriter<Snapshot: Sendable> {
    private let label: String
    private let logger: Logger
    private let write: @Sendable (Snapshot) async throws -> Void

    private var pending: Snapshot?
    private var inflight: Task<Void, Never>?

    public init(
        label: String,
        logger: Logger = Logger(subsystem: "com.agentsmith", category: "SerialPersistenceWriter"),
        write: @escaping @Sendable (Snapshot) async throws -> Void
    ) {
        self.label = label
        self.logger = logger
        self.write = write
    }

    /// Schedule a write for `snapshot`. Replaces any prior un-drained snapshot.
    public func enqueue(_ snapshot: Snapshot) {
        pending = snapshot
        if inflight == nil {
            inflight = Task { [weak self] in
                await self?.drain()
            }
        }
    }

    /// Returns once every snapshot enqueued before this call has been written.
    /// Loops because new enqueues may arrive while the prior in-flight task is draining.
    public func flush() async {
        while let task = inflight {
            await task.value
            // After awaiting, `inflight` may have been re-set by a fresh enqueue
            // that landed while we were suspended. The loop catches that.
        }
    }

    private func drain() async {
        defer { inflight = nil }
        while let snapshot = pending {
            pending = nil
            do {
                try await write(snapshot)
            } catch {
                logger.error("Persistence write failed [\(self.label, privacy: .public)]: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}
