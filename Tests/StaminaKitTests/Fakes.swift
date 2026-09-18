import Foundation
@testable import StaminaKit

/// Signaux pilotables : statut ATT et IDFA changent en cours de test, le reste imite un iPhone.
final class FakeSignals: SignalsProviding {
    var att: TrackingStatus = .notDetermined
    var adId: String? = "AAAAAAAA-1111-2222-3333-444444444444"
    var adServicesToken: String? = "ADSERVICES-TOKEN"

    func collect() async -> CollectedSignals {
        var s = CollectedSignals()
        s.osVersion = "26.5"
        s.deviceModel = "iPhone18,1"
        s.screenW = 402; s.screenH = 874; s.screenScale = 3
        s.colorScheme = "light"
        s.locale = "fr-FR"
        s.timezone = "Europe/Paris"
        s.appVersion = "1.0.0"; s.appBuild = "1"; s.bundleId = "io.getstamina.conformance"
        s.webViewUserAgent = "Mozilla/5.0 (conformance WebView)"
        s.vendorId = "IDFV-CONFORMANCE"
        s.attStatus = att
        s.advertisingId = await advertisingId()
        s.adServicesToken = adServicesToken
        return s
    }

    func trackingStatus() -> TrackingStatus { att }
    func requestTrackingAuthorization() async -> TrackingStatus { att }
    func advertisingId() async -> String? { att == .authorized ? adId : nil }
}

/// Client HTTP du serveur de conformité (../../stamina-sdk-conformance/server.js).
struct ConformanceServer {
    let base = URL(string: ProcessInfo.processInfo.environment["STAMINA_CONFORMANCE_URL"] ?? "http://127.0.0.1:4999")!

    func reachable() async -> Bool {
        (try? await get("/__health")) != nil
    }

    @discardableResult
    func reset() async throws -> Any { try await post("/__reset", [:]) }

    @discardableResult
    func mode(_ mode: String) async throws -> Any { try await post("/__mode", ["mode": mode]) }

    func calls(_ path: String? = nil) async throws -> [[String: Any]] {
        let q = path.map { "?path=\($0)" } ?? ""
        return (try await get("/__calls\(q)") as? [[String: Any]]) ?? []
    }

    /// Événements de tous les lots, dans l'ordre d'envoi.
    func events() async throws -> [[String: Any]] {
        try await calls("/v1/sdk/events").flatMap { ($0["body"] as? [String: Any])?["events"] as? [[String: Any]] ?? [] }
    }

    private func get(_ path: String) async throws -> Any {
        let (data, _) = try await URLSession.shared.data(from: base.appendingPathComponent(path).absoluteURL.withQuery(path))
        return try JSONSerialization.jsonObject(with: data)
    }

    private func post(_ path: String, _ body: [String: Any]) async throws -> Any {
        var req = URLRequest(url: base.appendingPathComponent(path))
        req.httpMethod = "POST"
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, _) = try await URLSession.shared.data(for: req)
        return try JSONSerialization.jsonObject(with: data)
    }
}

private extension URL {
    /// appendingPathComponent encode le `?` : on reconstruit l'URL avec la query telle quelle.
    func withQuery(_ pathWithQuery: String) -> URL {
        guard pathWithQuery.contains("?") else { return self }
        let base = self.absoluteString.components(separatedBy: "/__").first ?? self.absoluteString
        return URL(string: base + pathWithQuery)!
    }
}

func sleepMs(_ ms: UInt64) async { try? await Task.sleep(nanoseconds: ms * 1_000_000) }
