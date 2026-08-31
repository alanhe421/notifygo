import XCTest
@testable import NotifyGo

final class EndpointValidationTests: XCTestCase {
    func testNameIsRequired() { XCTAssertNotNil(EndpointValidation.nameError("  \n")) }
    func testNormalNameIsValid() { XCTAssertNil(EndpointValidation.nameError("Deploys")) }
    func testHTTPSDestinationIsValid() { XCTAssertNil(EndpointValidation.destinationError("https://example.com/build")) }
    func testInvalidDestinationIsRejected() { XCTAssertNotNil(EndpointValidation.destinationError("example.com")) }
    func testEmptyDestinationIsAllowed() { XCTAssertNil(EndpointValidation.destinationError("")) }
}
