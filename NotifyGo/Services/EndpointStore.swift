import Foundation

@MainActor
final class EndpointStore: ObservableObject {
    @Published private(set) var endpoints: [NotificationEndpoint] = []

    private let defaults: UserDefaults
    private let storageKey: String
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(defaults: UserDefaults = .standard, storageKey: String = "notificationEndpoints") {
        self.defaults = defaults
        self.storageKey = storageKey
        load()
    }

    func endpoint(id: UUID) -> NotificationEndpoint? {
        endpoints.first { $0.id == id }
    }

    func save(_ endpoint: NotificationEndpoint) {
        if let index = endpoints.firstIndex(where: { $0.id == endpoint.id }) {
            endpoints[index] = endpoint
        } else {
            endpoints.insert(endpoint, at: 0)
        }
        persist()
    }

    func delete(id: UUID) {
        endpoints.removeAll { $0.id == id }
        persist()
    }

    private func load() {
        guard let data = defaults.data(forKey: storageKey) else { return }
        endpoints = (try? decoder.decode([NotificationEndpoint].self, from: data)) ?? []
    }

    private func persist() {
        guard let data = try? encoder.encode(endpoints) else { return }
        defaults.set(data, forKey: storageKey)
    }
}
