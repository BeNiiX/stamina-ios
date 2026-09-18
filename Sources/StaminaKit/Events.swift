// Événements : normalisation des noms et des étapes, revenu, sérialisation JSON.
// Référence : docs/13-SPEC-SDK.md §6.
import Foundation

enum Events {
    /// Taxonomie standard — tout autre nom part en `custom` avec le nom normalisé en `subtype`.
    static let standard: Set<String> = [
        "session_start", "session_end", "onboarding", "login", "sign_up", "register", "purchase", "subscribe",
        "start_trial", "add_payment_info", "add_to_cart", "add_to_wishlist",
        "initiate_checkout", "view_content", "view_item", "search", "share",
        "tutorial_complete", "achieve_level", "level_start", "level_complete",
        "test", "custom",
    ]

    /// minuscules, trim, `-` → `_`
    static func normalizeName(_ raw: String) -> String {
        raw.lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "-", with: "_")
    }

    /// Même règle que la base (normalize_step_name) : minuscules, espaces/tirets → `_`, `[a-z0-9_]`, 40 car.
    static func normalizeStep(_ raw: String) -> String {
        var s = raw.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        s = s.replacingOccurrences(of: "[\\s-]+", with: "_", options: .regularExpression)
        s = s.replacingOccurrences(of: "[^a-z0-9_]", with: "", options: .regularExpression)
        return String(s.prefix(40))
    }

    /// `params.revenue` numérique, sinon `params.price` (nombre ou chaîne numérique).
    static func coerceRevenue(_ params: [String: Any]?) -> Double? {
        if let n = numeric(params?["revenue"]) { return n }
        if let p = params?["price"] {
            if let n = numeric(p) { return n }
            if let s = p as? String {
                let t = s.trimmingCharacters(in: .whitespaces)
                if !t.isEmpty, let n = Double(t), n.isFinite { return n }
            }
        }
        return nil
    }

    private static func numeric(_ v: Any?) -> Double? {
        guard let v, !(v is Bool), !(v is String), let n = v as? NSNumber else { return nil }
        // NSNumber issu d'un Bool : CFBoolean — exclu ci-dessus par `v is Bool`
        return n.doubleValue.isFinite ? n.doubleValue : nil
    }

    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    static func isoString(_ date: Date) -> String { iso.string(from: date) }

    /// Construit l'événement tel qu'il part sur le fil (mêmes clés que le cœur TypeScript).
    static func make(name: String, subtype: String?, params: [String: Any]?, now: Date) -> [String: Any] {
        let normalized = normalizeName(name)
        let isStandard = standard.contains(normalized)
        var rest = params ?? [:]
        rest.removeValue(forKey: "revenue")
        rest.removeValue(forKey: "price")
        let currency = rest.removeValue(forKey: "currency") as? String
        let revenue = coerceRevenue(params)

        var ev: [String: Any] = [
            "id": UUID().uuidString.lowercased(),
            "name": isStandard ? normalized : "custom",
            "ts": isoString(now),
        ]
        let sub: String?
        if normalized == "onboarding", let subtype, !subtype.isEmpty {
            sub = normalizeStep(subtype)
        } else {
            sub = subtype ?? (isStandard ? nil : normalized)
        }
        ev["subtype"] = sub ?? NSNull()
        if let revenue { ev["revenue"] = revenue }
        if let currency { ev["currency"] = currency.uppercased() }
        if !rest.isEmpty { ev["params"] = JSON.sanitize(rest) }
        return ev
    }
}

/// Valeurs JSON sûres : tout ce qui n'est pas sérialisable devient sa description.
enum JSON {
    static func sanitize(_ dict: [String: Any]) -> [String: Any] {
        var out: [String: Any] = [:]
        for (k, v) in dict { out[k] = sanitizeValue(v) }
        return out
    }

    static func sanitizeValue(_ v: Any) -> Any {
        switch v {
        case is NSNull: return NSNull()
        case let s as String: return s
        case let b as Bool: return b
        case let n as NSNumber: return n.doubleValue.isFinite ? n : NSNull()
        case let d as Date: return Events.isoString(d)
        case let u as URL: return u.absoluteString
        case let arr as [Any]: return arr.map(sanitizeValue)
        case let dict as [String: Any]: return sanitize(dict)
        case let opt as Any?:
            if let inner = opt { return String(describing: inner) }
            return NSNull()
        }
    }

    static func encode(_ obj: Any) -> Data? {
        guard JSONSerialization.isValidJSONObject(obj) else { return nil }
        return try? JSONSerialization.data(withJSONObject: obj, options: [])
    }

    static func decode(_ data: Data) -> Any? {
        try? JSONSerialization.jsonObject(with: data, options: [])
    }
}

/// GAID / IDFA « tout-à-zéro » (Limit Ad Tracking) → à ignorer.
func isZeroAdId(_ s: String) -> Bool {
    !s.isEmpty && s.allSatisfy { $0 == "0" || $0 == "-" }
}
