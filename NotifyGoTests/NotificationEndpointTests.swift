import XCTest
@testable import NotifyGo

final class NotificationEndpointTests: XCTestCase {
    func testPushURLIsStableAndUsesMockHost() {
        let id = UUID(uuidString: "C1B63A14-02C2-47D4-83A6-F44FB12A6849")!
        let endpoint = NotificationEndpoint(id: id, name: "Builds")
        XCTAssertEqual(endpoint.pushURL.host, "mock.notifygo.app")
        XCTAssertTrue(endpoint.pushURL.path.hasSuffix(id.uuidString.lowercased()))
    }

    func testCodableRoundTripPreservesConfiguration() throws {
        let value = NotificationEndpoint.sample
        let decoded = try JSONDecoder().decode(NotificationEndpoint.self, from: JSONEncoder().encode(value))
        XCTAssertEqual(decoded, value)
    }
}
