import Foundation

enum JSONValue: Codable, Hashable, Sendable {
    case object([String: JSONValue])
    case array([JSONValue])
    case string(String)
    case number(Double)
    case bool(Bool)
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(Double.self) { self = .number(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode([String: JSONValue].self) { self = .object(value) }
        else { self = .array(try container.decode([JSONValue].self)) }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .object(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }

    subscript(_ key: String) -> JSONValue? {
        guard case .object(let object) = self else { return nil }
        return object[key]
    }

    func value(at path: String) -> JSONValue? {
        path.split(separator: ".").reduce(Optional(self)) { value, key in value?[String(key)] }
    }

    var string: String? {
        switch self {
        case .string(let value): value
        case .number(let value): value.rounded() == value ? String(Int(value)) : String(value)
        default: nil
        }
    }

    var bool: Bool? {
        guard case .bool(let value) = self else { return nil }
        return value
    }

    var array: [JSONValue]? {
        guard case .array(let value) = self else { return nil }
        return value
    }

    var object: [String: JSONValue]? {
        guard case .object(let value) = self else { return nil }
        return value
    }

    var int: Int? {
        guard case .number(let value) = self else { return nil }
        return Int(value)
    }

    static func stringObject(_ values: [String: String]) -> JSONValue {
        .object(values.mapValues(JSONValue.string))
    }
}

extension JSONValue: Identifiable {
    var id: String {
        for key in ["id", "order_id", "rental_id", "return_id", "deposit_id", "user_id", "cancellation_id", "payment_id", "invoice_id", "instrument_id", "order_item_id", "allocation_id", "proposal_id"] {
            if let value = self[key]?.string { return value }
        }
        return self["code"]?.string ?? self["slug"]?.string ?? String(hashValue)
    }
}
