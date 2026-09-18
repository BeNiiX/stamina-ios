// Stockage clé/valeur. Suite UserDefaults `io.getstamina.sdk` et clés `@stamina/*` — identiques au SDK
// React Native (docs/13-SPEC-SDK.md §4) : un appareil qui change de SDK garde son identité.
import Foundation

enum Keys {
    static let deviceId = "@stamina/device_user_id"
    static let installSent = "@stamina/install_registered"
    static let queue = "@stamina/event_queue"
    static let lastActivity = "@stamina/last_activity_ts"
    static let sessionId = "@stamina/session_id"
    static let sessionCount = "@stamina/session_count"
    static let sessionStartedAt = "@stamina/session_started_at"
    static let disabled = "@stamina/disabled"
    static let attribution = "@stamina/attribution"
    static let pendingCustomerId = "@stamina/pending_customer_id"
    static let pendingAdvertisingId = "@stamina/pending_advertising_id"
    static let advertisingIdSent = "@stamina/advertising_id_sent"

    static let all: [String] = [
        deviceId, installSent, queue, lastActivity, sessionId, sessionCount, sessionStartedAt,
        disabled, attribution, pendingCustomerId, pendingAdvertisingId, advertisingIdSent,
    ]
}

protocol StaminaStorage: AnyObject {
    func get(_ key: String) -> String?
    func set(_ key: String, _ value: String)
    func remove(_ key: String)
}

final class UserDefaultsStorage: StaminaStorage {
    static let suiteName = "io.getstamina.sdk"
    private let defaults: UserDefaults

    init() {
        defaults = UserDefaults(suiteName: UserDefaultsStorage.suiteName) ?? .standard
    }

    func get(_ key: String) -> String? { defaults.string(forKey: key) }
    func set(_ key: String, _ value: String) { defaults.set(value, forKey: key) }
    func remove(_ key: String) { defaults.removeObject(forKey: key) }
}

/// Mémoire seule (tests).
final class InMemoryStorage: StaminaStorage {
    private var map: [String: String] = [:]
    private let lock = NSLock()

    init() {}

    func get(_ key: String) -> String? { lock.lock(); defer { lock.unlock() }; return map[key] }
    func set(_ key: String, _ value: String) { lock.lock(); map[key] = value; lock.unlock() }
    func remove(_ key: String) { lock.lock(); map.removeValue(forKey: key); lock.unlock() }
    func clear() { lock.lock(); map.removeAll(); lock.unlock() }
}
