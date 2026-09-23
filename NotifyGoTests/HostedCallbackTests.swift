import XCTest
import CryptoKit
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

final class MigrationCodeTests: XCTestCase {
    func testCodeRoundTripsAndDerivesStableValues() throws {
        let code = MigrationCode()
        let parsed = try XCTUnwrap(MigrationCode("  \(code.text)\n"))
        XCTAssertTrue(code.text.hasPrefix(MigrationCode.prefix))
        XCTAssertEqual(parsed.lookup, code.lookup)
        XCTAssertEqual(parsed.lookup.count, 64)
        let sealed = try XCTUnwrap(AES.GCM.seal(Data("secret".utf8), using: code.key).combined)
        XCTAssertEqual(try AES.GCM.open(AES.GCM.SealedBox(combined: sealed), using: parsed.key), Data("secret".utf8))
    }

    func testInvalidCodesAreRejected() {
        XCTAssertNil(MigrationCode(""))
        XCTAssertNil(MigrationCode("NGM1-short"))
        XCTAssertNil(MigrationCode(String(MigrationCode().text.dropFirst(5))))
    }
}
