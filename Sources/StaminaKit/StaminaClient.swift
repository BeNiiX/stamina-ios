// Cœur du SDK : identité, install, file d'événements, sessions, synchro IDFA, attribution.
// Miroir du cœur TypeScript (stamina-sdk/src/index.ts) — docs/13-SPEC-SDK.md fait foi.
//
// Concurrence : tout l'état vit dans cet actor. Le stockage et la file sont SYNCHRONES (UserDefaults),
// donc les sections critiques (sessions, enqueue) n'ont aucun point de suspension et ne s'entrelacent
// jamais. Seul le réseau est asynchrone ; le drapeau `flushing` empêche deux envois simultanés.
import Foundation

public let staminaSDKVersion = "1.1.0"

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
    /// Copie mémoire de la file persistée : évite de redécoder le JSON à chaque événement.
    private var queueCache: [[String: Any]]?

    init(storage: StaminaStorage = UserDefaultsStorage(), signals: SignalsProviding = DeviceSignals()) {
        self.storage = storage
        self.signals = signals
    }

    // ── hooks de test ──────────────────────────────────────────────────────

    func _setStorage(_ s: StaminaStorage) { storage = s; queueCache = nil }
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
        stopTimers() // configure() rappelé : on repart propre, sans doubler observateurs ni timers

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

        // identité client / IDFA en attente (échec réseau précédent) → retry
        if let customer = config.customerUserId.flatMap({ $0.isEmpty ? nil : $0 }) ?? storage.get(Keys.pendingCustomerId) {
            Task { await self.setCustomerUserId(customer) }
        }
        if let pendingAd = storage.get(Keys.pendingAdvertisingId) {
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
        if let queueCache { return queueCache }
        var queue: [[String: Any]] = []
        if let raw = storage.get(Keys.queue), let data = raw.data(using: .utf8) {
            if let arr = JSON.decode(data) as? [[String: Any]] {
                queue = arr.filter { $0["name"] is String }
            } else {
                Log.warn("file d'événements corrompue — réinitialisée.")
                storage.remove(Keys.queue)
            }
        }
        queueCache = queue
        return queue
    }

    private func writeQueue(_ queue: [[String: Any]]) {
        let trimmed = Array(queue.suffix(StaminaClient.maxQueue))
        queueCache = trimmed
        if trimmed.isEmpty {
            storage.remove(Keys.queue)
        } else if let data = JSON.encode(trimmed), let s = String(data: data, encoding: .utf8) {
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
        var payload = s.deviceFields
        let extra: [String: Any?] = [
            "device_user_id": currentDeviceUserId(),
            "webview_user_agent": config.webviewUserAgent ?? s.webViewUserAgent,
            "install_referrer": nil,
            "adservices_token": config.adservicesToken ?? s.adServicesToken,
            "idfa": adId,
            "gaid": nil,
            "customer_user_id": config.customerUserId,
            "extras": [
                "sdk_platform": platform,
                "sdk_version": staminaSDKVersion,
                "att_status": s.attStatus.rawValue,
                "app_version": s.appVersion ?? NSNull(),
                "app_build": s.appBuild ?? NSNull(),
            ] as [String: Any],
        ]
        payload.merge(extra.mapValues { $0 ?? NSNull() }) { _, new in new }
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
        guard !isZeroAdId(id) else { return }
        if await identify("advertising_id", id, pendingKey: Keys.pendingAdvertisingId) {
            storage.set(Keys.advertisingIdSent, id)
        }
    }

    /// `/v1/sdk/identify` pour un champ ; en cas d'échec la valeur reste sous `pendingKey` et repart
    /// au prochain configure().
    @discardableResult
    private func identify(_ field: String, _ value: String, pendingKey: String) async -> Bool {
        guard !value.isEmpty, !disabled, let transport else { return false }
        let res = try? await transport.request("/v1/sdk/identify", method: "POST", body: [
            "device_user_id": currentDeviceUserId(), field: value,
        ])
        let ok = res?.ok ?? false
        if ok { storage.remove(pendingKey) } else { storage.set(pendingKey, value) }
        return ok
    }

    func requestTrackingAuthorization() async -> Bool {
        let status = await signals.requestTrackingAuthorization()
        if status == .authorized { Task { await self.maybeSyncAdvertisingId() } }
        return status == .authorized
    }

    func trackingStatus() -> TrackingStatus { signals.trackingStatus() }

    func setCustomerUserId(_ customerUserId: String) async {
        await identify("customer_user_id", customerUserId, pendingKey: Keys.pendingCustomerId)
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
        var out = s.deviceFields
        out["sdk_platform"] = platform
        out["sdk_version"] = staminaSDKVersion
        out["att_status"] = s.attStatus.rawValue
        out["app_version"] = s.appVersion ?? NSNull()
        out["app_build"] = s.appBuild ?? NSNull()
        out["has_adservices_token"] = s.adServicesToken != nil
        out["has_idfa"] = s.advertisingId != nil
        return out
    }

    /// Reset complet (y compris kill-switch et device id).
    func clearData() {
        Keys.all.forEach(storage.remove)
        queueCache = nil
        deviceUserId = nil
        disabled = false
        flushFailCount = 0
        nextFlushAllowedAt = .distantPast
    }

    /// Coupe timers et observateurs (tests / réinitialisation).
    func destroy() {
        stopTimers()
        configured = false
    }

    private func stopTimers() {
        flushTimer?.cancel()
        flushTimer = nil
        installRetry?.cancel()
        installRetry = nil
        lifecycle?.stop()
        lifecycle = nil
    }

    /// Valeur de `extras.sdk_platform` : `ios`, ou celle du wrapper (Flutter, React Native).
    private var platform: String {
        guard let p = config?.sdkPlatform, !p.isEmpty else { return "ios" }
        return p
    }
}
