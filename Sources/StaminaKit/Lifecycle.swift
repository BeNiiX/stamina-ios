// Cycle de vie de l'app : premier plan (sessions + détection du consentement ATT — le dialogue
// système fait passer par inactive → active) et arrière-plan (session_end). Référence : spec §7, §8.
import Foundation
import UIKit

final class LifecycleObserver {
    private var tokens: [NSObjectProtocol] = []

    init(onActive: @escaping @Sendable () -> Void, onBackground: @escaping @Sendable () -> Void) {
        let nc = NotificationCenter.default
        tokens.append(nc.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in onActive() })
        tokens.append(nc.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { _ in onBackground() })
    }

    func stop() {
        tokens.forEach(NotificationCenter.default.removeObserver)
        tokens.removeAll()
    }

    deinit { stop() }
}
