// STAMINA — SDK d'attribution iOS. Façade publique.
//
//   Stamina.configure(apiKey: "stam_ios_live_…")                 // AppDelegate ou App.init, non bloquant
//   Stamina.sendEvent("purchase", params: ["revenue": 9.99, "currency": "EUR"])
//   Stamina.trackOnboardingStep("choose_goal", step: 2)
//   await Stamina.linkRevenueCat(bridge)                          // identité partagée RevenueCat
//
// Rien d'autre à brancher : sessions, install, jeton AdServices, IDFA après le consentement ATT
// (quel que soit le code qui affiche le prompt), file hors ligne, kill-switch — tout est automatique.
//
// Ordre garanti : les appels non bloquants (configure, sendEvent, …) passent par un bus FIFO
// consommé par l'actor client, pas par des Task lâchés en parallèle.
import Foundation

public struct StaminaConfig {
    public var apiKey: String
    /// Force une adresse unique (désactive le repli). Tests.
    public var endpoint: String?
    /// Forcer l'identifiant (sinon UUID généré et persisté au 1er lancement). À partager avec RevenueCat.
    public var deviceUserId: String?
    /// Identifiant interne (opaque/hashé, jamais de PII brute). Retry automatique.
    public var customerUserId: String?
    /// Sessions automatiques (session_start / session_end, timeout 30 min). Défaut true.
    public var autoTrackSessions: Bool
    /// IDFA si l'app le lit déjà elle-même (sinon collecté par le SDK ; valeurs tout-à-zéro ignorées).
    public var advertisingId: String?
    /// Jeton AdServices si l'app le lit déjà elle-même (sinon collecté par le SDK).
    public var adservicesToken: String?
    /// User-agent WebView si l'app le lit déjà elle-même (sinon collecté par le SDK).
    public var webviewUserAgent: String?

    public init(
        apiKey: String,
        endpoint: String? = nil,
        deviceUserId: String? = nil,
        customerUserId: String? = nil,
        autoTrackSessions: Bool = true,
        advertisingId: String? = nil,
        adservicesToken: String? = nil,
        webviewUserAgent: String? = nil
    ) {
        self.apiKey = apiKey
        self.endpoint = endpoint
        self.deviceUserId = deviceUserId
        self.customerUserId = customerUserId
        self.autoTrackSessions = autoTrackSessions
        self.advertisingId = advertisingId
        self.adservicesToken = adservicesToken
        self.webviewUserAgent = webviewUserAgent
    }
}

public struct AttributionResult: Sendable {
    /// `resolved` | `pending` | `unknown_device`
    public let status: String
    public let isAttributed: Bool?
    public let source: String?
    public let label: String?
    /// `deterministic` | `probabilistic` | `organic`
    public let method: String?
    public let matchedAt: String?

    init?(_ dict: [String: Any]) {
        guard let status = dict["status"] as? String else { return nil }
        self.status = status
        isAttributed = dict["isAttributed"] as? Bool
        source = dict["source"] as? String
        label = dict["label"] as? String
        method = dict["method"] as? String
        matchedAt = dict["matchedAt"] as? String
    }
}

/// Pont vers RevenueCat : le SDK n'importe pas RevenueCat, l'app implémente ces 4 méthodes autour de
/// `Purchases.shared` (async/await natif de RevenueCat 4+).
public protocol StaminaPurchasesBridge {
    func isAnonymous() async throws -> Bool
    func appUserID() async throws -> String
    func logIn(_ appUserID: String) async throws
    func setAttributes(_ attributes: [String: String]) async throws
}

public struct LinkRevenueCatResult: Sendable {
    public let deviceUserId: String
    public let appUserId: String?
    /// `login` (RC anonyme aliasé) · `same` (déjà le même id) · `customer` (id de l'app retenu) · `attribute` (attribut seul)
    public let method: String
    public let attributeSet: Bool
}

public enum Stamina {
    static var client = StaminaClient()
    static var bus = CommandBus(client: client)

    // ── configuration ──────────────────────────────────────────────────────

    /// À appeler le plus tôt possible. Non bloquant : l'install part en arrière-plan.
    public static func configure(_ config: StaminaConfig) {
        bus.post { await $0.configure(config) }
    }

    public static func configure(apiKey: String, deviceUserId: String? = nil, customerUserId: String? = nil, autoTrackSessions: Bool = true) {
        configure(StaminaConfig(apiKey: apiKey, deviceUserId: deviceUserId, customerUserId: customerUserId, autoTrackSessions: autoTrackSessions))
    }

    /// L'id anonyme à partager avec RevenueCat (`Purchases.logIn`).
    public static func deviceUserId() async -> String {
        await bus.run { await $0.currentDeviceUserId() }
    }

    // ── événements ─────────────────────────────────────────────────────────

    /// Taxonomie standard normalisée, le reste part en `custom`. `params["revenue"]` (ou `price`) +
    /// `params["currency"]` pour le revenu.
    public static func sendEvent(_ name: String, subtype: String? = nil, params: [String: Any]? = nil) {
        bus.post { await $0.sendEvent(name, subtype: subtype, params: params) }
    }

