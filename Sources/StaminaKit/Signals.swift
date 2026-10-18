// Signaux d'appareil et d'attribution — même collecte que le module natif du SDK React Native
// (ios/StaminaNativeModule.swift), sans l'enveloppe Expo. Référence : docs/13-SPEC-SDK.md §3 et §8.
import Foundation
import UIKit
import WebKit
import AdSupport
import AppTrackingTransparency
import AdServices

/// Statut ATT. Toujours `authorized` hors iOS.
public enum TrackingStatus: String, Sendable {
    case authorized, denied, restricted, notDetermined = "not_determined", unavailable
}

struct CollectedSignals {
    var osVersion: String?
    var deviceModel: String?
    var manufacturer: String? = "Apple"
    var screenW: Int?
    var screenH: Int?
    var screenScale: Double?
    var colorScheme: String?
    var locale: String?
    var timezone: String?
    var appVersion: String?
    var appBuild: String?
    var bundleId: String?
    var webViewUserAgent: String?
    var vendorId: String?
    var attStatus: TrackingStatus = .unavailable
    var advertisingId: String?
    var adServicesToken: String?

    /// Champs d'appareil tels qu'ils partent sur le fil — partagés par l'install et `deviceInfo()`.
    var deviceFields: [String: Any] {
        let fields: [String: Any?] = [
            "os_version": osVersion,
            "device_model": deviceModel,
            "device_manufacturer": manufacturer,
            "screen_w": screenW,
            "screen_h": screenH,
            "screen_scale": screenScale,
            "color_scheme": colorScheme,
            "locale": locale,
            "timezone": timezone,
            "webview_user_agent": webViewUserAgent,
            "idfv": vendorId,
        ]
        return fields.mapValues { $0 ?? NSNull() }
    }
}

/// Abstraction des signaux : `DeviceSignals` en production, un faux dans les tests de conformité.
protocol SignalsProviding: AnyObject {
    func collect() async -> CollectedSignals
    func trackingStatus() -> TrackingStatus
    func requestTrackingAuthorization() async -> TrackingStatus
    /// IDFA si ATT autorisé et non tout-à-zéro, sinon nil.
    func advertisingId() async -> String?
}

final class DeviceSignals: SignalsProviding {
    init() {}

    func collect() async -> CollectedSignals {
        // Ce qui touche UIKit se lit sur le main thread, d'un bloc, sans muter de variable capturée.
        let ui: (os: String, idfv: String?, w: Int, h: Int, scale: Double, scheme: String) = await MainActor.run {
            let screen = UIScreen.main
            return (
                UIDevice.current.systemVersion,
                UIDevice.current.identifierForVendor?.uuidString,
                Int(screen.bounds.width.rounded()),
                Int(screen.bounds.height.rounded()),
                Double(screen.scale),
                UITraitCollection.current.userInterfaceStyle == .dark ? "dark" : "light"
            )
        }
        var s = CollectedSignals()
        s.osVersion = ui.os
        s.vendorId = ui.idfv
        s.screenW = ui.w
        s.screenH = ui.h
        s.screenScale = ui.scale
        s.colorScheme = ui.scheme
        s.deviceModel = DeviceSignals.modelIdentifier
        s.locale = Locale.preferredLanguages.first ?? Locale.current.identifier
        s.timezone = TimeZone.current.identifier
        let bundle = Bundle.main
        s.appVersion = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        s.appBuild = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        s.bundleId = bundle.bundleIdentifier
        s.webViewUserAgent = await withTimeout(seconds: 4) { await DeviceSignals.readWebViewUserAgent() }
        s.attStatus = trackingStatus()
        s.advertisingId = await advertisingId()
        s.adServicesToken = await withTimeout(seconds: 3) {
            await Task.detached(priority: .utility) { try? AAAttribution.attributionToken() }.value
        }
        return s
    }

    func trackingStatus() -> TrackingStatus {
        switch ATTrackingManager.trackingAuthorizationStatus {
        case .authorized: return .authorized
        case .denied: return .denied
        case .restricted: return .restricted
        case .notDetermined: return .notDetermined
        @unknown default: return .notDetermined
        }
    }

    /// Sans NSUserTrackingUsageDescription iOS ne montre rien et répond « denied » : on le signale.
    func requestTrackingAuthorization() async -> TrackingStatus {
        guard Bundle.main.object(forInfoDictionaryKey: "NSUserTrackingUsageDescription") != nil else {
            Log.warn("requestTrackingAuthorization: NSUserTrackingUsageDescription absent d'Info.plist — prompt impossible.")
            return .unavailable
        }
        _ = await ATTrackingManager.requestTrackingAuthorization()
        return trackingStatus()
    }

    func advertisingId() async -> String? {
        guard trackingStatus() == .authorized else { return nil }
        let id = ASIdentifierManager.shared().advertisingIdentifier.uuidString
        return isZeroAdId(id) ? nil : id
    }

    // ── helpers ────────────────────────────────────────────────────────────

    /// WKWebView doit vivre jusqu'au retour de evaluateJavaScript : on les retient le temps de l'appel.
    @MainActor private static var pendingWebViews: [WKWebView] = []

    @MainActor private static func readWebViewUserAgent() async -> String? {
        await withCheckedContinuation { cont in
            let webView = WKWebView(frame: .zero)
            pendingWebViews.append(webView)
            webView.evaluateJavaScript("navigator.userAgent") { result, _ in
                pendingWebViews.removeAll { $0 === webView }
                cont.resume(returning: result as? String)
            }
        }
    }

    /// « iPhone15,2 » — l'identifiant matériel exact. Sur simulateur uname renvoie l'archi du Mac.
    static let modelIdentifier: String = {
        if let simulated = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] { return simulated }
        var systemInfo = utsname()
        uname(&systemInfo)
        let mirror = Mirror(reflecting: systemInfo.machine)
        return mirror.children.reduce("") { identifier, element in
            guard let value = element.value as? Int8, value != 0 else { return identifier }
            return identifier + String(UnicodeScalar(UInt8(value)))
        }
    }()
}

/// Borne une opération dans le temps : au-delà, nil (l'install ne doit jamais attendre un service natif).
func withTimeout<T>(seconds: Double, _ operation: @escaping () async -> T?) async -> T? {
    await withTaskGroup(of: T?.self) { group in
        group.addTask { await operation() }
        group.addTask {
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            return nil
        }
        let first = await group.next() ?? nil
        group.cancelAll()
        return first
    }
}

enum Log {
    static func warn(_ message: String) { print("[STAMINA] \(message)") }
}
