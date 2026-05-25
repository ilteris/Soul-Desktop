import Foundation

public enum ACPProtocolVersion {
    public static let current: Int = 1
}

public struct JSONRPCEnvelope: Codable, Sendable {
    /// Optional on the wire: codex app-server omits this header per its
    /// protocol docs ("with the 'jsonrpc':'2.0' header omitted on the
    /// wire"). ACP servers include it. We always emit "2.0" on outgoing
    /// envelopes; on incoming we accept either shape.
    public var jsonrpc: String? = "2.0"
    public var id: JSONRPCID?
    public var method: String?
    public var params: JSONValue?
    public var result: JSONValue?
    public var error: JSONRPCError?

    public init(jsonrpc: String? = "2.0",
                id: JSONRPCID? = nil,
                method: String? = nil,
                params: JSONValue? = nil,
                result: JSONValue? = nil,
                error: JSONRPCError? = nil) {
        self.jsonrpc = jsonrpc
        self.id = id
        self.method = method
        self.params = params
        self.result = result
        self.error = error
    }
}

public enum JSONRPCID: Codable, Hashable, Sendable {
    case int(Int)
    case string(String)

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let i = try? c.decode(Int.self) { self = .int(i); return }
        self = .string(try c.decode(String.self))
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .int(let i):    try c.encode(i)
        case .string(let s): try c.encode(s)
        }
    }
}

public struct JSONRPCError: Codable, Error, Sendable {
    public var code: Int
    public var message: String
    public var data: JSONValue?

    public init(code: Int, message: String, data: JSONValue? = nil) {
        self.code = code
        self.message = message
        self.data = data
    }
}

public enum JSONValue: Codable, Sendable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: Decoder) throws {
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
    public func encode(to encoder: Encoder) throws {
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

    public var stringValue: String? {
        if case .string(let s) = self { return s } else { return nil }
    }
    public subscript(key: String) -> JSONValue? {
        if case .object(let o) = self { return o[key] } else { return nil }
    }
}

public struct InitializeRequest: Codable, Sendable {
    public var protocolVersion: Int
    public var clientCapabilities: ClientCapabilities?
    public var clientInfo: Implementation?

    public init(protocolVersion: Int, clientCapabilities: ClientCapabilities? = nil, clientInfo: Implementation? = nil) {
        self.protocolVersion = protocolVersion
        self.clientCapabilities = clientCapabilities
        self.clientInfo = clientInfo
    }
}

public struct InitializeResponse: Codable, Sendable {
    public var protocolVersion: Int
    public var agentCapabilities: AgentCapabilities?
    public var agentInfo: Implementation?
    public var authMethods: [AuthMethod]?
}

public struct Implementation: Codable, Sendable {
    public var name: String
    public var version: String

    public init(name: String, version: String) {
        self.name = name
        self.version = version
    }
}

public struct ClientCapabilities: Codable, Sendable {
    public var fs: FileSystemCapability?
    public var terminal: Bool?

    public init(fs: FileSystemCapability? = nil, terminal: Bool? = nil) {
        self.fs = fs
        self.terminal = terminal
    }
}
public struct FileSystemCapability: Codable, Sendable {
    public var readTextFile: Bool?
    public var writeTextFile: Bool?

    public init(readTextFile: Bool? = nil, writeTextFile: Bool? = nil) {
        self.readTextFile = readTextFile
        self.writeTextFile = writeTextFile
    }
}
public struct AgentCapabilities: Codable, Sendable {
    public var promptCapabilities: PromptCapabilities?
    public var loadSession: Bool?
    public var mcpCapabilities: JSONValue?
}
public struct PromptCapabilities: Codable, Sendable {
    public var image: Bool?
    public var audio: Bool?
    public var embeddedContext: Bool?
}
public struct AuthMethod: Codable, Sendable {
    public var id: String
    public var name: String?
    public var description: String?
}

public struct NewSessionRequest: Codable, Sendable {
    public var cwd: String
    public var mcpServers: [McpServer]
}
public struct NewSessionResponse: Codable, Sendable {
    public var sessionId: String
}
public struct LoadSessionRequest: Codable, Sendable {
    public var cwd: String
    public var mcpServers: [McpServer]
    public var sessionId: String
}
public struct LoadSessionResponse: Codable, Sendable {
    // configOptions, modes — ignored for now
}
public struct McpServer: Codable, Sendable {
    public var name: String
    public var command: String
    public var args: [String]?
    public var env: [EnvVariable]?
}
public struct EnvVariable: Codable, Sendable {
    public var name: String
    public var value: String
}

public struct PromptRequest: Codable, Sendable {
    public var sessionId: String
    public var prompt: [ContentBlock]
}
public struct PromptResponse: Codable, Sendable {
    public var stopReason: String
}

public enum ContentBlock: Codable, Hashable, Equatable, Sendable {
    case text(String)
    case image(mimeType: String, base64: String)