    /// Étape d'onboarding typée. Nom STABLE en snake_case ; `step` = indice de secours (1 = première).
    /// Réservés : `completed`, `skipped`.
    public static func trackOnboardingStep(_ stepName: String, step: Int? = nil, params: [String: Any]? = nil) {
        bus.post { await $0.trackOnboardingStep(stepName, step: step, params: params) }
    }

    /// Lie ton id utilisateur interne (opaque/hashé) à l'install. Retry auto au prochain configure().
    public static func setCustomerUserId(_ customerUserId: String) {
        bus.post { await $0.setCustomerUserId(customerUserId) }
    }

    // ── RevenueCat ─────────────────────────────────────────────────────────

    /// Lie l'identité STAMINA à RevenueCat, quel que soit l'état de l'app. Ne lève jamais.
    /// À appeler APRÈS `Purchases.configure`, et à rappeler après chaque `logIn` / `logOut`.
    public static func linkRevenueCat(_ purchases: StaminaPurchasesBridge, logIn: Bool = true) async -> LinkRevenueCatResult {
        let deviceUserId = await deviceUserId()
        var method = "attribute"
        var appUserId: String?
        do {
            let anonymous = try await purchases.isAnonymous()
            if anonymous && logIn {
                try await purchases.logIn(deviceUserId)
                method = "login"
            }
            appUserId = try await purchases.appUserID()
            if appUserId == deviceUserId {
                if method != "login" { method = "same" }
            } else if let appUserId, !appUserId.isEmpty, !anonymous {
                method = "customer"
                setCustomerUserId(appUserId)
            }
        } catch {
            Log.warn("linkRevenueCat: identité RevenueCat indisponible (\(error))")
        }
        var attributeSet = false
        do {
            try await purchases.setAttributes(["stamina_device_user_id": deviceUserId])
            attributeSet = true
        } catch {
            Log.warn("linkRevenueCat: setAttributes a échoué (\(error))")
        }
        return LinkRevenueCatResult(deviceUserId: deviceUserId, appUserId: appUserId, method: method, attributeSet: attributeSet)
    }

    // ── ATT / identifiants ─────────────────────────────────────────────────

    /// Facultatif : prompt ATT système (l'IDFA est de toute façon synchronisé seul après le consentement).
    /// Jamais sur le tout premier écran. `true` si autorisé.
    public static func requestTrackingAuthorization() async -> Bool {
        await client.requestTrackingAuthorization()
    }

    public static var trackingStatus: TrackingStatus {
        get async { await client.trackingStatus() }
    }

    /// Facultatif : force la relecture immédiate de l'IDFA (déjà faite au retour au premier plan).
    @discardableResult
    public static func syncAdvertisingId() async -> String? {
        await bus.run { await $0.maybeSyncAdvertisingId() }
    }

    // ── attribution / diagnostic ───────────────────────────────────────────

    /// Attribution résolue de cet install (cache local, sinon fetch).
    public static func attribution() async -> AttributionResult? { await client.attribution() }

    /// Force un refetch de l'attribution côté serveur.
    public static func refreshAttribution() async -> AttributionResult? { await client.refreshAttribution() }

    /// Vérification de connectivité (fonctionne même SDK désactivé).
    public static func sendTestEvent() async -> (success: Bool, message: String) { await client.sendTestEvent() }

    /// Diagnostic : signaux collectés.
    public static func deviceInfo() async -> [String: Any] { await client.deviceInfo() }

    /// Vide la file immédiatement (remet le backoff à zéro).
    public static func flush() async { await bus.run { await $0.flush() } }

    /// Reset complet (kill-switch et device id inclus).
    public static func clearData() async { await bus.run { await $0.clearData() } }

    public static var isInitialized: Bool { get async { await client.configured } }

    /// true si la clé API a été rejetée (401/403) — plus rien ne part jusqu'à clearData().
    public static var isDisabled: Bool { get async { await client.disabled } }

    /// Coupe timers et observateurs (tests).
    public static func destroy() async { await bus.run { await $0.destroy() } }
}

/// FIFO strict des commandes : `yield` est synchrone et ordonné, un seul consommateur.
final class CommandBus {
    typealias Command = (StaminaClient) async -> Void
    private let continuation: AsyncStream<Command>.Continuation
    private let consumer: Task<Void, Never>

    init(client: StaminaClient) {
        var cont: AsyncStream<Command>.Continuation!
        let stream = AsyncStream<Command> { cont = $0 }
        continuation = cont
        consumer = Task.detached(priority: .utility) {
            for await command in stream { await command(client) }
        }
    }

    func post(_ command: @escaping Command) {
        continuation.yield(command)
    }

    func run<T>(_ body: @escaping (StaminaClient) async -> T) async -> T {
        await withCheckedContinuation { (c: CheckedContinuation<T, Never>) in
            post { client in c.resume(returning: await body(client)) }
        }
    }

    deinit {
        continuation.finish()
        consumer.cancel()
    }
}
