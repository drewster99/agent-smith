import Foundation

/// Describes a tool that an LLM can invoke.
public struct LLMToolDefinition: Codable, Sendable {
    public var name: String
    public var description: String
    /// JSON Schema describing the tool's parameters, stored as a dictionary.
    public var parameters: [String: AnyCodable]

    public init(name: String, description: String, parameters: [String: AnyCodable]) {
        self.name = name
        self.description = description
        self.parameters = parameters
    }
}

/// Type-erased Codable wrapper for JSON values.
public enum AnyCodable: Codable, Sendable, Hashable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case array([AnyCodable])
    case dictionary([String: AnyCodable])
    case null

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int.self) {
            self = .int(value)
        } else if let value = try? container.decode(Double.self) {
            self = .double(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([AnyCodable].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: AnyCodable].self) {
            self = .dictionary(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unable to decode AnyCodable"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .int(let value): try container.encode(value)
        case .double(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .dictionary(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }

    /// Convenience: returns the underlying value as a Swift `Any`.
    public var rawValue: Any {
        switch self {
        case .string(let v): return v
        case .int(let v): return v
        case .double(let v): return v
        case .bool(let v): return v
        case .array(let v): return v.map(\.rawValue)
        case .dictionary(let v): return v.mapValues(\.rawValue)
        case .null: return NSNull()
        }
    }
}
