// Scénarios de conformité S1…S9 (stamina-sdk-conformance/scenarios.md) — mêmes vérifications que le
// client React Native, exécutées sur le simulateur contre le serveur Node (scripts/test.sh le lance).
import XCTest
import UIKit
@testable import StaminaKit

final class ConformanceTests: XCTestCase {
    let server = ConformanceServer()
    let storage = InMemoryStorage()
    let signals = FakeSignals()
    let apiKey = "stam_ios_test_conformance"

    override func setUp() async throws {
        try await super.setUp()
        let reachable = await server.reachable()
        try XCTSkipUnless(reachable, "serveur de conformité injoignable — lance `node stamina-sdk-conformance/server.js`")
        await Stamina.destroy()
        await Stamina.clearData()
        storage.clear()
        signals.att = .notDetermined
        signals.adId = "AAAAAAAA-1111-2222-3333-444444444444"
        await Stamina.client._setStorage(storage)
        await Stamina.client._setSignals(signals)
        await Stamina.client._setNow { Date() }
        try await server.reset()
    }

    override func tearDown() async throws {
        await Stamina.destroy()
        try await super.tearDown()
    }

    // ── outils ─────────────────────────────────────────────────────────────

    private var t0 = Date()

    private func configure() {
        t0 = Date()
        Stamina.configure(StaminaConfig(apiKey: apiKey, endpoint: server.base.absoluteString))
    }

    private func active() async {
        await MainActor.run { NotificationCenter.default.post(name: UIApplication.didBecomeActiveNotification, object: nil) }
    }

    private func background() async {
        await MainActor.run { NotificationCenter.default.post(name: UIApplication.didEnterBackgroundNotification, object: nil) }
    }

    /// Horloge du SDK = instant du configure() + `seconds` (indépendant de la durée réelle des tests).
    private func timeTravel(_ seconds: TimeInterval) async {
        let at = t0.addingTimeInterval(seconds)
        await Stamina.client._setNow { at }
    }

    private func body(_ call: [String: Any]) -> [String: Any] { call["body"] as? [String: Any] ?? [:] }

    // ── scénarios ──────────────────────────────────────────────────────────

    func testS1_install() async throws {
        configure()
        await sleepMs(600)
        let installs = try await server.calls("/v1/sdk/install")
        XCTAssertEqual(installs.count, 1, "un install")
        let b = body(installs[0])
        let headers = installs[0]["headers"] as? [String: Any] ?? [:]
        XCTAssertEqual(headers["authorization"] as? String, "Bearer \(apiKey)")
        XCTAssertTrue((headers["user-agent"] as? String)?.hasPrefix("Stamina-iOS/\(staminaSDKVersion)") == true, "User-Agent")
        for field in ["device_user_id", "os_version", "device_model", "device_manufacturer", "locale", "timezone", "webview_user_agent", "screen_w", "screen_h"] {
            XCTAssertNotNil(b[field], field)
            XCTAssertFalse(b[field] is NSNull, "\(field) non nul")
        }
        let extras = b["extras"] as? [String: Any] ?? [:]
        XCTAssertEqual(extras["sdk_platform"] as? String, "ios")
        XCTAssertEqual(extras["sdk_version"] as? String, staminaSDKVersion)
        XCTAssertEqual(extras["app_version"] as? String, "1.0.0")
        XCTAssertEqual(extras["att_status"] as? String, "not_determined")
        XCTAssertEqual(b["idfv"] as? String, "IDFV-CONFORMANCE")
        XCTAssertEqual(b["adservices_token"] as? String, "ADSERVICES-TOKEN")
        XCTAssertTrue(b["idfa"] is NSNull, "pas d'IDFA avant ATT")
    }

