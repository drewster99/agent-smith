#if DEBUG
import Foundation

extension AgentActor {
    /// Scans `conversationHistory` for structural violations that would cause API errors
    /// (e.g., orphaned tool_use without matching tool_result, or vice versa) and fixes them.
    ///
    /// This is a recovery mechanism for after destructive context pruning. It should be
    /// excluded from release builds once pruning is replaced with a non-destructive approach.
    func sanitizeHistory() {
        // 1. Collect all tool_use IDs from assistant messages and their positions.
        //    Each assistant message can contain multiple tool calls.
        var toolUseIDs: Set<String> = []          // All IDs the assistant requested
        var toolUsePositions: [String: Int] = [:]  // ID → index of the assistant message

        for (index, message) in conversationHistory.enumerated() {
            guard message.role == .assistant else { continue }
            let calls: [LLMToolCall]
            switch message.content {
            case .toolCalls(let c): calls = c
            case .mixed(_, let c): calls = c
            default: continue
            }
            for call in calls {
                toolUseIDs.insert(call.id)
                toolUsePositions[call.id] = index
            }
        }

        // 2. Collect all tool_result IDs from tool messages.
        var toolResultIDs: Set<String> = []
        for message in conversationHistory {
            guard message.role == .tool,
                  case .toolResult(let toolCallID, _) = message.content else { continue }
            toolResultIDs.insert(toolCallID)
        }

        // 3. Find orphans.
        let useWithoutResult = toolUseIDs.subtracting(toolResultIDs)
        let resultWithoutUse = toolResultIDs.subtracting(toolUseIDs)

        guard !useWithoutResult.isEmpty || !resultWithoutUse.isEmpty else { return }

        var fixes: [String] = []

        // 4. Remove orphaned tool_result messages (result exists but tool_use was pruned).
        if !resultWithoutUse.isEmpty {
            conversationHistory.removeAll { message in
                guard message.role == .tool,
                      case .toolResult(let toolCallID, _) = message.content,
                      resultWithoutUse.contains(toolCallID) else { return false }
                return true
            }
            fixes.append("Removed \(resultWithoutUse.count) orphaned tool result(s)")
        }

        // 5. Insert synthetic tool_result for orphaned tool_use calls.
        //    We need to insert them right after the assistant message that made the call.
        //    Work backwards so insertions don't shift indices of earlier items.
        if !useWithoutResult.isEmpty {
            // Group orphaned IDs by their assistant message index.
            var orphansByPosition: [Int: [String]] = [:]
            for id in useWithoutResult {
                guard let position = toolUsePositions[id] else { continue }
                orphansByPosition[position, default: []].append(id)
            }

            // Find where to insert: right after the assistant message, but after any
            // existing tool results that are already there.
            let sortedPositions = orphansByPosition.keys.sorted(by: >)
            for assistantIndex in sortedPositions {
                guard let ids = orphansByPosition[assistantIndex] else { continue }
                // Find the insertion point: skip past any consecutive .tool messages
                // that immediately follow this assistant message.
                var insertAt = assistantIndex + 1
                while insertAt < conversationHistory.count,
                      conversationHistory[insertAt].role == .tool {
                    insertAt += 1
                }
                // Insert synthetic results for each orphaned tool call.
                for id in ids {
                    let synthetic = LLMMessage(
                        role: .tool,
                        content: .toolResult(
                            toolCallID: id,
                            content: "[Result unavailable — removed from context]"
                        )
                    )
                    conversationHistory.insert(synthetic, at: insertAt)
                    insertAt += 1
                }
            }
            fixes.append("Inserted \(useWithoutResult.count) synthetic tool result(s)")
        }

        // 6. Update the turn baseline since we modified the array.
        lastTurnMessageCount = conversationHistory.count

        // 7. Log what we fixed.
        let roleName = configuration.role.displayName
        let channel = toolContext.channel
        let description = fixes.joined(separator: "; ")
        Task.detached {
            await channel.post(ChannelMessage(
                sender: .system,
                content: "History sanitized for \(roleName): \(description)."
            ))
        }
    }
}
#endif
