// HTTP : repli d'adresses, timeout 15 s, en-têtes. Référence : docs/13-SPEC-SDK.md §2.
import Foundation

struct HTTPResponse {
    let status: Int
    let contentType: String
    let data: Data

    var ok: Bool { (200..<300).contains(status) }
    var json: [String: Any]? { JSON.decode(data) as? [String: Any] }
}

enum TransportError: Error {
    case http(Int)
    case unreachable
}

/// Une adresse injoignable (erreur réseau) est écartée pour la durée du process et la suivante
/// devient courante ; une erreur HTTP ne bascule pas. Utilisé exclusivement depuis l'actor client.
final class Transport {
    static let defaultEndpoints = [
        "https://api.getstamina.io", // domaine principal
        "https://stamina-tracker.stamina.workers.dev", // repli permanent, jamais désactivé
    ]

    private let session: URLSession
    private let apiKey: String
    private let userAgent: String
    private let endpoints: [String]
    private var index = 0

    init(apiKey: String, endpoints: [String], userAgent: String) {
        self.apiKey = apiKey
        self.endpoints = endpoints
        self.userAgent = userAgent
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 15
        cfg.timeoutIntervalForResource = 15
        cfg.waitsForConnectivity = false
        session = URLSession(configuration: cfg)
    }

    func request(_ path: String, method: String, body: [String: Any]? = nil) async throws -> HTTPResponse {
        var lastError: Error?
        for tries in 0..<endpoints.count {
            let i = (index + tries) % endpoints.count
            guard let url = URL(string: endpoints[i] + path) else { continue }
            var req = URLRequest(url: url)
            req.httpMethod = method
            req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
            if let body {
                guard let data = JSON.encode(body) else { throw TransportError.http(0) }
                req.httpBody = data
            }
            do {
                let (data, response) = try await session.data(for: req)
                index = i
                let http = response as? HTTPURLResponse
                return HTTPResponse(
                    status: http?.statusCode ?? 0,
                    contentType: (http?.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased(),
                    data: data
                )
            } catch {
                lastError = error
            }
        }
        throw lastError ?? TransportError.unreachable
    }
}
