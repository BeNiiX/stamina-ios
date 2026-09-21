# Changelog

## 1.0.0 — 2026-09-21

Première version publique.

- Install attribué : jeton AdServices (Apple Search Ads), IDFV, UA WebView, modèle exact, IDFA si ATT autorisé.
- IDFA rattaché automatiquement à l'install après le consentement ATT, quel que soit le code qui affiche le prompt.
- Sessions automatiques (30 min), file d'événements persistée (500, lots de 100, backoff), install envoyé une fois avec retry.
- Kill-switch sur clé rejetée (401/403 JSON), repli d'adresse.
- Pont RevenueCat sans dépendance (`StaminaPurchasesBridge`).
- Manifeste de confidentialité inclus.
- Conforme à la spécification commune des SDK STAMINA (9 scénarios de conformité).
