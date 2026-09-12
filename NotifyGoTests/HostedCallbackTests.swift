import XCTest
@testable import NotifyGo

final class HostedCallbackTests: XCTestCase {
    func testTypedConditionValuesRoundTrip() throws {
        var callback = HostedCallback()
        callback.name = "Sales"
        callback.rules[0].conditions = [
            CallbackCondition(field: "amount", op: "gt", value: .number(9.99)),
            CallbackCondition(field: "environment", op: "eq", value: .string("Production")),
            CallbackCondition(field: "trial", op: "eq", value: .bool(false))
        ]
        let data = try JSONEncoder().encode(callback)
        XCTAssertEqual(try JSONDecoder().decode(HostedCallback.self, from: data), callback)
    }

    func testServerPreviewAndHistoryDecode() throws {
        let json = """
        {"fields":{"amount":9.99,"isTrial":false,"product":{"id":"premium"}},
         "trace":[{"id":"rule","name":"Sales","matched":true}],
         "matchedRuleId":"rule","missing":[],"notification":null,"status":"suppressed"}
        """
        let preview = try JSONDecoder().decode(CallbackPreview.self, from: Data(json.utf8))
        XCTAssertEqual(preview.status, "suppressed")
        XCTAssertNil(preview.sampleOnly)
        XCTAssertEqual(preview.matchedRuleId, "rule")
        XCTAssertTrue(preview.trace[0].matched)
        XCTAssertTrue(preview.fields.pretty.contains("premium"))
    }

    func testUnsignedSampleIsExplicitlyDifferentFromAppleSignedInput() throws {
        var callback = HostedCallback()
        callback.parser = "apple"
        let sample = try JSONDecoder().decode(JSONValue.self, from: Data(callback.sample.utf8))
        guard case .object(let fields) = sample else { return XCTFail("Expected object") }
        XCTAssertNil(fields["signedPayload"])
        XCTAssertEqual(fields["amount"], .number(9.99))
        XCTAssertEqual(fields["country"], .string("USA"))
    }
}
