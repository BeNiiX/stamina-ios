# StaminaKit — SDK d'attribution STAMINA pour iOS (Swift)

Une ligne à intégrer, zéro dépendance, rien à brancher : install attribué (Apple Search Ads via
AdServices, liens de tracking via matching), sessions, revenu par source d'acquisition.
Même comportement que les SDK STAMINA React Native, Android et Flutter (spécification et suite de conformité communes).

## Installation

**Swift Package Manager** — Xcode → File → Add Package Dependencies →
`https://github.com/BeNiiX/stamina-ios.git` (ou dans `Package.swift`) :

```swift
.package(url: "https://github.com/BeNiiX/stamina-ios.git", from: "1.1.0")
```

**CocoaPods** :

```ruby
pod 'StaminaKit', '~> 1.0'
```

iOS 15+. Frameworks liés automatiquement : WebKit, AdSupport, AppTrackingTransparency, AdServices.

## Usage

```swift
import StaminaKit

// AppDelegate.didFinishLaunching ou App.init — non bloquant, l'install part en arrière-plan
Stamina.configure(apiKey: "stam_ios_live_…")

// Événements (taxonomie standard normalisée, le reste part en `custom`)
Stamina.sendEvent("login")
Stamina.sendEvent("purchase", params: ["revenue": 9.99, "currency": "EUR"])
Stamina.sendEvent("custom", subtype: "level_complete", params: ["level": 5])

// Funnel d'onboarding : nom d'étape STABLE en snake_case ; l'ordre se déclare dans le dashboard
Stamina.trackOnboardingStep("choose_goal", step: 2)

// Attribution résolue de cet install (cache local, sinon fetch)
let attribution = await Stamina.attribution()
```

### Revenu, cas 1 : RevenueCat

Le SDK n'importe pas RevenueCat : passez-lui un pont de 4 méthodes autour de `Purchases.shared`,
**après** `Purchases.configure`, et à chaque `logIn` / `logOut` de l'app :

```swift
import RevenueCat

struct RevenueCatBridge: StaminaPurchasesBridge {
    func isAnonymous() async throws -> Bool { Purchases.shared.isAnonymous }
    func appUserID() async throws -> String { Purchases.shared.appUserID }
    func logIn(_ id: String) async throws { _ = try await Purchases.shared.logIn(id) }
    func setAttributes(_ a: [String: String]) async throws { Purchases.shared.attribution.setAttributes(a) }
}

await Stamina.linkRevenueCat(RevenueCatBridge())
```

Tous les cas sont couverts (RC anonyme → aliasé sur l'id STAMINA ; id maison → retenu comme
`customer_user_id`) et l'attribut abonné `stamina_device_user_id` est toujours posé.

### Revenu, cas 2 : StoreKit 2 seul, sans RevenueCat

Apple envoie chaque achat, essai, renouvellement, résiliation et remboursement au serveur STAMINA
(App Store Server Notifications V2). Dans l'app, il suffit de passer le jeton STAMINA à l'achat :

```swift
let options: Set<Product.PurchaseOption> = await Stamina.appAccountToken().map { [.appAccountToken($0)] } ?? []
let result = try await product.purchase(options: options)
```

Puis, dans App Store Connect → l'app → Informations sur l'app → **Notifications du serveur de
l'App Store**, collez `https://api.getstamina.io/v1/integrations/appstore/notifications/<app_id>`
en **Production** et en **Sandbox**, version 2. Le serveur vérifie la signature Apple et le bundle id.
N'envoyez pas en plus `sendEvent("purchase", params: ["revenue": …])` : l'achat compterait deux fois.

### ATT / IDFA : rien à faire

Quel que soit le code qui affiche le prompt ATT (le vôtre, AppsFlyer…), le SDK relit le statut au
retour au premier plan et rattache l'IDFA à l'install dès qu'il est autorisé, une seule fois.
`Stamina.requestTrackingAuthorization()` existe si vous voulez que le SDK affiche le prompt
(`NSUserTrackingUsageDescription` requis dans Info.plist) ; `Stamina.syncAdvertisingId()` force la
relecture. Ni l'un ni l'autre n'est nécessaire.

## API

| Méthode | Rôle |
|---|---|
| `configure(apiKey:deviceUserId:customerUserId:autoTrackSessions:)` / `configure(StaminaConfig)` | Init non bloquante, idempotente |
| `deviceUserId()` | Id anonyme persisté (à partager avec RevenueCat) |
| `sendEvent(_:subtype:params:)` | Événement ; `revenue`/`price` + `currency` pour le revenu |
| `trackOnboardingStep(_:step:params:)` | Étape d'onboarding typée |
| `setCustomerUserId(_:)` | Id interne (opaque/hashé), retry automatique |
| `linkRevenueCat(_:logIn:)` | Identité partagée RevenueCat |
| `appAccountToken()` | Jeton d'achat StoreKit 2 (revenu sans RevenueCat) |
| `attribution()` / `refreshAttribution()` | Attribution de l'install |
| `requestTrackingAuthorization()` / `trackingStatus` / `syncAdvertisingId()` | ATT (facultatif) |
| `sendTestEvent()` / `deviceInfo()` | Diagnostic |
| `flush()` / `clearData()` / `destroy()` | File, reset complet, arrêt |
| `isInitialized` / `isDisabled` | État (kill-switch si la clé est rejetée) |

Les appels non bloquants (`configure`, `sendEvent`, `trackOnboardingStep`, `setCustomerUserId`)
passent par un bus FIFO : l'ordre d'appel est l'ordre d'envoi.

## Comportement (identique aux autres SDK STAMINA)

Install envoyé une fois (retry 30 s / 2 min / 10 min) · file persistée 500 événements, lots de 100,
timer 20 s, backoff 30 s → 5 min · sessions automatiques (nouvelle session après 30 min d'arrière-plan,
`session_end` avec durée) · kill-switch uniquement sur 401/403 JSON du serveur · repli d'adresse
`api.getstamina.io` → `stamina-tracker.stamina.workers.dev` · stockage `UserDefaults` suite
`io.getstamina.sdk` (mêmes clés que le SDK React Native : un appareil qui change de SDK garde son
identité) · manifeste de confidentialité inclus (`PrivacyInfo.xcprivacy`).

## Développement

```bash
scripts/test.sh            # démarre le serveur de conformité, xcodebuild test sur le simulateur booté
```

Tests : 5 unitaires (`EventsTests`) + 9 scénarios de conformité (`ConformanceTests`, faux signaux
pour piloter ATT/IDFA, vrais UserDefaults/UIKit/WKWebView du simulateur). Le jeton AdServices et
l'IDFA réels n'existent que sur appareil : à vérifier avec une vraie campagne Apple Search Ads
(page Installs du dashboard → « Apple Search Ads · Certain »).

## Licence

MIT — voir `LICENSE`.