    func testS2_events() async throws {
        configure()
        await sleepMs(300)
        Stamina.sendEvent("purchase", params: ["revenue": 9.99, "currency": "eur", "product": "pro"])
        Stamina.sendEvent("Level-Complete", params: ["level": 5])
        Stamina.sendEvent("Boss-Defeated", params: ["boss": "x"])
        Stamina.sendEvent("subscribe", params: ["price": "4.99", "currency": "USD"])
        Stamina.trackOnboardingStep("Choose Goal!", step: 2, params: ["extra": 1])
        Stamina.trackOnboardingStep("   ")
        await sleepMs(800)
        let evs = try await server.events().filter { $0["name"] as? String != "session_start" }
        XCTAssertEqual(evs.count, 5, "5 événements (reçu \(evs.count))")
        guard evs.count == 5 else { return }
        let (p, lc, bd, sub, ob) = (evs[0], evs[1], evs[2], evs[3], evs[4])
        XCTAssertEqual(p["name"] as? String, "purchase")
        XCTAssertTrue(p["subtype"] is NSNull)
        XCTAssertEqual(p["revenue"] as? Double, 9.99)
        XCTAssertEqual(p["currency"] as? String, "EUR")
        XCTAssertEqual((p["params"] as? [String: Any])?["product"] as? String, "pro")
        XCTAssertNil((p["params"] as? [String: Any])?["revenue"])
        XCTAssertEqual(lc["name"] as? String, "level_complete")
        XCTAssertTrue(lc["subtype"] is NSNull)
        XCTAssertEqual(bd["name"] as? String, "custom")
        XCTAssertEqual(bd["subtype"] as? String, "boss_defeated")
        XCTAssertEqual(sub["name"] as? String, "subscribe")
        XCTAssertEqual(sub["revenue"] as? Double, 4.99)
        XCTAssertEqual(sub["currency"] as? String, "USD")
        XCTAssertEqual(ob["name"] as? String, "onboarding")
        XCTAssertEqual(ob["subtype"] as? String, "choose_goal")
        XCTAssertEqual((ob["params"] as? [String: Any])?["step"] as? Int, 2)
        XCTAssertEqual((ob["params"] as? [String: Any])?["extra"] as? Int, 1)
        for e in evs {
            XCTAssertTrue(((e["id"] as? String)?.count ?? 0) > 10, "id local")
            XCTAssertTrue((e["ts"] as? String)?.hasSuffix("Z") == true, "ts ISO")
        }
    }

    func testS3_sessions() async throws {
        configure()
        await sleepMs(400)
        var evs = try await server.events()
        let starts = evs.filter { $0["name"] as? String == "session_start" }
        XCTAssertEqual(starts.count, 1, "session_start n°1")
        let sid = (starts.first?["params"] as? [String: Any])?["session_id"] as? String
        XCTAssertEqual((starts.first?["params"] as? [String: Any])?["session_number"] as? Int, 1)

        await timeTravel(65)
        await background()
        await sleepMs(400)
        evs = try await server.events()
        let end = evs.first { $0["name"] as? String == "session_end" }
        let endParams = end?["params"] as? [String: Any]
        XCTAssertEqual(endParams?["session_id"] as? String, sid)
        XCTAssertEqual(endParams?["duration_s"] as? Int, 65, "session_end 65 s")

        await timeTravel(10 * 60)
        await active()
        await sleepMs(400)
        evs = try await server.events()
        XCTAssertEqual(evs.filter { $0["name"] as? String == "session_start" }.count, 1, "pas de nouvelle session < 30 min")

        await timeTravel(41 * 60)
        await background()
        await sleepMs(300)
        await timeTravel(72 * 60)
        await active()
        await sleepMs(400)
        evs = try await server.events()
        let starts2 = evs.filter { $0["name"] as? String == "session_start" }
        XCTAssertEqual(starts2.count, 2, "session_start n°2 après 30 min")
        XCTAssertEqual((starts2.last?["params"] as? [String: Any])?["session_number"] as? Int, 2)
        XCTAssertNotEqual((starts2.last?["params"] as? [String: Any])?["session_id"] as? String, sid)
    }

