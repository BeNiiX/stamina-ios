// Cœur du SDK : identité, install, file d'événements, sessions, synchro IDFA, attribution.
// Miroir du cœur TypeScript (stamina-sdk/src/index.ts) — docs/13-SPEC-SDK.md fait foi.
//
// Concurrence : tout l'état vit dans cet actor. Le stockage et la file sont SYNCHRONES (UserDefaults),
// donc les sections critiques (sessions, enqueue) n'ont aucun point de suspension et ne s'entrelacent
// jamais. Seul le réseau est asynchrone ; le drapeau `flushing` empêche deux envois simultanés.
import Foundation

public let staminaSDKVersion = "1.0.0"

actor StaminaClient {
    static let sessionTimeout: TimeInterval = 30 * 60
    static let flushInterval: UInt64 = 20_000_000_000
    static let installRetryDelays: [UInt64] = [30, 120, 600] // secondes
    static let maxQueue = 500
    static let batchSize = 100

    private var storage: StaminaStorage
    private var signals: SignalsProviding
    private var transport: Transport?
    private var lifecycle: LifecycleObserver?
    private(set) var config: StaminaConfig?
    var now: () -> Date = { Date() }

    private(set) var configured = false
    private(set) var disabled = false
    private var deviceUserId: String?
    private var sessionsEnabled = true

    private var flushing = false
    private var flushFailCount = 0
    private var nextFlushAllowedAt: Date = .distantPast
    private var flushTimer: Task<Void, Never>?
    private var installRetry: Task<Void, Never>?
    private var adIdSyncing = false

    init(storage: StaminaStorage = UserDefaultsStorage(), signals: SignalsProviding = DeviceSignals()) {
        self.storage = storage
        self.signals = signals
    }

    // ── hooks de test ──────────────────────────────────────────────────────

    func _setStorage(_ s: StaminaStorage) { storage = s }
    func _setSignals(_ s: SignalsProviding) { signals = s }
    func _setNow(_ f: @escaping () -> Date) { now = f }

    // ── configuration ──────────────────────────────────────────────────────

    func configure(_ config: StaminaConfig) {
        let apiKey = config.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !apiKey.isEmpty else {
            // Pas de clé : on ne plante JAMAIS l'app hôte, on se désactive silencieusement.
            Log.warn("configure: apiKey manquante — SDK inactif.")
            return
        }
        // configure() rappelé : on repart propre, sans doubler observateurs ni timers
        lifecycle?.stop()
        lifecycle = nil
        flushTimer?.cancel()
        flushTimer = nil
        installRetry?.cancel()
        installRetry = nil

        self.config = config
        let endpoints = config.endpoint.map { [$0.hasSuffix("/") ? String($0.dropLast()) : $0] } ?? Transport.defaultEndpoints
        transport = Transport(apiKey: apiKey, endpoints: endpoints, userAgent: StaminaClient.userAgent())
        disabled = storage.get(Keys.disabled) == "1"

        var id = config.deviceUserId ?? storage.get(Keys.deviceId) ?? ""
        if id.isEmpty { id = UUID().uuidString.lowercased() }
        storage.set(Keys.deviceId, id)
        deviceUserId = id
        sessionsEnabled = config.autoTrackSessions
        configured = true

        // install en arrière-plan avec retry/backoff
        Task { await self.registerInstall(attempt: 0) }

        // Le listener sert aux sessions ET à la détection du consentement ATT.
        lifecycle = LifecycleObserver(
            onActive: { [weak self] in Task { await self?.onActive() } },
            onBackground: { [weak self] in Task { await self?.onBackground() } }
        )
        if sessionsEnabled { startSessionIfNeeded() }
        Task { await self.maybeSyncAdvertisingId() }

        // identité client en attente (échec précédent) → retry
        if let c = config.customerUserId, !c.isEmpty {
            Task { await self.setCustomerUserId(c) }
        } else if let pending = storage.get(Keys.pendingCustomerId), !pending.isEmpty {
            Task { await self.setCustomerUserId(pending) }
        }
        // IDFA obtenu après l'install mais non transmis (réseau) → retry
        if let pendingAd = storage.get(Keys.pendingAdvertisingId), !pendingAd.isEmpty {
            Task { await self.sendAdvertisingId(pendingAd) }
        }

        Task { await self.flushQueue() }
        ensureFlushTimer()
    }

    func currentDeviceUserId() -> String {
        if let deviceUserId { return deviceUserId }
        var id = storage.get(Keys.deviceId) ?? ""
        if id.isEmpty {
            id = UUID().uuidString.lowercased()
            storage.set(Keys.deviceId, id)
        }
        deviceUserId = id
        return id
    }

    static func userAgent() -> String {
        let bundle = Bundle.main.bundleIdentifier ?? "unknown"
        let v = ProcessInfo.processInfo.operatingSystemVersion
        let os = v.patchVersion > 0 ? "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)" : "\(v.majorVersion).\(v.minorVersion)"
        return "Stamina-iOS/\(staminaSDKVersion) (\(bundle); iOS \(os))"
    }

    // ── événements ─────────────────────────────────────────────────────────

    func sendEvent(_ name: String, subtype: String?, params: [String: Any]?) {
        guard !disabled else { return }
        enqueue(Events.make(name: name, subtype: subtype, params: params, now: now()))
        Task { await self.flushQueue() }
        ensureFlushTimer()
    }

    func trackOnboardingStep(_ stepName: String, step: Int?, params: [String: Any]?) {
        let name = Events.normalizeStep(stepName)
        guard !name.isEmpty else {
            Log.warn("trackOnboardingStep: \"\(stepName)\" ne contient aucun caractère valide — ignoré.")
            return
        }
        if name != stepName {
            Log.warn("trackOnboardingStep: \"\(stepName)\" normalisé en \"\(name)\" — utilise directement le snake_case.")
        }
        var extra = params ?? [:]
        extra.removeValue(forKey: "step")
        if let step { extra["step"] = step }
        sendEvent("onboarding", subtype: name, params: extra)
    }

    // ── file ───────────────────────────────────────────────────────────────

    /// Lecture tolérante : une file corrompue est remise à zéro, jamais une exception.
    private func readQueue() -> [[String: Any]] {
        guard let raw = storage.get(Keys.queue), let data = raw.data(using: .utf8) else { return [] }
        if let arr = JSON.decode(data) as? [[String: Any]] {
            return arr.filter { $0["name"] is String }
        }
        Log.warn("file d'événements corrompue — réinitialisée.")
        storage.remove(Keys.queue)
        return []
    }

    private func writeQueue(_ queue: [[String: Any]]) {
        if queue.isEmpty {
            storage.remove(Keys.queue)
            return
        }
        let trimmed = Array(queue.suffix(StaminaClient.maxQueue))
        if let data = JSON.encode(trimmed), let s = String(data: data, encoding: .utf8) {
            storage.set(Keys.queue, s)
        }
    }

    private func enqueue(_ event: [String: Any]) {
        var q = readQueue()
        q.append(event)
        writeQueue(q)
    }

    private func ensureFlushTimer() {
        guard flushTimer == nil, configured else { return }
        flushTimer = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: StaminaClient.flushInterval)
                guard let self, !Task.isCancelled else { return }
                if await !self.flushTick() { return }
            }
        }
    }

    /// false = file vide, le timer s'arrête (il sera réarmé au prochain sendEvent).
    private func flushTick() async -> Bool {
        if readQueue().isEmpty {
            flushTimer = nil
            return false
        }
        await flushQueue()
        return true
    }

    func flushQueue() async {
        guard configured, !flushing, !disabled, let transport else { return }
        guard now() >= nextFlushAllowedAt else { return } // backoff en cours
        flushing = true
        defer { flushing = false }
        while true {
            let queue = readQueue()
            if queue.isEmpty { return }
            let batch = Array(queue.prefix(StaminaClient.batchSize))
            do {
                let res = try await transport.request("/v1/sdk/events", method: "POST", body: [
                    "device_user_id": currentDeviceUserId(),
                    "events": batch,
                ])
                if res.ok {
                    flushFailCount = 0
                    nextFlushAllowedAt = .distantPast
                    let sent = Set(batch.compactMap { $0["id"] as? String })
                    // ne retire QUE les envoyés : d'autres ont pu arriver pendant l'envoi → tour suivant
                    writeQueue(readQueue().filter { !sent.contains(($0["id"] as? String) ?? "") })
                    continue
                }
                if !handleAuthFailure(res) { applyFlushBackoff() }
                return
            } catch {
                applyFlushBackoff() // offline : file persistée
                return
            }
        }
    }

    private func applyFlushBackoff() {
        flushFailCount += 1
        let backoff = min(30.0 * pow(2.0, Double(flushFailCount - 1)), 300.0) // 30 s → 5 min max
        nextFlushAllowedAt = now().addingTimeInterval(backoff)
    }

    func flush() async {
        flushFailCount = 0
        nextFlushAllowedAt = .distantPast
        await flushQueue()
    }

    /// Clé rejetée par NOTRE API (401/403 JSON `{ error }`) → kill-switch persistant. Un 403 HTML
    /// (challenge Cloudflare, proxy, portail captif) est une panne transitoire → backoff.
    private func handleAuthFailure(_ res: HTTPResponse) -> Bool {
        guard res.status == 401 || res.status == 403,
              res.contentType.contains("application/json"),
              let json = res.json, json["error"] is String
        else { return false }
        disabled = true
        storage.set(Keys.disabled, "1")
        Log.warn("clé API rejetée par le serveur — SDK désactivé jusqu'à clearData().")
        return true
    }

    // ── install ────────────────────────────────────────────────────────────

    private func registerInstall(attempt: Int) async {
        guard configured, !disabled, let config, let transport else { return }
        if storage.get(Keys.installSent) == "1" { return }
        let s = await signals.collect()
        let adId: String? = {
            if let given = config.advertisingId, !given.isEmpty, !isZeroAdId(given) { return given }
            return s.advertisingId
        }()
        let webViewUA: Any = (config.webviewUserAgent ?? s.webViewUserAgent).map { $0 as Any } ?? NSNull()
        let adServicesToken: Any = (config.adservicesToken ?? s.adServicesToken).map { $0 as Any } ?? NSNull()
        var extras: [String: Any] = [
            "sdk_platform": config.sdkPlatform.isEmpty ? "ios" : config.sdkPlatform,
            "sdk_version": staminaSDKVersion,
            "att_status": s.attStatus.rawValue,
        ]
        extras["app_version"] = s.appVersion ?? NSNull()
        extras["app_build"] = s.appBuild ?? NSNull()
        let payload: [String: Any] = [
            "device_user_id": currentDeviceUserId(),
            "os_version": s.osVersion ?? NSNull(),
            "device_model": s.deviceModel ?? NSNull(),
            "device_manufacturer": s.manufacturer ?? NSNull(),
            "screen_w": s.screenW ?? NSNull(),
            "screen_h": s.screenH ?? NSNull(),
            "screen_scale": s.screenScale ?? NSNull(),
            "color_scheme": s.colorScheme ?? NSNull(),
            "locale": s.locale ?? NSNull(),
            "timezone": s.timezone ?? NSNull(),
            "webview_user_agent": webViewUA,
            "install_referrer": NSNull(),
            "idfv": s.vendorId ?? NSNull(),
            "adservices_token": adServicesToken,
            "idfa": adId ?? NSNull(),
            "gaid": NSNull(),
            "customer_user_id": config.customerUserId ?? NSNull(),
            "extras": extras,
        ]
        do {
            let res = try await transport.request("/v1/sdk/install", method: "POST", body: payload)
            if res.ok {
                storage.set(Keys.installSent, "1")
                if let adId { storage.set(Keys.advertisingIdSent, adId) } else { Task { await self.maybeSyncAdvertisingId() } }
                return
            }
            if handleAuthFailure(res) { return }
            throw TransportError.http(res.status)
        } catch {
            guard attempt < StaminaClient.installRetryDelays.count else { return } // retenté au prochain configure()
            let delay = StaminaClient.installRetryDelays[attempt]
            installRetry = Task {
                try? await Task.sleep(nanoseconds: delay * 1_000_000_000)
                guard !Task.isCancelled else { return }
                await self.registerInstall(attempt: attempt + 1)
            }
        }
    }

    // ── sessions ───────────────────────────────────────────────────────────

    func onActive() {
        if sessionsEnabled { startSessionIfNeeded() }
        Task { await self.maybeSyncAdvertisingId() }
    }

    func onBackground() {
        if sessionsEnabled { endSession() }
    }

    private var nowMs: Int64 { Int64((now().timeIntervalSince1970 * 1000).rounded()) }

    private func startSessionIfNeeded() {
        guard !disabled else { return }
        let t = nowMs
        let last = Int64(storage.get(Keys.lastActivity) ?? "") ?? 0
        if let current = storage.get(Keys.sessionId), !current.isEmpty,
           Double(t - last) / 1000 < StaminaClient.sessionTimeout {
            storage.set(Keys.lastActivity, String(t))
            return
        }
        let number = (Int(storage.get(Keys.sessionCount) ?? "") ?? 0) + 1
        let sessionId = UUID().uuidString.lowercased()
        storage.set(Keys.sessionCount, String(number))
        storage.set(Keys.sessionId, sessionId)
        storage.set(Keys.sessionStartedAt, String(t))
        storage.set(Keys.lastActivity, String(t))
        sendEvent("session_start", subtype: nil, params: ["session_id": sessionId, "session_number": number])
    }

    private func endSession() {
        guard !disabled, let sessionId = storage.get(Keys.sessionId), !sessionId.isEmpty else { return }
        let t = nowMs
        let startedAt = Int64(storage.get(Keys.sessionStartedAt) ?? "") ?? t
        let number = Int(storage.get(Keys.sessionCount) ?? "") ?? 0
        storage.set(Keys.lastActivity, String(t))
        let duration = max(0, Int((Double(t - startedAt) / 1000).rounded()))
        sendEvent("session_end", subtype: nil, params: ["session_id": sessionId, "session_number": number, "duration_s": duration])
    }

    // ── identifiants ───────────────────────────────────────────────────────

    /// Quel que soit le code qui affiche le prompt ATT, on relit le statut au premier plan et on
    /// rattache l'IDFA à l'install — une fois, puis seulement si l'identifiant change.
    @discardableResult
    func maybeSyncAdvertisingId() async -> String? {
        guard configured, !disabled, !adIdSyncing, config?.advertisingId == nil else { return nil }
        guard signals.trackingStatus() == .authorized else { return nil }
        adIdSyncing = true
        defer { adIdSyncing = false }
        guard storage.get(Keys.installSent) == "1" else { return nil }
        guard let id = await signals.advertisingId() else { return nil }
        if storage.get(Keys.advertisingIdSent) == id { return id }
        await sendAdvertisingId(id)
        return id
    }

    private func sendAdvertisingId(_ id: String) async {
        guard !id.isEmpty, !isZeroAdId(id), !disabled, let transport else { return }
        do {
            let res = try await transport.request("/v1/sdk/identify", method: "POST", body: [
                "device_user_id": currentDeviceUserId(), "advertising_id": id,
            ])
            if res.ok {
                storage.set(Keys.advertisingIdSent, id)
                storage.remove(Keys.pendingAdvertisingId)
            } else {
                storage.set(Keys.pendingAdvertisingId, id)
            }
        } catch {
            storage.set(Keys.pendingAdvertisingId, id)
        }
    }

    func requestTrackingAuthorization() async -> Bool {
        let status = await signals.requestTrackingAuthorization()
        if status == .authorized { Task { await self.maybeSyncAdvertisingId() } }
        return status == .authorized
    }

    func trackingStatus() -> TrackingStatus { signals.trackingStatus() }

    func setCustomerUserId(_ customerUserId: String) async {
        guard !customerUserId.isEmpty, !disabled, let transport else { return }
        do {
            let res = try await transport.request("/v1/sdk/identify", method: "POST", body: [
                "device_user_id": currentDeviceUserId(), "customer_user_id": customerUserId,
            ])
            if res.ok { storage.remove(Keys.pendingCustomerId) } else { storage.set(Keys.pendingCustomerId, customerUserId) }
        } catch {
            storage.set(Keys.pendingCustomerId, customerUserId)
        }
    }

    // ── attribution ────────────────────────────────────────────────────────

    func attribution() async -> AttributionResult? {
        if let cached = storage.get(Keys.attribution), let data = cached.data(using: .utf8),
           let dict = JSON.decode(data) as? [String: Any], let r = AttributionResult(dict) {
            return r
        }
        return await refreshAttribution()
    }

    func refreshAttribution() async -> AttributionResult? {
        guard configured, let transport else { return nil }
        let id = currentDeviceUserId().addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        do {
            let res = try await transport.request("/v1/sdk/attribution?device_user_id=\(id)", method: "GET")
            guard res.ok || res.status == 404, let dict = res.json, let result = AttributionResult(dict) else { return nil }
            if result.status == "resolved", let s = String(data: res.data, encoding: .utf8) { storage.set(Keys.attribution, s) }
            return result
        } catch {
            return nil
        }
    }

    // ── divers ─────────────────────────────────────────────────────────────

    func sendTestEvent() async -> (success: Bool, message: String) {
        guard let transport else { return (false, "Stamina.configure() must be called first") }
        do {
            let res = try await transport.request("/v1/sdk/test", method: "POST", body: [:])
            let body = res.json ?? [:]
            return ((body["success"] as? Bool) ?? res.ok, (body["message"] as? String) ?? "HTTP \(res.status)")
        } catch {
            return (false, String(describing: error))
        }
    }

    func deviceInfo() async -> [String: Any] {
        let s = await signals.collect()
        var out: [String: Any] = ["sdk_platform": "ios", "sdk_version": staminaSDKVersion, "att_status": s.attStatus.rawValue]
        out["os_version"] = s.osVersion ?? NSNull()
        out["device_model"] = s.deviceModel ?? NSNull()
        out["device_manufacturer"] = s.manufacturer ?? NSNull()
        out["screen_w"] = s.screenW ?? NSNull()
        out["screen_h"] = s.screenH ?? NSNull()
        out["screen_scale"] = s.screenScale ?? NSNull()
        out["color_scheme"] = s.colorScheme ?? NSNull()
        out["locale"] = s.locale ?? NSNull()
        out["timezone"] = s.timezone ?? NSNull()
        out["webview_user_agent"] = s.webViewUserAgent ?? NSNull()
        out["idfv"] = s.vendorId ?? NSNull()
        out["app_version"] = s.appVersion ?? NSNull()
        out["app_build"] = s.appBuild ?? NSNull()
        out["has_adservices_token"] = s.adServicesToken != nil
        out["has_idfa"] = s.advertisingId != nil
        return out
    }

    /// Reset complet (y compris kill-switch et device id).
    func clearData() {
        Keys.all.forEach(storage.remove)
        deviceUserId = nil
        disabled = false
        flushFailCount = 0
        nextFlushAllowedAt = .distantPast
    }

    /// Coupe timers et observateurs (tests / réinitialisation).
    func destroy() {
        flushTimer?.cancel()
        flushTimer = nil
        installRetry?.cancel()
        installRetry = nil
        lifecycle?.stop()
        lifecycle = nil
        configured = false
    }
}
