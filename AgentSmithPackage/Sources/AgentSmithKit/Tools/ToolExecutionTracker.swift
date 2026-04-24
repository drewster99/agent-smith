import Foundation

/// Tracks the execution status of tool calls for security agent inspection.
///
/// Thread-safe storage for recording whether tool calls succeeded or failed
/// after being approved by the security agent.
public actor ToolExecutionTracker: Sendable {
    private var executionStatus: [String: Bool] = [:] // toolCallID -> succeeded
    
    public init() {}
    
    /// Records the execution status of a tool call.
    /// - Parameters:
    ///   - toolCallID: The ID of the tool call
    ///   - succeeded: Whether the tool execution succeeded
    public func recordExecutionStatus(toolCallID: String, succeeded: Bool) {
        executionStatus[toolCallID] = succeeded
    }
    
    /// Gets the execution status of a tool call.
    /// - Parameter toolCallID: The ID of the tool call
    /// - Returns: true if succeeded, false if failed, nil if not recorded
    public func getExecutionStatus(toolCallID: String) -> Bool? {
        executionStatus[toolCallID]
    }
    
    /// Checks if a tool call has already succeeded.
    /// - Parameter toolCallID: The ID of the tool call
    /// - Returns: true if the tool call has already succeeded
    public func hasSucceeded(toolCallID: String) -> Bool {
        executionStatus[toolCallID] == true
    }
    
    /// Checks if a tool call has already failed after being approved.
    /// - Parameter toolCallID: The ID of the tool call
    /// - Returns: true if the tool call has already failed
    public func hasFailed(toolCallID: String) -> Bool {
        executionStatus[toolCallID] == false
    }
}