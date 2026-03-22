import Foundation

/// The role an agent plays in the system.
public enum AgentRole: String, Codable, Sendable, CaseIterable {
    case smith
    case brown
    case jones

    /// The user's preferred nickname, set at launch. Used in system prompts and display labels.
    /// Accessed from multiple isolation domains; writes happen only at app startup on MainActor.
    public nonisolated(unsafe) static var userNickname: String = ""

    /// Human-readable name for display.
    public var displayName: String {
        switch self {
        case .smith: return "Smith"
        case .brown: return "Brown"
        case .jones: return "Jones"
        }
    }

    private var baseSystemPromptSuffix: String {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss zzz"
        let dateStr = dateFormatter.string(from: Date())

        var results: [String] = []
        results.append("The current date and time are \(dateStr)")
        results.append("This device is running MacOS \(ProcessInfo.processInfo.operatingSystemVersionString)")
        let nickname = Self.userNickname
        if !nickname.isEmpty {
            results.append("The user prefers to be called: \(nickname)")
        }
        results.append("The current user's username is: \(NSUserName())")
        results.append("The user's home directory is: \(FileManager.default.homeDirectoryForCurrentUser.path)")
        results.append("The current working directory is: \(URL.currentDirectory().path)")
        return results.joined(separator: "\n")
    }
    /// Default system prompt for this role, used as the base before behavior-specific additions.
    public var baseSystemPrompt: String {
        switch self {
        case .smith:
            return """
            \(baseSystemPromptSuffix)
            """
        case .brown:
            return """
            \(baseSystemPromptSuffix)
            """
        case .jones:
            return """
            \(baseSystemPromptSuffix)
            """
        }
    }
}
