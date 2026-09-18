import XCTest
@testable import StaminaKit

final class EventsTests: XCTestCase {
    func testNormalizeName() {
        XCTAssertEqual(Events.normalizeName("  Level-Complete "), "level_complete")
        XCTAssertTrue(Events.standard.contains("level_complete"))
    }

    func testNormalizeStep() {
        XCTAssertEqual(Events.normalizeStep("Choose Goal!"), "choose_goal")
        XCTAssertEqual(Events.normalizeStep("  allow - notifications  "), "allow_notifications")
        XCTAssertEqual(Events.normalizeStep("   "), "")
        XCTAssertEqual(Events.normalizeStep(String(repeating: "a", count: 60)).count, 40)
    }

    func testRevenue() {
        XCTAssertEqual(Events.coerceRevenue(["revenue": 9.99]), 9.99)
        XCTAssertEqual(Events.coerceRevenue(["price": "4.99"]), 4.99)
        XCTAssertEqual(Events.coerceRevenue(["price": 3]), 3)
        XCTAssertNil(Events.coerceRevenue(["price": "abc"]))
        XCTAssertNil(Events.coerceRevenue(["revenue": true]))
        XCTAssertNil(Events.coerceRevenue(nil))
    }

    func testMakeEvent() {
        let now = Date(timeIntervalSince1970: 1_789_725_858.673)
        let p = Events.make(name: "purchase", subtype: nil, params: ["revenue": 9.99, "currency": "eur", "product": "pro"], now: now)
        XCTAssertEqual(p["name"] as? String, "purchase")
        XCTAssertTrue(p["subtype"] is NSNull)
        XCTAssertEqual(p["revenue"] as? Double, 9.99)
        XCTAssertEqual(p["currency"] as? String, "EUR")
        XCTAssertEqual((p["params"] as? [String: Any])?["product"] as? String, "pro")
        XCTAssertEqual(p["ts"] as? String, "2026-09-18T10:04:18.673Z")

        let c = Events.make(name: "Boss-Defeated", subtype: nil, params: nil, now: now)
        XCTAssertEqual(c["name"] as? String, "custom")
        XCTAssertEqual(c["subtype"] as? String, "boss_defeated")
        XCTAssertNil(c["params"])

        let o = Events.make(name: "onboarding", subtype: "Choose Goal!", params: ["step": 2], now: now)
        XCTAssertEqual(o["subtype"] as? String, "choose_goal")
        XCTAssertTrue(JSONSerialization.isValidJSONObject(o))
    }

    func testZeroAdId() {
        XCTAssertTrue(isZeroAdId("00000000-0000-0000-0000-000000000000"))
        XCTAssertFalse(isZeroAdId("AAAAAAAA-1111-2222-3333-444444444444"))
        XCTAssertFalse(isZeroAdId(""))
    }
}
