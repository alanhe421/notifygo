import XCTest
@testable import NotifyGo

@MainActor
final class EndpointStoreTests: XCTestCase {
    private var defaults: UserDefaults!
    private let suite = "EndpointStoreTests"

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        super.tearDown()
    }

    func testCreateUpdateDeleteAndReload() {
        let store = EndpointStore(defaults: defaults, storageKey: "test")
        var endpoint = NotificationEndpoint(name: "Deploys")
        store.save(endpoint)
        XCTAssertEqual(store.endpoints, [endpoint])

        endpoint.defaultTitle = "Finished"
        store.save(endpoint)
        XCTAssertEqual(store.endpoints.count, 1)
        XCTAssertEqual(EndpointStore(defaults: defaults, storageKey: "test").endpoints.first?.defaultTitle, "Finished")

        store.delete(id: endpoint.id)
        XCTAssertTrue(EndpointStore(defaults: defaults, storageKey: "test").endpoints.isEmpty)
    }
}
