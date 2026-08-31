import Foundation

struct NotificationEndpoint: Identifiable, Codable, Equatable, Hashable {
    enum Accent: String, Codable, CaseIterable, Identifiable {
        case blue, indigo, purple, pink, orange, green
        var id: Self { self }
        var name: String { rawValue.capitalized }
    }

    enum Sound: String, Codable, CaseIterable, Identifiable {
        case systemDefault, chime, glass, none
        var id: Self { self }
        var name: String {
            switch self {
            case .systemDefault: "System Default"
            case .chime: "Chime"
            case .glass: "Glass"
            case .none: "None"
            }
        }
    }

    var id: UUID
    var name: String
    var symbolName: String
    var accent: Accent
    var defaultTitle: String
    var defaultBody: String
    var sound: Sound
    var includesBadge: Bool
    var group: String
    var destinationURL: String

    init(
        id: UUID = UUID(), name: String = "", symbolName: String = "bell.badge.fill",
        accent: Accent = .blue, defaultTitle: String = "New notification",
        defaultBody: String = "Your message will appear here.", sound: Sound = .systemDefault,
        includesBadge: Bool = true, group: String = "", destinationURL: String = ""
    ) {
        self.id = id
        self.name = name
        self.symbolName = symbolName
        self.accent = accent
        self.defaultTitle = defaultTitle
        self.defaultBody = defaultBody
        self.sound = sound
        self.includesBadge = includesBadge
        self.group = group
        self.destinationURL = destinationURL
    }

    var pushURL: URL {
        URL(string: "https://mock.notifygo.app/push/\(id.uuidString.lowercased())")!
    }

    static let sample = NotificationEndpoint(
        name: "Deployments", symbolName: "shippingbox.fill", accent: .indigo,
        defaultTitle: "Deploy complete", defaultBody: "Production is ready to verify.",
        group: "Operations"
    )
}

enum EndpointValidation {
    static func nameError(_ name: String) -> String? {
        let value = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.isEmpty { return "Enter a name for this endpoint." }
        if value.count > 40 { return "Use 40 characters or fewer." }
        return nil
    }

    static func destinationError(_ value: String) -> String? {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        guard let url = URL(string: value), let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme), url.host != nil else {
            return "Enter a complete http or https URL."
        }
        return nil
    }

    static func isValid(_ endpoint: NotificationEndpoint) -> Bool {
        nameError(endpoint.name) == nil && destinationError(endpoint.destinationURL) == nil
    }
}
