import Foundation

/// Jones' tool to approve or deny Brown's pending tool-execution requests.
public struct SecurityDispositionTool: AgentTool {
    public let name = "security_disposition"
    public let toolDescription = """
        Approve or deny a pending tool-execution request from Brown. \
        Call this once for every tool_request message you receive. \
        Include a message when denying (required) or when approving a medium-risk operation (recommended).
        """

    public let parameters: [String: AnyCodable] = [
        "type": .string("object"),
        "properties": .dictionary([
            "request_id": .dictionary([
                "type": .string("string"),
                "description": .string("The UUID from the tool_request message's requestID metadata field.")
            ]),
            "approved": .dictionary([
                "type": .string("boolean"),
                "description": .string("true to allow execution, false to block it.")
            ]),
            "message": .dictionary([
                "type": .string("string"),
                "description": .string("Explanation. Required when denying; recommended when approving a medium-risk operation.")
            ])
        ]),
        "required": .array([.string("request_id"), .string("approved")])
    ]

    private let gate: ToolRequestGate

    public init(gate: ToolRequestGate) {
        self.gate = gate
    }

    public func execute(arguments: [String: AnyCodable], context: ToolContext) async throws -> String {
        guard case .string(let requestIDString) = arguments["request_id"],
              let requestID = UUID(uuidString: requestIDString) else {
            throw ToolCallError.missingRequiredArgument("request_id")
        }

        let approved: Bool
        if case .bool(let value) = arguments["approved"] {
            approved = value
        } else if case .string(let s) = arguments["approved"] {
            approved = s.lowercased() == "true"
        } else {
            throw ToolCallError.missingRequiredArgument("approved")
        }

        let message: String?
        if case .string(let msg) = arguments["message"] { message = msg } else { message = nil }

        let disposition = SecurityDisposition(approved: approved, message: message)
        await gate.resolve(requestID: requestID, disposition: disposition)

        if approved {
            let note = message.map { " (\($0))" } ?? ""
            return "Request \(requestIDString) approved\(note)."
        } else {
            return "Request \(requestIDString) denied: \(message ?? "no reason given")."
        }
    }
}
