import Foundation

/// The outcome of Jones evaluating a tool request from Brown.
public struct SecurityDisposition: Sendable {
    public let approved: Bool
    /// Explanation — required when denied, recommended for medium-risk warnings.
    public let message: String?
    /// True when this is a WARN denial — the request can be retried once for auto-approval.
    public let isWarning: Bool
    /// True when this approval was automatic (identical retry of a WARN'd request).
    public let isAutoApproval: Bool

    public init(approved: Bool, message: String? = nil, isWarning: Bool = false, isAutoApproval: Bool = false) {
        self.approved = approved
        self.message = message
        self.isWarning = isWarning
        self.isAutoApproval = isAutoApproval
    }
}

/// Broker between Brown's tool-execution requests and Jones' approval decisions.
///
/// Brown suspends on `wait(for:)` until Jones calls `resolve(requestID:disposition:)`.
public actor ToolRequestGate {
    private var continuations: [UUID: CheckedContinuation<SecurityDisposition, Never>] = [:]

    public init() {}

    /// Suspends until Jones resolves the given request ID.
    public func wait(for requestID: UUID) async -> SecurityDisposition {
        await withCheckedContinuation { continuations[requestID] = $0 }
    }

    /// Called by Jones (via text response parsing) to unblock the waiting Brown tool call.
    public func resolve(requestID: UUID, disposition: SecurityDisposition) {
        continuations.removeValue(forKey: requestID)?.resume(returning: disposition)
    }

    /// Resolves all pending requests with the given disposition.
    /// Call this when Brown is being shut down to prevent suspended continuations from leaking.
    public func drainAll(approved: Bool = false, message: String? = nil) {
        let disposition = SecurityDisposition(approved: approved, message: message)
        for continuation in continuations.values {
            continuation.resume(returning: disposition)
        }
        continuations.removeAll()
    }
}
