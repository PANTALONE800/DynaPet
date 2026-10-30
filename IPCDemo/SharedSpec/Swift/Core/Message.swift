import Foundation

public enum JSONValue: Codable, Equatable {
    case null, bool(Bool), number(Double), string(String), array([JSONValue]), object([String: JSONValue])
    public init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer()
        if value.decodeNil() { self = .null }
        else if let v = try? value.decode(Bool.self) { self = .bool(v) }
        else if let v = try? value.decode(String.self) { self = .string(v) }
        else if let v = try? value.decode(Double.self) { self = .number(v) }
        else if let v = try? value.decode([JSONValue].self) { self = .array(v) }
        else { self = .object(try value.decode([String: JSONValue].self)) }
    }
    public func encode(to encoder: Encoder) throws {
        var value = encoder.singleValueContainer()
        switch self {
        case .null: try value.encodeNil()
        case .bool(let v): try value.encode(v)
        case .number(let v): try value.encode(v)
        case .string(let v): try value.encode(v)
        case .array(let v): try value.encode(v)
        case .object(let v): try value.encode(v)
        }
    }
    public var string: String? { if case .string(let value) = self { return value }; return nil }
    public var object: [String: JSONValue]? { if case .object(let value) = self { return value }; return nil }
}

public struct Message: Codable {
    public static let maximumBytes = 65_536
    public enum Kind: String, Codable { case request, response, event }
    public enum Invalid: Error { case size, envelope, body }
    public let version: Int
    public let id: String
    public let type: Kind
    public let body: [String: JSONValue]
    private enum CodingKeys: String, CodingKey { case version, id, type, body }
    private struct AnyKey: CodingKey {
        let stringValue: String
        let intValue: Int? = nil
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
    }
    public init(id: String, type: Kind, body: [String: JSONValue]) {
        self.version = 1; self.id = id; self.type = type; self.body = body
    }
    public init(from decoder: Decoder) throws {
        let all = try decoder.container(keyedBy: AnyKey.self)
        guard Set(all.allKeys.map(\.stringValue)) == ["version", "id", "type", "body"] else { throw Invalid.envelope }
        let values = try decoder.container(keyedBy: CodingKeys.self)
        version = try values.decode(Int.self, forKey: .version)
        id = try values.decode(String.self, forKey: .id)
        type = try values.decode(Kind.self, forKey: .type)
        body = try values.decode([String: JSONValue].self, forKey: .body)
    }
    public func validate() throws {
        guard version == 1, id.range(of: #"^[A-Za-z0-9_-]{1,64}$"#, options: .regularExpression) != nil else { throw Invalid.envelope }
        func keys(_ names: Set<String>) -> Bool { Set(body.keys) == names }
        func name(_ value: JSONValue?) -> Bool {
            guard let value = value?.string else { return false }
            return value.range(of: #"^[A-Za-z][A-Za-z0-9_.-]{0,63}$"#, options: .regularExpression) != nil
        }
        switch type {
        case .request:
            guard keys(["method", "params"]), name(body["method"]), body["params"]?.object != nil else { throw Invalid.body }
        case .response:
            switch body["ok"] {
            case .bool(true):
                guard keys(["ok", "result"]), body["result"]?.object != nil else { throw Invalid.body }
            case .bool(false):
                guard keys(["ok", "error"]), let error = body["error"]?.object,
                      Set(error.keys) == ["code", "message"], name(error["code"]),
                      let text = error["message"]?.string, text.utf8.count <= 2_048 else { throw Invalid.body }
            default: throw Invalid.body
            }
        case .event:
            guard keys(["name", "seq", "data"]), name(body["name"]),
                  case .number(let seq) = body["seq"], seq.isFinite, seq >= 1,
                  seq <= 9_007_199_254_740_991, seq.rounded() == seq,
                  body["data"]?.object != nil else { throw Invalid.body }
        }
    }
    public static func decode(_ data: Data) throws -> Message {
        guard data.count <= maximumBytes else { throw Invalid.size }
        let message = try JSONDecoder().decode(Message.self, from: data)
        try message.validate()
        return message
    }
    public func encodedLine() throws -> Data {
        try validate()
        var data = try JSONEncoder().encode(self)
        guard data.count <= Self.maximumBytes else { throw Invalid.size }
        data.append(10)
        return data
    }
}
