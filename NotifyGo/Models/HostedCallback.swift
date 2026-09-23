import Foundation

enum JSONValue: Codable, Equatable {
    case string(String), number(Double), bool(Bool), object([String: JSONValue]), array([JSONValue]), null

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
        case .string(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }
    var text: String {
        switch self {
        case .string(let value): value
        case .number(let value): String(value)
        case .bool(let value): String(value)
        default: ""
        }
    }
    var pretty: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return (try? String(decoding: encoder.encode(self), as: UTF8.self)) ?? ""
    }
}

struct CallbackTemplate: Codable, Equatable {
    var title = "{{title}}"
    var subtitle: String?
    var body = "{{body}}"
    var url = ""
    var icon: String?
    var group: String?
    var sound = "default"
    var level = "active"
    var badge = "unchanged"
    var badgeValue = 0
}

struct CallbackCondition: Codable, Equatable {
    var field = "type"
    var op = "eq"
    var value: JSONValue = .string("DID_RENEW")
}

struct CallbackRule: Codable, Identifiable, Equatable {
    var id = UUID().uuidString.lowercased()
    var name = "Default"
    var priority = 100
    var enabled = true
    var send = true
    var conditions: [CallbackCondition] = []
    var template = CallbackTemplate()
}

struct FieldMapping: Codable, Equatable {
    var field = "title"
    var source = "event.title"
}

struct HostedCallback: Codable, Identifiable, Equatable {
    var id = ""
    var name = ""
    var enabled = true
    var parser = "json"
    var appleBundleId = ""
    var appleAppId: Int?
    var appleEnvironment = "Sandbox"
    var symbol = "bell.badge.fill"
    var emoji = ""
    var imageURL = ""
    var color = "blue"
    var tags: [String] = []
    var mappings: [FieldMapping] = []
    var rules = [CallbackRule()]
    var callbackURL: String?

    var sample: String {
        parser == "apple"
        ? "{\n  \"type\": \"DID_RENEW\",\n  \"product\": \"premium.monthly\",\n  \"amount\": 9.99,\n  \"currency\": \"USD\",\n  \"country\": \"USA\",\n  \"environment\": \"Sandbox\"\n}"
        : "{\n  \"title\": \"Hello from NotifyGo\",\n  \"body\": \"Your Callback is ready.\"\n}"
    }
}

struct CallbackTrace: Decodable, Identifiable {
    let id: String
    let name: String
    let matched: Bool
}

struct CallbackPreview: Decodable {
    let fields: JSONValue
    let trace: [CallbackTrace]
    let matchedRuleId: String?
    let missing: [String]
    let notification: CallbackTemplate?
    let status: String
    let sampleOnly: Bool?
}

struct CallbackSource: Decodable {
    let name: String
    let symbol: String
    let emoji: String
    let imageURL: String
    let color: String
    let tags: [String]
}

struct CallbackEvent: Decodable, Identifiable {
    let id: String
    let createdAt: String
    let status: String
    let fields: JSONValue
    let notification: CallbackTemplate?
    let source: CallbackSource
    let test: Bool

    var deliveryCategory: CallbackDeliveryCategory? {
        switch status {
        case "sent": .sent
        case "failed": .failed
        case "disabled", "unmatched", "suppressed", "missing_fields", "sending", "ready": .notSent
        default: nil
        }
    }

    func matches(query: String) -> Bool {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return true }
        let values: [String?] = [notification?.title, notification?.body, source.name] + source.tags.map { Optional($0) }
        return values.compactMap { $0 }.contains {
            $0.range(of: query, options: [.caseInsensitive, .diacriticInsensitive], locale: .current) != nil
        }
    }
}

enum CallbackDeliveryCategory: String, CaseIterable, Identifiable, Equatable {
    case sent, failed, notSent
    var id: String { rawValue }
}