    func testS4_killSwitch() async throws {
        configure()
        await sleepMs(300)
        try await server.mode("auth_reject_json")
        Stamina.sendEvent("login")
        await sleepMs(500)
        let disabled = await Stamina.isDisabled
        XCTAssertTrue(disabled, "désactivé")
        XCTAssertEqual(storage.get(Keys.disabled), "1", "persisté")
        let before = try await server.calls().count
        Stamina.sendEvent("login")
        await Stamina.flush()
        await sleepMs(300)
        let after = try await server.calls().count
        XCTAssertEqual(after, before, "plus aucun appel")
        try await server.mode("ok")
        await Stamina.clearData()
        let reenabled = await Stamina.isDisabled
        XCTAssertFalse(reenabled, "réactivé")
    }

    func testS5_forbiddenHtml() async throws {
        configure()
        await sleepMs(300)
        try await server.mode("forbidden_html")
        Stamina.sendEvent("login")
        await sleepMs(500)
        let disabled = await Stamina.isDisabled
        XCTAssertFalse(disabled, "pas désactivé")
        let n = try await server.calls("/v1/sdk/events").count
        Stamina.sendEvent("login")
        await sleepMs(400)
        let afterBackoff = try await server.calls("/v1/sdk/events").count
        XCTAssertEqual(afterBackoff, n, "backoff : pas de nouvel envoi immédiat")
        try await server.mode("ok")
        await Stamina.flush()
        await sleepMs(300)
        let last = try await server.calls("/v1/sdk/events").last
        let names = (body(last ?? [:])["events"] as? [[String: Any]])?.compactMap { $0["name"] as? String } ?? []
        XCTAssertTrue(names.contains("login"), "file conservée puis envoyée")
    }

    func testS6_attAdvertisingId() async throws {
        configure()
        await sleepMs(500)
        await active()
        await sleepMs(300)
        let none = try await server.calls("/v1/sdk/identify").count
        XCTAssertEqual(none, 0, "rien avant consentement")

        signals.att = .authorized
        await active()
        await sleepMs(500)
        var ids = try await server.calls("/v1/sdk/identify")
        XCTAssertEqual(ids.count, 1, "un identify")
        XCTAssertEqual(body(ids.first ?? [:])["advertising_id"] as? String, signals.adId)

        await background()
        await active()
        await sleepMs(300)
        let still = try await server.calls("/v1/sdk/identify").count
        XCTAssertEqual(still, 1, "pas de renvoi")

        signals.adId = "BBBBBBBB-1111-2222-3333-444444444444"
        await active()
        await sleepMs(500)
        ids = try await server.calls("/v1/sdk/identify")
        XCTAssertEqual(ids.count, 2, "renvoi si l'identifiant change")
        XCTAssertEqual(body(ids.last ?? [:])["advertising_id"] as? String, signals.adId)
    }

    func testS7_installOnce() async throws {
        configure()
        await sleepMs(500)
        await Stamina.destroy()
        configure()
        await sleepMs(500)
        let installs = try await server.calls("/v1/sdk/install").count
        XCTAssertEqual(installs, 1, "un seul install")
    }

    func testS8_corruptedQueue() async throws {
        storage.set(Keys.queue, "not-json{")
        configure()
        await sleepMs(300)
        Stamina.sendEvent("login")
        await sleepMs(500)
        let names = try await server.events().compactMap { $0["name"] as? String }
        XCTAssertTrue(names.contains("login"), "événement envoyé après réinitialisation")
    }

    func testS9_batches() async throws {
        configure()
        await sleepMs(400)
        try await server.reset()
        try await server.mode("offline")
        for i in 0..<250 { Stamina.sendEvent("view_content", params: ["i": i]) }
        await sleepMs(600)
        try await server.mode("ok")
        await Stamina.flush()
        await sleepMs(300)
        let sizes = try await server.calls("/v1/sdk/events").map { (body($0)["events"] as? [[String: Any]])?.count ?? 0 }
        XCTAssertEqual(sizes, [100, 100, 50], "lots \(sizes)")
    }
}