    private enum CodingKeys: String, CodingKey { case type, text, mimeType, data }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let type = try c.decode(String.self, forKey: .type)
        switch type {
        case "text": 
            self = .text(try c.decode(String.self, forKey: .text))
        case "image":
            let mimeType = try c.decode(String.self, forKey: .mimeType)
            let data = try c.decode(String.self, forKey: .data)
            self = .image(mimeType: mimeType, base64: data)
        default:     
            self = .text("")
        }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .text(let s):
            try c.encode("text", forKey: .type)
            try c.encode(s, forKey: .text)
        case .image(let mimeType, let base64):
            try c.encode("image", forKey: .type)
            try c.encode(mimeType, forKey: .mimeType)
            try c.encode(base64, forKey: .data)
        }
    }
}

public struct CancelNotification: Codable, Sendable {
    public var sessionId: String
}

public struct SessionNotification: Codable, Sendable {
    public var sessionId: String
    public var update: SessionUpdate
}

public enum SessionUpdate: Codable, Sendable {
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

    public init(from decoder: Decoder) throws {
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

    public func encode(to encoder: Encoder) throws {
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
    /// SOUL-SOUL_DESKTOP-107: ACP defines five ContentBlock types — text,
    /// image, audio, resource, resource_link. The legacy decoder only kept
    /// text and silently collapsed every other type to an empty string, so
    /// any provider that ships a resource_link in agent_message_chunk
    /// (Pi citing a file it read, for example) dropped the content on the
    /// floor and rendered an invisible message. Fall back to a textual
    /// surrogate for non-text types so the user can SEE that something
    /// arrived even before we wire structured rendering for each shape.
    init(fromUpdate raw: JSONValue) throws {
        guard case .object(let o) = raw,
              case .object(let content)? = o["content"],
              case .string(let type)? = content["type"]
        else {
            self = .text("")
            return
        }
        switch type {
        case "text":
            if case .string(let t)? = content["text"] {
                self = .text(t)
            } else {
                self = .text("")
            }
        case "resource_link":
            // ACP shape: { type: "resource_link", uri, name?, mimeType?, description?, title?, size? }
            let name = (content["name"] ?? content["title"])?.stringValue
            let uri = content["uri"]?.stringValue ?? ""
            let desc = content["description"]?.stringValue
            var label = name ?? uri
            if label.isEmpty { label = "(unnamed resource)" }
            var parts = ["📎 \(label)"]
            if !uri.isEmpty, uri != name { parts.append("(\(uri))") }
            if let d = desc, !d.isEmpty { parts.append("— \(d)") }
            self = .text(parts.joined(separator: " "))
        case "resource":
            // ACP shape: { type: "resource", resource: { uri, mimeType?, text?, blob? } }
            // Inline-text resources should render verbatim; binary blobs get a placeholder.
            if case .object(let res)? = content["resource"] {
                let uri = res["uri"]?.stringValue ?? ""
                if case .string(let t)? = res["text"], !t.isEmpty {
                    let header = uri.isEmpty ? "📄 (inline resource)" : "📄 \(uri)"
                    self = .text("\(header)\n\n\(t)")
                } else {
                    let mime = res["mimeType"]?.stringValue ?? "unknown"
                    self = .text("📎 \(uri.isEmpty ? "(unnamed resource)" : uri) [\(mime), binary]")
                }
            } else {
                self = .text("📎 (resource block, undecodable)")
            }
        case "image":
            // ACP shape: { type: "image", data: <base64>, mimeType: "image/..." }
            let mime = content["mimeType"]?.stringValue ?? "image"
            self = .text("🖼 [image: \(mime)]")
        case "audio":
            let mime = content["mimeType"]?.stringValue ?? "audio"
            self = .text("🔊 [audio: \(mime)]")
        default:
            // Unknown block type — surface the type name so we notice it on
            // canvas rather than silently dropping it. If a provider invents
            // a new type, we want to see it so we can add real handling.
            self = .text("[\(type) content block]")
        }
    }
}
