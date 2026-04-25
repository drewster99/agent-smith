import Foundation

/// Append-only pub/sub message bus. All agents and the UI subscribe to messages.
public actor MessageChannel {
    private var messages: [ChannelMessage] = []
    private var subscribers: [UUID: @Sendable (ChannelMessage) -> Void] = [:]

    /// Maximum number of messages retained in memory. Older messages are trimmed on post.
    private let maxMessages: Int

    /// Identifier for the currently-running orchestration session. Set by
    /// `OrchestrationRuntime.start()` and cleared by `stopAll()`. Auto-stamped
    /// onto every posted message that doesn't already carry a sessionID, so
    /// every code path (including tools that don't know about sessions) gets
    /// session attribution for free.
    private var currentSessionID: UUID?

    public init(maxMessages: Int = 10_000) {
        self.maxMessages = maxMessages
    }

    /// Sets the session ID auto-stamped on all subsequent posts. Pass `nil` to
    /// clear (e.g. on `stopAll()`). Messages posted outside of an active session
    /// — before `start()` or after `stopAll()` — remain unstamped.
    public func setCurrentSessionID(_ id: UUID?) {
        currentSessionID = id
    }

    /// All messages posted so far.
    public func allMessages() -> [ChannelMessage] {
        messages
    }

    /// Posts a message to the channel and notifies all subscribers.
    /// If the message has no `sessionID` set, stamps it with the channel's
    /// current session (if any). Other context fields — `taskID`, `providerID`,
    /// `modelID`, `configuration` — are the caller's responsibility and are
    /// left alone here.
    public func post(_ message: ChannelMessage) {
        var stamped = message
        if stamped.sessionID == nil {
            stamped.sessionID = currentSessionID
        }
        messages.append(stamped)
        trimIfNeeded()
        for subscriber in subscribers.values {
            subscriber(stamped)
        }
    }

    /// Drops the oldest messages when the cap is exceeded.
    private func trimIfNeeded() {
        if messages.count > maxMessages {
            let excess = messages.count - maxMessages
            messages.removeFirst(excess)
        }
    }

    /// Subscribes to new messages. Returns a subscription ID for unsubscribing.
    @discardableResult
    public func subscribe(_ handler: @escaping @Sendable (ChannelMessage) -> Void) -> UUID {
        let id = UUID()
        subscribers[id] = handler
        return id
    }

    /// Removes a subscription.
    public func unsubscribe(_ id: UUID) {
        subscribers.removeValue(forKey: id)
    }

    /// Returns an `AsyncStream` of new messages from this point forward.
    public func stream() -> AsyncStream<ChannelMessage> {
        AsyncStream { continuation in
            let id = UUID()
            subscribers[id] = { message in
                continuation.yield(message)
            }
            continuation.onTermination = { [weak self] _ in
                guard let self else { return }
                Task { await self.unsubscribe(id) }
            }
        }
    }

    /// Messages posted since a given index (useful for building LLM context).
    ///
    /// - Warning: Positional indices shift after trimming. Do not cache indices
    ///   across ``post(_:)`` calls that may trigger a trim — the cached index may
    ///   reference a different message or be out of bounds.
    public func messages(since index: Int) -> [ChannelMessage] {
        guard index < messages.count else { return [] }
        return Array(messages[index...])
    }

    /// Messages with `timestamp >= cutoff`. Internally uses a binary search over the
    /// chronologically-ordered backing array, so for a 10K-message channel the digest
    /// no longer pays an O(N) scan per fire — typical digest windows of 10 minutes
    /// hit a few hundred messages at most.
    public func messages(since cutoff: Date) -> [ChannelMessage] {
        guard !messages.isEmpty else { return [] }
        if messages[0].timestamp >= cutoff { return messages }
        if messages[messages.count - 1].timestamp < cutoff { return [] }

        var lo = 0
        var hi = messages.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if messages[mid].timestamp < cutoff {
                lo = mid + 1
            } else {
                hi = mid
            }
        }
        return Array(messages[lo...])
    }

    /// Current message count.
    public var messageCount: Int {
        messages.count
    }
}
