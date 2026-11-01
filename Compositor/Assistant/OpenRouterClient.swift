import Foundation

/// Any JSON value: tool schemas going out, tool arguments and results coming back.
nonisolated enum JSONValue: Codable, Equatable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        // Bool first: JSONDecoder won't read 0 or 1 as one, but would read true as a number on some paths.
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(Double.self) { self = .number(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode([JSONValue].self) { self = .array(value) }
        else if let value = try? container.decode([String: JSONValue].self) { self = .object(value) }
        else { throw DecodingError.dataCorruptedError(in: container, debugDescription: "Not a JSON value") }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }

    /// Compact JSON text, keys sorted so the same value always reads the same.
    var encodedString: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(self), let text = String(data: data, encoding: .utf8) else { return "null" }
        return text
    }

    static func int(_ value: Int) -> JSONValue { .number(Double(value)) }
}

/// One message in an OpenAI-style chat: the system prompt, the person's words, the model's reply (text and/or tool
/// calls), or a tool's result.
nonisolated struct ChatMessage: Codable, Equatable, Sendable {
    var role: String
    var content: String?
    var toolCalls: [ToolCall]?
    var toolCallID: String?
    /// Pictures sent with a user message, as data URLs, for a model that can see. With any, the content goes out as a
    /// list of parts: the text, then each picture.
    var images: [String] = []

    static func system(_ text: String) -> ChatMessage { ChatMessage(role: "system", content: text) }
    static func user(_ text: String, images: [String] = []) -> ChatMessage {
        var message = ChatMessage(role: "user", content: text)
        message.images = images
        return message
    }
    static func tool(_ id: String, content: String) -> ChatMessage { ChatMessage(role: "tool", content: content, toolCallID: id) }

    init(role: String, content: String?, toolCalls: [ToolCall]? = nil, toolCallID: String? = nil) {
        self.role = role
        self.content = content
        self.toolCalls = toolCalls
        self.toolCallID = toolCallID
    }

    enum CodingKeys: String, CodingKey {
        case role, content
        case toolCalls = "tool_calls"
        case toolCallID = "tool_call_id"
    }

    private nonisolated struct Part: Codable {
        nonisolated struct ImageURL: Codable { var url: String }
        var type: String
        var text: String?
        var imageURL: ImageURL?

        enum CodingKeys: String, CodingKey {
            case type, text
            case imageURL = "image_url"
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        role = try container.decodeIfPresent(String.self, forKey: .role) ?? "assistant"
        // Some providers answer in parts too; only their text is kept.
        if let text = try? container.decodeIfPresent(String.self, forKey: .content) {
            content = text
        } else if let parts = try? container.decodeIfPresent([Part].self, forKey: .content) {
            let text = parts.compactMap(\.text).joined(separator: "\n")
            content = text.isEmpty ? nil : text
        } else {
            content = nil
        }
        toolCalls = try container.decodeIfPresent([ToolCall].self, forKey: .toolCalls)
        toolCallID = try container.decodeIfPresent(String.self, forKey: .toolCallID)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(role, forKey: .role)
        if !images.isEmpty {
            let parts = [Part(type: "text", text: content ?? "")]
                + images.map { Part(type: "image_url", imageURL: Part.ImageURL(url: $0)) }
            try container.encode(parts, forKey: .content)
        } else {
            // Always written, null beside tool calls: some providers reject an assistant message without it.
            try container.encode(content, forKey: .content)
        }
        if let toolCalls, !toolCalls.isEmpty { try container.encode(toolCalls, forKey: .toolCalls) }
        try container.encodeIfPresent(toolCallID, forKey: .toolCallID)
    }
}

nonisolated struct ToolCall: Codable, Equatable, Sendable {
    var id: String
    var type: String = "function"
    var function: FunctionCall

    init(id: String, name: String, arguments: String) {
        self.id = id
        self.function = FunctionCall(name: name, arguments: arguments)
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        type = try container.decodeIfPresent(String.self, forKey: .type) ?? "function"
        function = try container.decode(FunctionCall.self, forKey: .function)
    }
}

nonisolated struct FunctionCall: Codable, Equatable, Sendable {
    var name: String
    /// A JSON object written out as a string, as the API sends it.
    var arguments: String

    init(name: String, arguments: String) {
        self.name = name
        self.arguments = arguments
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        // A few providers send the object itself rather than its text; it's kept as text either way.
        if let text = try? container.decode(String.self, forKey: .arguments) { arguments = text }
        else if let value = try? container.decode(JSONValue.self, forKey: .arguments) { arguments = value.encodedString }
        else { arguments = "" }
    }
}

/// A tool the model may call: its name, what it's for, and its parameters as JSON Schema.
nonisolated struct ToolDefinition: Encodable, Equatable, Sendable {
    nonisolated struct Function: Encodable, Equatable, Sendable {
        var name: String
        var description: String
        var parameters: JSONValue
    }
    var type = "function"
    var function: Function

    init(name: String, description: String, parameters: JSONValue) {
        function = Function(name: name, description: description, parameters: parameters)
    }
}

nonisolated struct ChatRequest: Encodable, Equatable, Sendable {
    var model: String
    var messages: [ChatMessage]
    var tools: [ToolDefinition]
    var toolChoice = "auto"

    enum CodingKeys: String, CodingKey {
        case model, messages, tools
        case toolChoice = "tool_choice"
    }
}

nonisolated struct ChatResponse: Decodable, Sendable {
    nonisolated struct Choice: Decodable, Sendable {
        var message: ChatMessage
    }
    nonisolated struct APIError: Decodable, Sendable {
        var message: String?
    }
    var choices: [Choice]?
    var error: APIError?
}

nonisolated enum OpenRouterError: LocalizedError, Equatable {
    case missingKey
    case http(status: Int, message: String?)
    case api(String)
    case malformed
    case empty

    var errorDescription: String? {
        switch self {
        case .missingKey: "Add your OpenRouter API key in Settings to use the assistant."
        case .http(401, _), .http(403, _): "OpenRouter didn’t accept the API key. Check it in Settings."
        case .http(402, _): "Your OpenRouter account is out of credit."
        case .http(429, _): "OpenRouter is limiting requests right now. Wait a moment and try again."
        case .http(let status, let message): "OpenRouter answered with an error (\(status))" + (message.map { ": \($0)" } ?? ".")
        case .api(let message): "OpenRouter: \(message)"
        case .malformed: "OpenRouter’s answer couldn’t be read."
        case .empty: "The model sent back an empty answer."
        }
    }
}

/// OpenRouter's OpenAI-compatible chat completions, without streaming.
nonisolated struct OpenRouterClient: Sendable {
    static let endpoint = URL(string: "https://openrouter.ai/api/v1/chat/completions")!
    /// A model that calls tools and can see, as `look_at_canvas` needs.
    static let defaultModel = "deepseek/deepseek-v4.1-flash"

    var session: URLSession = .shared

    func urlRequest(for chat: ChatRequest, apiKey: String) throws -> URLRequest {
        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Compositor", forHTTPHeaderField: "X-Title")
        request.httpBody = try JSONEncoder().encode(chat)
        return request
    }

    /// The model's reply. Cancelling the calling task cancels the request.
    // VERIFY(macOS): Stop cancels the task awaiting `data(for:)`, and URLSession then throws CancellationError or
    // URLError(.cancelled) promptly, which `AssistantSession` reports as "Stopped."
    func complete(_ chat: ChatRequest, apiKey: String) async throws -> ChatMessage {
        guard !apiKey.isEmpty else { throw OpenRouterError.missingKey }
        let (data, response) = try await session.data(for: try urlRequest(for: chat, apiKey: apiKey))
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let decoded = try? JSONDecoder().decode(ChatResponse.self, from: data)
        guard (200..<300).contains(status) else {
            throw OpenRouterError.http(status: status, message: decoded?.error?.message)
        }
        return try Self.message(from: data)
    }

    /// The first choice's message in a response body; an error the body carries instead is thrown.
    static func message(from data: Data) throws -> ChatMessage {
        guard let decoded = try? JSONDecoder().decode(ChatResponse.self, from: data) else { throw OpenRouterError.malformed }
        if let error = decoded.error { throw OpenRouterError.api(error.message ?? "Unknown error") }
        guard let message = decoded.choices?.first?.message else { throw OpenRouterError.empty }
        return message
    }
}
