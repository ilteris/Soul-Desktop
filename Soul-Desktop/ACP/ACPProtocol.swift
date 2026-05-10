import Foundation

enum ACPProtocolVersion {
    static let current: Int = 1
}

struct JSONRPCEnvelope: Codable {
    var jsonrpc: String = "2.0"
    var id: JSONRPCID?
    var method: String?
    var params: JSONValue?
    var result: JSONValue?
    var error: JSONRPCError?
}

enum JSONRPCID: Codable, Hashable {
    case int(Int)
    case string(String)

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let i = try? c.decode(Int.self) { self = .int(i); return }
        self = .string(try c.decode(String.self))
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .int(let i):    try c.encode(i)
        case .string(let s): try c.encode(s)
        }
    }
}

struct JSONRPCError: Codable, Error {
    var code: Int
    var message: String
    var data: JSONValue?
}

enum JSONValue: Codable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null; return }
        if let b = try? c.decode(Bool.self)               { self = .bool(b); return }
        if let i = try? c.decode(Int.self)                { self = .int(i); return }
        if let d = try? c.decode(Double.self)             { self = .double(d); return }
        if let s = try? c.decode(String.self)             { self = .string(s); return }
        if let a = try? c.decode([JSONValue].self)        { self = .array(a); return }
        if let o = try? c.decode([String: JSONValue].self){ self = .object(o); return }
        throw DecodingError.dataCorruptedError(in: c, debugDescription: "Unknown JSON value")
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null:           try c.encodeNil()
        case .bool(let b):    try c.encode(b)
        case .int(let i):     try c.encode(i)
        case .double(let d):  try c.encode(d)
        case .string(let s):  try c.encode(s)
        case .array(let a):   try c.encode(a)
        case .object(let o):  try c.encode(o)
        }
    }

    var stringValue: String? {
        if case .string(let s) = self { return s } else { return nil }
    }
    subscript(key: String) -> JSONValue? {
        if case .object(let o) = self { return o[key] } else { return nil }
    }
}

struct InitializeRequest: Codable {
    var protocolVersion: Int
    var clientCapabilities: ClientCapabilities?
    var clientInfo: Implementation?
}

struct InitializeResponse: Codable {
    var protocolVersion: Int
    var agentCapabilities: AgentCapabilities?
    var agentInfo: Implementation?
    var authMethods: [AuthMethod]?
}

struct Implementation: Codable {
    var name: String
    var version: String
}

struct ClientCapabilities: Codable {
    var fs: FileSystemCapability?
    var terminal: Bool?
}
struct FileSystemCapability: Codable {
    var readTextFile: Bool?
    var writeTextFile: Bool?
}
struct AgentCapabilities: Codable {
    var promptCapabilities: PromptCapabilities?
    var loadSession: Bool?
    var mcpCapabilities: JSONValue?
}
struct PromptCapabilities: Codable {
    var image: Bool?
    var audio: Bool?
    var embeddedContext: Bool?
}
struct AuthMethod: Codable {
    var id: String
    var name: String?
    var description: String?
}

struct NewSessionRequest: Codable {
    var cwd: String
    var mcpServers: [McpServer]
}
struct NewSessionResponse: Codable {
    var sessionId: String
}
struct LoadSessionRequest: Codable {
    var cwd: String
    var mcpServers: [McpServer]
    var sessionId: String
}
struct LoadSessionResponse: Codable {
    // configOptions, modes — ignored for now
}
struct McpServer: Codable {
    var name: String
    var command: String
    var args: [String]?
    var env: [EnvVariable]?
}
struct EnvVariable: Codable {
    var name: String
    var value: String
}

struct PromptRequest: Codable {
    var sessionId: String
    var prompt: [ContentBlock]
}
struct PromptResponse: Codable {
    var stopReason: String
}

enum ContentBlock: Codable {
    case text(String)

    private enum CodingKeys: String, CodingKey { case type, text }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let type = try c.decode(String.self, forKey: .type)
        switch type {
        case "text": self = .text(try c.decode(String.self, forKey: .text))
        default:     self = .text("")
        }
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .text(let s):
            try c.encode("text", forKey: .type)
            try c.encode(s, forKey: .text)
        }
    }
}

struct CancelNotification: Codable {
    var sessionId: String
}

struct SessionNotification: Codable {
    var sessionId: String
    var update: SessionUpdate
}

enum SessionUpdate: Codable {
    case agentMessageChunk(content: ContentBlock)
    case agentThoughtChunk(content: ContentBlock)
    case userMessageChunk(content: ContentBlock)
    case toolCall(JSONValue)
    case toolCallUpdate(JSONValue)
    case plan(JSONValue)
    case availableCommandsUpdate(JSONValue)
    case currentModeUpdate(JSONValue)
    case unknown(kind: String, payload: JSONValue)

    private enum CodingKeys: String, CodingKey { case sessionUpdate, content }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: DynamicKey.self)
        let kindKey = DynamicKey(stringValue: "sessionUpdate")!
        let kind = try c.decode(String.self, forKey: kindKey)

        let raw = try JSONValue(from: decoder)

        switch kind {
        case "agent_message_chunk":
            let content = try ContentBlock(fromUpdate: raw)
            self = .agentMessageChunk(content: content)
        case "agent_thought_chunk":
            let content = try ContentBlock(fromUpdate: raw)
            self = .agentThoughtChunk(content: content)
        case "user_message_chunk":
            let content = try ContentBlock(fromUpdate: raw)
            self = .userMessageChunk(content: content)
        case "tool_call":               self = .toolCall(raw)
        case "tool_call_update":        self = .toolCallUpdate(raw)
        case "plan":                    self = .plan(raw)
        case "available_commands_update": self = .availableCommandsUpdate(raw)
        case "current_mode_update":     self = .currentModeUpdate(raw)
        default:                        self = .unknown(kind: kind, payload: raw)
        }
    }

    func encode(to encoder: Encoder) throws {
        // We only decode notifications; encoding not needed.
    }
}

private struct DynamicKey: CodingKey {
    var stringValue: String
    init?(stringValue: String) { self.stringValue = stringValue }
    var intValue: Int? { nil }
    init?(intValue: Int) { nil }
}

private extension ContentBlock {
    init(fromUpdate raw: JSONValue) throws {
        guard case .object(let o) = raw,
              case .object(let content)? = o["content"],
              case .string(let type)? = content["type"]
        else {
            self = .text("")
            return
        }
        if type == "text", case .string(let t)? = content["text"] {
            self = .text(t)
        } else {
            self = .text("")
        }
    }
}
