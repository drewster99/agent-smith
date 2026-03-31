import Foundation

/// Represents a tool invocation requested by the LLM.
public struct LLMToolCall: Codable, Sendable {
    public var id: String
    public var name: String
    /// Raw JSON string of the arguments.
    public var arguments: String

    public init(id: String, name: String, arguments: String) {
        self.id = id
        self.name = name
        self.arguments = arguments
    }

    /// Parses the arguments JSON string into a dictionary.
    public func parsedArguments() throws -> [String: AnyCodable] {
        guard let data = arguments.data(using: .utf8) else {
            throw ToolCallError.invalidArgumentsEncoding
        }
        return try JSONDecoder().decode([String: AnyCodable].self, from: data)
    }
}

/// Errors that arise when validating or parsing tool call arguments from LLM responses.
public enum ToolCallError: Error, LocalizedError {
    case invalidArgumentsEncoding
    case missingRequiredArgument(String)
    case invalidArgumentType(name: String, expected: String)

    public var errorDescription: String? {
        switch self {
        case .invalidArgumentsEncoding:
            return "Tool call arguments are not valid UTF-8"
        case .missingRequiredArgument(let name):
            return "Missing required argument: \(name)"
        case .invalidArgumentType(let name, let expected):
            return "Argument '\(name)' should be \(expected)"
        }
    }
}
