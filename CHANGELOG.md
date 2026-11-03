# Changelog

## 1.1.0 (unreleased)

### Purchase core
- Every StoreKit transaction — from `purchase(…)`, `Transaction.updates`, the unfinished-transaction replay or a retry — is validated with BillingBear before it is finished; failed validations stay unfinished and are retried (5 s, 30 s, 2 min, 10 min) and replayed on foreground and at launch.
- Customer info stream and delegate, fetch policies (`customerInfo(fetchPolicy:)`, 5-minute cache), offline entitlements, Ask to Buy, observer mode (`finishTransactions: false`), refunds and upgrades that can no longer roll access back.
- Intro eligibility, promotional offers signed by BillingBear out of the box (`getPromotionalOffer`), win-back offers, offer codes and refund requests.
- One-time purchases follow the purchase-integrity contract:
  - `purchase(…)` and `restore()` send `claimOrphanOnly: false` (the project's restore transfer policy may move a purchase another subscriber holds); `Transaction.updates`, the replay, background retries and `syncPurchases()` send `true` (only purchases parked on an anonymous id are adopted). `syncPurchases()` also marks its subscription restores `claimOrphanOnly`, so a silent sync never takes a subscription from its owner.
  - `NonSubscriptionPurchaseResult` gains `revoked`, `refundedAt`, `transferred` and `keptByOriginalOwner` (absent on older servers: nil / false), exposed on `PurchaseResult.nonSubscriptionRecord`.
  - Any 200 finishes the transaction, a revoked one included — also when the entitlement read after it fails (the cached customer info is then marked outdated) — and the entitlements are read back. `restore()` finishes the one-time purchases it recorded, and a failed read after them marks the cache outdated too.
  - A refunded or withdrawn one-time purchase BillingBear recorded but has not taken back is posted again, so the server takes it back without waiting for the App Store notification. A revoked purchase BillingBear never recorded for this subscriber is never posted.
  - `purchase()` of a one-time product a silent sync just left with another subscriber records it again explicitly, so the transfer policy applies.
  - `purchase()` throws `.storeError` when a refund of the very transaction it got was already seen: the refund decides, so a taken-back purchase is never reported as a success.
- The promotional-offer signature endpoint's own 429 (`rate_limited`, `BillingBearAPI.PromotionalOfferErrorCode.rateLimited`) maps like the gateway's empty-body 429: `.networkError`.

### Paywalls
- Exit offers: closing a paywall without buying shows its exit offer in place, once per presentation and within its frequency cap (server `eligible` + a local record); a sheet swipe-down goes through the same close. `.exitOffersEnabled(_:)` turns it off.
- `.onPurchaseRequest(_:)` hands the host a `PaywallPurchaseRequest` (product, offering to buy from, paywall on screen, whether it is an exit offer) and takes a `PaywallPurchaseOutcome` (`.completed` / `.cancelled` / `.failed`); only a completed purchase is credited, disarms the exit offer or ends an exit-offer flow. One purchase runs per presentation at a time. `PaywallPurchaseOutcome(purchase:)` maps a `PurchaseResult` to the outcome to report: `.failed` for a one-time purchase this customer did not get (revoked, or a non-consumable kept by another subscriber, whatever other access they have).
- `PaywallExposureOutcome` gains `exitOfferViewed`, `exitOfferPurchased` and `exitOfferDismissed` (`exit_offer_viewed`, `exit_offer_purchased`, `exit_offer_dismissed`), so the exit-offer funnel reaches the dashboard. **Source note:** an exhaustive `switch` over `PaywallExposureOutcome` needs the new cases (or a `default`).
- Offering experiments and placements: `BillingBearPaywall(decision:)` renders the paywall a `register(_:)` decision presents, sells the decision's `offeringIdentifier` (the experiment variant, else the placement default) and attributes its view to the evaluation's `presentationId` (one view per presentation); `.placementDecision(_:)` does the same for a paywall you build yourself; `.purchaseOffering(_:)` picks the offering directly. `CampaignDecision` gains `offeringIdentifier`, `experimentId`, `experimentName`, `variant` and `presentationId`; `recordExposure` takes `presentationId`; `currentOffering(forPlacement:)` returns the offering a placement sells.

## 1.0.0
- First release: configure, customer info, login / logout, attributes, StoreKit 2 purchase and restore, offerings, placements (`register(_:)`), virtual currencies, web checkout, the native SwiftUI paywall (with its prefetch/cache speed layer) and Customer Center.
