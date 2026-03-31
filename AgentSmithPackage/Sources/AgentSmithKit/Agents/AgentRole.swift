import Foundation
import Synchronization

/// The role an agent plays in the system.
public enum AgentRole: String, Codable, Sendable, CaseIterable, CodingKeyRepresentable {
    case smith
    case brown
    case jones
    case summarizer

    /// Thread-safe storage for the user's preferred nickname.
    private static let _userNickname = Mutex("")

    /// The user's preferred nickname, used in system prompts and display labels.
    public static var userNickname: String {
        get { _userNickname.withLock { $0 } }
        set { _userNickname.withLock { $0 = newValue } }
    }

    /// Roles that must be configured for the system to start.
    public static let requiredRoles: [AgentRole] = [.smith, .brown, .jones, .summarizer]

    /// Human-readable name for display.
    public var displayName: String {
        switch self {
        case .smith: return "Smith"
        case .brown: return "Brown"
        case .jones: return "Jones"
        case .summarizer: return "Summarizer"
        }
    }

    private var baseSystemPromptSuffix: String {
        var results: [String] = []
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
        return baseSystemPromptSuffix
    }
}
