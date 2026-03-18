import Foundation

/// The outcome of Jones evaluating a tool request from Brown.
public struct SecurityDisposition: Sendable {
    public let approved: Bool
    /// Explanation — required when denied, recommended for medium-risk warnings.
    public let message: String?

    public init(approved: Bool, message: String? = nil) {
        self.approved = approved
        self.message = message
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

    /// Called by Jones' `SecurityDispositionTool` to unblock the waiting Brown tool call.
    public func resolve(requestID: UUID, disposition: SecurityDisposition) {
        continuations.removeValue(forKey: requestID)?.resume(returning: disposition)
    }
}
