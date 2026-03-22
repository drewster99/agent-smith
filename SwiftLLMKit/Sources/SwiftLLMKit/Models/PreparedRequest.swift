import Foundation

/// A partially-built request ready for the app to add messages/tools and send.
///
/// SwiftLLMKit sets the URL, auth headers, and base body parameters.
/// The consuming app adds `messages`, `tools`, `system`, etc. to `baseBody`
/// and serializes it as the request's HTTP body.
///
/// - Note: Marked `@unchecked Sendable` because `baseBody` uses `[String: Any]`.
///   This is safe because all creation and consumption happens on `@MainActor`
///   (`LLMKitManager.prepareRequest()` → `AppViewModel`). The struct is a
///   short-lived transfer object that does not cross isolation boundaries.
public struct PreparedRequest: @unchecked Sendable {
    /// URLRequest with URL, HTTP method, and auth headers already configured.
    public let urlRequest: URLRequest
    /// Base body parameters: model, temperature, max_tokens, thinking, stream, etc.
    /// The app merges its own keys (messages, tools) into this dictionary before sending.
    public let baseBody: [String: Any]
    /// The provider type, so the app knows which message format to use.
    public let providerType: ProviderType
    /// Whether the configuration requested streaming.
    public let streaming: Bool

    public init(
        urlRequest: URLRequest,
        baseBody: [String: Any],
        providerType: ProviderType,
        streaming: Bool
    ) {
        self.urlRequest = urlRequest
        self.baseBody = baseBody
        self.providerType = providerType
        self.streaming = streaming
    }
}
