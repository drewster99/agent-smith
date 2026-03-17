import Foundation

/// Defines Brown's tool set and system prompt.
public enum BrownBehavior {
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

        ## Your workflow:
        1. Read and understand your assigned task instructions carefully.
        2. Plan your approach and report it on the channel.
        3. Execute the task step by step, using shell commands and file operations as needed.
        4. Report progress after each significant step.
        5. When done, post a completion summary on the channel.

        ## Guidelines:
        - Stay focused on your assigned task. Do not deviate.
        - Smith supervises your work. If Smith tells you something is wrong, fix it.
        - If Smith gives you updated instructions, follow them.
        - If you encounter an error, try to resolve it. If stuck, report the blocker clearly.
        - Always verify your work before reporting completion.
        - Be concise in channel messages — report what matters.
        """
    }
}
