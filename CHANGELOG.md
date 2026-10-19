# Changelog

## 1.1.1 — 2026-10-19

- Manifeste de confidentialité : `NSPrivacyTracking = false`, identifiant d'appareil et données
  publicitaires déclarés « non utilisés pour le pistage ». La 1.1.0 déclarait le pistage avec une liste
  `NSPrivacyTrackingDomains` vide, combinaison refusée à l'envoi par App Store Connect (ITMS-91064).
  Une app qui demande l'ATT déclare le pistage dans son propre manifeste.

## 1.1.0 — 2026-10-18

- `Stamina.appAccountToken()` : jeton à passer à `product.purchase(options:)` pour les apps StoreKit 2
  sans RevenueCat. Le revenu arrive par les App Store Server Notifications V2, rattaché à l'install.
- Interne, sans changement de comportement : file d'événements gardée en mémoire (plus de décodage JSON
  à chaque événement), identify factorisé, champs d'appareil partagés entre l'install et `deviceInfo()`
  (qui renvoie désormais le bon `sdk_platform` pour Flutter / React Native).

## 1.0.0 — 2026-09-21

Première version publique.

- Install attribué : jeton AdServices (Apple Search Ads), IDFV, UA WebView, modèle exact, IDFA si ATT autorisé.
- IDFA rattaché automatiquement à l'install après le consentement ATT, quel que soit le code qui affiche le prompt.
- Sessions automatiques (30 min), file d'événements persistée (500, lots de 100, backoff), install envoyé une fois avec retry.
- Kill-switch sur clé rejetée (401/403 JSON), repli d'adresse.
- Pont RevenueCat sans dépendance (`StaminaPurchasesBridge`).
- Manifeste de confidentialité inclus.
- Conforme à la spécification commune des SDK STAMINA (9 scénarios de conformité).
