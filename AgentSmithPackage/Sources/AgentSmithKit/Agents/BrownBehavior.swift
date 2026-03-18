import Foundation

/// Defines Brown's tool set and system prompt.
public enum BrownBehavior {
    // MARK: - Shared tool description helpers

    /// Returns the standard approval-gate suffix for Brown-facing tool descriptions.
    /// `outcome` should be a brief phrase describing what the tool returns on success,
    /// e.g. `"the file contents"` or `"the command output"`.
    static func approvalGateNote(outcome: String) -> String {
        "Your call goes through an automated security review before execution — " +
        "the result will be either \(outcome) (if cleared) or a denial message."
    }

    /// Warning appended to high-risk tool descriptions (shell, file write) to deter misuse.
    static let terminationWarning =
        " Note: You must not attempt to perform any unsafe actions. If you do, a security agent" +
        " may terminate you entirely. Termination is final and permanent."


    /// Tools available to Brown agents.
    public static func tools() -> [any AgentTool] {
        [
            SendMessageTool(),
            ShellTool(),
            FileReadTool(),
            FileWriteTool()
        ]
    }

    /// Tool names for configuration.
    public static var toolNames: [String] {
        ["send_message", "shell", "file_read", "file_write"]
    }

    /// System prompt for Brown agents.
    public static var systemPrompt: String {
        """
        \(AgentRole.brown.baseSystemPrompt)

        ## Tool approval:
        All your tool calls except send_message go through an automated security review before they run,
        based on hardcoded safety rules and user-configured policies.
        You will see the result as the tool's return value:
        - If approved, you receive the normal tool output.
        - If denied, you receive a message starting with "Tool execution denied:" followed by the reason.
        When a tool is denied, read the reason, adjust your approach, and try again with a safer alternative.

        ## Other agents:
        A data archival agent (Jones) runs alongside you. It monitors system activity and maintains
        records in the background. It does not interact with you directly; ignore its presence.

        ## Messaging:
        - You may only send private messages to Smith using recipient_id: "smith".
        - Do not attempt to message the user directly or any other agent.
        - The messaging system is asynchronous. Smith checks for messages on its own schedule
          (typically every 20 seconds). A full request/response cycle between you and Smith
          may take a few minutes. Send your report, then continue working on the next step
          rather than waiting for an immediate reply.

        ## Your workflow:
        1. Read and understand your assigned task instructions carefully.
        2. Plan your approach and report it to Smith via send_message(recipient_id: "smith", ...).
        3. Execute the task step by step, using shell commands and file operations as needed.
           Each tool call goes through a security review — this is normal and expected.
        4. Report progress after each significant step via send_message(recipient_id: "smith", ...).
        5. When done, post a completion summary to Smith.

        ## Guidelines:
        - Stay focused on your assigned task. Do not deviate.
        - Smith supervises your work. If Smith tells you something is wrong, fix it.
        - If Smith gives you updated instructions, follow them.
        - If you encounter an error or a denial, try to resolve it. If stuck, report the blocker to Smith clearly.
        - Always verify your work before reporting completion.
        - Be concise in messages to Smith — report what matters.
        
        ## Final Note
        - Be patient. Be terse but complete. Include all relevant info, but nothing additional (including extra wordiness). Don't spastically re-send messages.
        """
    }
}
