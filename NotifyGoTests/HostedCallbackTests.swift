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

    func testHistorySearchMatchesVisibleFieldsIgnoringCaseAndDiacritics() throws {
        let event = try decodeEvent(status: "sent")
        XCTAssertTrue(event.matches(query: " cafe "))
        XCTAssertTrue(event.matches(query: "PAYMENT"))
        XCTAssertTrue(event.matches(query: "billing"))
        XCTAssertTrue(event.matches(query: "收入"))
        XCTAssertTrue(event.matches(query: "   "))
        XCTAssertFalse(event.matches(query: "raw-only-value"))
    }

    func testHistoryDeliveryCategoriesKeepUnknownStatusesUnfiltered() throws {
        XCTAssertEqual(try decodeEvent(status: "sent").deliveryCategory, .sent)
        XCTAssertEqual(try decodeEvent(status: "failed").deliveryCategory, .failed)
        XCTAssertEqual(try decodeEvent(status: "suppressed").deliveryCategory, .notSent)
        XCTAssertNil(try decodeEvent(status: "future_status").deliveryCategory)
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
    private func decodeEvent(status: String) throws -> CallbackEvent {
        let json = """
        {"id":"event","createdAt":"2026-09-23T08:00:00.000Z","status":"\(status)",
         "fields":{"secret":"raw-only-value"},
         "notification":{"title":"Café Payment","body":"收入 received","url":"","sound":"default","level":"active","badge":"unchanged","badgeValue":0},
         "source":{"name":"Billing","symbol":"bell","emoji":"","imageURL":"","color":"blue","tags":["finance"]},"test":false}
        """
        return try JSONDecoder().decode(CallbackEvent.self, from: Data(json.utf8))
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
