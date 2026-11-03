# BillingBear iOS SDK

Native Swift SDK for [BillingBear](https://api.billingbear.io) subscription management, using **StoreKit 2** and async/await. Mirrors the `@billingbear/purchases` React Native SDK: anonymous-first user management, entitlement lookups, login/logout, web checkout, and on-device purchase validation.

- Swift 5.9+, SwiftPM
- iOS 15+ / macOS 12+
- One dependency: [lottie-ios](https://github.com/airbnb/lottie-ios) (animated paywall backgrounds), resolved automatically

## Install (Swift Package Manager)

In Xcode: **File > Add Package Dependencies…** and point at `https://github.com/Spicy-Sparks/billingbear-ios`, or add to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/Spicy-Sparks/billingbear-ios", from: "1.1.0")
]
```

Or with CocoaPods: `pod 'BillingBear', '~> 1.1'`.

Then add `"BillingBear"` to your target's dependencies.

## Quick Start

```swift
import BillingBear
import StoreKit

// 1. Configure at app startup
await Purchases.shared.configure(apiKey: "pk_live_...")

// 2. Check entitlements
let info = try await Purchases.shared.customerInfo()
print(info.isPremium)                                  // true / false
print(info.entitlements["premium"]?.isActive ?? false) // true / false
print(info.activeSubscription?.store ?? "none")        // "apple", "stripe", ...

// Shortcuts
let premium = try await Purchases.shared.isPremium()          // Bool
let pro = try await Purchases.shared.checkEntitlement("pro")   // Bool
```

## Configure

```swift
await Purchases.shared.configure(
    apiKey: "pk_live_...",          // Required (public key)
    appUserId: "known-user-id",     // Optional — defaults to an anonymous id
    baseURL: "https://api.billingbear.io" // Optional override
)
```

When `appUserId` is omitted, the SDK generates an anonymous id and persists it in `UserDefaults` (key `com.billingbear.anonymousAppUserId`), so the same anonymous user is recognised across launches.

Call `configure` as early as possible (in `application(_:didFinishLaunchingWithOptions:)` or your `App` initialiser): it starts the StoreKit transaction listener, and a transaction that arrives before it is only picked up at the next foreground.

### Purchase-core options

```swift
await Purchases.shared.configure(
    apiKey: "pk_live_...",
    options: PurchasesOptions(
        finishTransactions: true,            // false = observer mode: your code finishes transactions
        customerInfoCacheTTL: 300,           // seconds a customer info stays fresh
        offlineEntitlementsWindow: 86_400,   // how old a cached answer may be when BillingBear is unreachable
        offlineEntitlement: "premium",       // granted by an active on-device purchase while offline (nil = off)
        promotionalOfferSigner: nil,         // optional: sign promotional offers on your backend (see below)
        endUserTokenProvider: nil            // optional: { appUserId in try await myBackend.billingBearToken(appUserId) }
    )
)
```

## What the SDK does with StoreKit transactions

From `configure` on, the SDK:

- **Listens to `Transaction.updates`** (one listener per process, kept across reconfigures). Renewals, Ask to Buy approvals, redeemed offer codes, refunds and purchases made on another device are validated with BillingBear and then finished.
- **Replays `Transaction.unfinished`** at launch and every time the app returns to the foreground, so a purchase interrupted between payment and validation (app killed, no network) is never lost.
- **Finishes a transaction only after BillingBear accepted it.** A failed validation leaves it unfinished; transient failures (network, 429, 5xx) are retried after 5 s, 30 s, 2 min and 10 min, then at the next foreground or launch. A retry is only sent for the subscriber whose validation failed: `login`/`logout` cancel pending retries (the replay at the next foreground validates what is still unfinished for the subscriber then current, as RevenueCat does).
- Every server change to one subscription (its renewals, refunds, restore) is sent one at a time, and a purchase is validated for the subscriber who started it, even if they log out while the sheet is open.
- Routes **subscriptions** to `/subscription/confirm` and **consumables / non-consumables** to `/v1/subscribers/{appUserId}/non-subscription`.
- **Renewals replayed out of order** (several renewals left unfinished while the app was closed) are confirmed with the subscription's latest transaction, because BillingBear records the period of the transaction it is given: an older renewal can never roll a paid subscription back. A renewal superseded by an upgrade is not confirmed.
- Different revisions of one transaction (the purchase and, later, its refund) are processed one after the other; once a refund is seen, the older revision neither grants nor finishes anything.
- **Revocations:** a refunded subscription is confirmed again, which makes BillingBear re-read it from Apple and remove the entitlement; it is finished only once that confirm succeeded. A refunded one-time purchase is never recorded again (that would grant it again): it stays unfinished until BillingBear's record of it shows the refund (its App Store refund notification), or BillingBear never recorded it for this subscriber. A refund of a purchase the SDK already validated is new work, not a duplicate. A Family Sharing revocation (which BillingBear records without a refund date) is done once BillingBear answers. **Upgrades:** the upgraded-away transaction is not confirmed (Apple marks it revoked as of the upgrade, and confirming it would expire the subscription; its replacement carries the entitlement); it is finished once BillingBear answers.
- Sends each purchase with a deterministic `appAccountToken` (UUIDv5 of the appUserId, identical to the React Native and Android SDKs).
- Skips (never grants, never finishes) transactions StoreKit could not verify.

`PurchasesOptions(finishTransactions: false)` is observer mode: every transaction is still synced, but your own StoreKit code finishes it.

## Customer info updates

```swift
// AsyncStream: starts with the last known value, then every change.
Task {
    for await info in Purchases.shared.customerInfoStream {
        paywallModel.isPremium = info.isPremium
    }
}

// Or a delegate (held weakly, called on the main actor; every method is optional).
final class Store: PurchasesDelegate {
    func purchases(_ purchases: Purchases, receivedUpdated customerInfo: CustomerInfo) { /* ... */ }
    func purchases(_ purchases: Purchases, didSyncTransaction transaction: StoreTransaction, customerInfo: CustomerInfo) {
        // An Ask to Buy approval, renewal, offer code or another device's purchase was validated.
    }
    func purchases(_ purchases: Purchases, didFailToSyncTransaction transaction: StoreTransaction, error: PurchasesError) {
        // Left unfinished; the SDK retries. Log it.
    }
}
Purchases.shared.delegate = store
```

`customerInfo(fetchPolicy:)` takes RevenueCat's policies: `.cachedOrFetched` (what `customerInfo()` uses: the cache while fresh, else the network), `.notStaleCachedOrFetched`, `.fetchCurrent` and `.fromCacheOnly`. Concurrent reads share one request, and an answer that started before a purchase (a read, or a background renewal's sync) can never overwrite the purchase's result.

> **Behaviour change from 1.0.0:** `customerInfo()` used to ask BillingBear on every call; it now serves a cache younger than `customerInfoCacheTTL` (5 minutes), like the React Native SDK and RevenueCat. Use `customerInfo(fetchPolicy: .fetchCurrent)` or `invalidateCustomerInfoCache()` after a change made outside the app (e.g. a web purchase).

## Offline entitlements

When BillingBear cannot be reached (a transport failure, not a server error), `customerInfo()` and `restore()` do not downgrade a paying user:

1. the last server answer for this subscriber is served while it is younger than `offlineEntitlementsWindow` (24 h by default; it is persisted in `UserDefaults` and survives relaunches, scoped to the project and the appUserId);
2. StoreKit's verified, still-active purchases add a provisional `offlineEntitlement` ("premium") on top. The result has `isOfflineComputed == true`, is never persisted, and is replaced by the next successful fetch.

A server rejection (4xx/5xx) never produces a provisional grant: it falls back to the cached answer only.

## Purchase (StoreKit 2)

```swift
// Load your products with StoreKit directly:
let products = try await Product.products(for: ["com.myapp.premiumMonthly"])

// Purchase — the SDK runs the StoreKit flow, sends the verified transaction
// to /subscription/confirm, finishes the transaction, and returns the
// refreshed customer info.
let result = try await Purchases.shared.purchase(product: products[0])
print(result.customerInfo.isPremium) // true
print(result.productId)
print(result.transactionId ?? "")
```

A one-time product (consumable or non-consumable) is recorded on BillingBear's one-time purchase path automatically, and `result.nonSubscriptionRecord` carries BillingBear's record of it: `entitlementGranted`, `alreadyRecorded`, `revoked` (the store took it back: refund, void or Family Sharing withdrawal — it never grants again), `refundedAt`, `transferred` (moved here from another subscriber under the project's transfer policy) and `keptByOriginalOwner`. The StoreKit transaction is finished on any 200 answer, a revoked one included, and the entitlements are read back. You can also purchase by id: `try await Purchases.shared.purchase(productId: "com.myapp.premiumMonthly")`.

**Ask to Buy / deferred payments:** `purchase` throws `.paymentPending`. When the purchase is approved, StoreKit delivers it to the transaction listener; the SDK validates and finishes it and the new entitlement reaches `customerInfoStream` and the delegate (`didSyncTransaction`).

Errors are surfaced as `PurchasesError`:

| Code | Meaning |
| --- | --- |
| `.userCancelled` | User cancelled the StoreKit sheet |
| `.paymentPending` | Deferred / awaiting approval (Ask to Buy) |
| `.storeError` | StoreKit failure or unverified transaction |
| `.validationError` | Backend rejected the receipt |
| `.networkError` | Transport failure |
| `.notConfigured` | `configure(apiKey:)` was not called |

## Restore

```swift
let info = try await Purchases.shared.restore()
// Sends every verified StoreKit entitlement to BillingBear and returns the refreshed customer info.
// A purchase the backend rejects (4xx) is skipped; if every purchase failed on the server, the last
// error is thrown; if every purchase failed for the network, the offline grant is returned.

try await Purchases.shared.syncPurchases() // silent: no restore UI semantics (e.g. observer mode)
```

`restore()` is the customer's "Restore Purchases": a purchase another subscriber holds follows the project's restore transfer policy. `syncPurchases()`, `Transaction.updates`, the unfinished-transaction replay and background retries are silent syncs (`claimOrphanOnly: true`): they adopt purchases parked on an anonymous id but never take one from another subscriber. A purchase made with `purchase(…)` is explicit, like `restore()`.

## Intro offers, promotional offers, win-back offers

```swift
// Free trial / intro price eligibility (StoreKit's answer; RevenueCat's IntroEligibilityStatus values).
let eligibility = await Purchases.shared.checkTrialOrIntroDiscountEligibility(productIdentifiers: ["com.myapp.yearly"])
if eligibility["com.myapp.yearly"]?.status == .eligible { showTrialBadge() }

// Promotional offers (signed). The signature must be made for the purchase's appAccountToken.
let offer = try await Purchases.shared.getPromotionalOffer(productId: "com.myapp.yearly", offerId: "comeback50")
let result = try await Purchases.shared.purchase(product: yearly, promotionalOffer: offer)

// Win-back offers (iOS 18+).
let winBacks = try await Purchases.shared.eligibleWinBackOffers(forProduct: monthly)
if let best = winBacks.first {
    _ = try await Purchases.shared.purchase(product: monthly, winBackOffer: best)
}
```

When StoreKit cannot load a product, eligibility falls back to a hint from the subscriber's history (the current subscription's product is ineligible, a subscriber without any entitlement is eligible, anything else is unknown).

**Signing promotional offers.** BillingBear signs them out of the box: `getPromotionalOffer` calls `POST /v1/subscribers/{appUserId}/apple/promotional-offer-signature` with the publishable key, sending the product, the offer, the purchase's `appAccountToken` and the app's bundle id. BillingBear signs with the project's App Store In-App Purchase key for that `appAccountToken` — Apple's `applicationUsername`, which StoreKit checks the signature against.

Before the first signature:

- upload the App Store **In-App Purchase key** in the dashboard;
- **configure the offer**: BillingBear only signs an offer id that is the *store offer id* of one of the project's **Customer Center retention offers** (the promotional offer identifier from App Store Connect). Any other id answers `offer_not_configured`;
- the product must be one of the project's App Store products, and the subscriber must already exist in BillingBear (any earlier SDK call creates it);
- if the project requires end-user tokens, set `PurchasesOptions.endUserTokenProvider` (the same token the Customer Center uses, sent as `X-BillingBear-User-Token`). Without that requirement the publishable key is enough.

Errors (`PurchasesError.serverCode` carries the backend code; constants in `BillingBearAPI.PromotionalOfferErrorCode`):

| `PurchasesError.code` | HTTP / `serverCode` | Meaning |
| --- | --- | --- |
| `.productNotFound` | 404 `offer_not_configured` | The offer id is not a retention offer's store offer id |
| `.productNotFound` | 400 `product_not_in_project` | Not an App Store product of this project (or of this bundle) |
| `.validationError` | 404 `subscriber_not_found` | BillingBear has no customer for this appUserId yet |
| `.validationError` | 400 `app_account_token_mismatch`, `invalid_request` | The token is not this subscriber's / malformed request |
| `.notConfigured` | 409 `apple_iap_key_missing`, `apple_iap_key_invalid` | No (or an unreadable) In-App Purchase key for this app |
| `.notConfigured` | 401 / 403 | The project requires this subscriber's end-user token |
| `.networkError` | 429 (empty, or `rate_limited`), offline | Rate limited (10 a minute per subscriber) or unreachable: try later |

To sign on your own backend instead, set `PurchasesOptions.promotionalOfferSigner`:

```swift
struct MyBackendSigner: PromotionalOfferSigner {
    func signPromotionalOffer(_ request: PromotionalOfferSigningRequest) async throws -> PromotionalOffer {
        // POST request.productId / request.offerId / request.applicationUsername to your server, which signs
        // appBundleId ⁣ keyId ⁣ productId ⁣ offerId ⁣ applicationUsername ⁣ nonce ⁣ timestamp with your
        // App Store in-app purchase key. applicationUsername is the purchase's appAccountToken (lowercased).
        try await myServer.sign(request)
    }
}
```

## Paywalls, placements and exit offers

`BillingBearPaywall` is a SwiftUI renderer for the paywalls you design in the dashboard. A placement (a named app event) asks the backend whether to present one, and which offering to sell:

```swift
let decision = try await Purchases.shared.register("onboarding_complete")

// In your view:
if let paywall = BillingBearPaywall(decision: decision, onDismiss: { showPaywall = false }) {
    paywall.onPurchaseRequest { request in
        // request.offeringIdentifier: the exit offer's offering while the exit offer shows, else the
        // decision's. PaywallPurchaseLookup.find(productId:in:preferring:) resolves the package.
        do {
            let result = try await Purchases.shared.purchase(productId: request.product.identifier)
            // .failed for a purchase that unlocks nothing here (refunded, or kept by another account).
            return PaywallPurchaseOutcome(purchase: result)
        } catch let error as PurchasesError where error.userCancelled {
            return .cancelled
        } catch {
            return .failed
        }
    }
}
```

- **Offering experiments.** The decision's `offeringIdentifier` is the offering-experiment variant the customer is enrolled in, else the placement's default offering; the paywall hands it to `onPurchaseRequest(_:)`. Hosts with their own purchase UI call `try await Purchases.shared.currentOffering(forPlacement: "onboarding_complete")` instead.
- **One view per presentation.** The placement evaluation already records the paywall's `viewed` (its `presentationId`); the decision's paywall re-sends it only to carry a paywall A/B cell, folded into that row. For a paywall you build yourself (e.g. from `getPaywall(decision.paywallIdentifier!)`), add `.placementDecision(decision)`. Each decision is a new presentation: when a new decision replaces the one on screen, give the view a new identity (`.id(decision.presentationId)`).
- **Exit offers.** When the served version has one, closing without buying (close button, or a swipe-down of the sheet) shows the exit paywall in place, once per presentation and within its frequency cap; closing it ends the flow and calls `onDismiss` once. The source paywall records `exit_offer_viewed`, `exit_offer_purchased` (only for a `.completed` outcome) and `exit_offer_dismissed`. Turn it off with `.exitOffersEnabled(false)`. Hosts on the legacy `onPurchase` cannot report an outcome, so nothing is credited to an exit offer they buy from.

`BillingBearPaywall(identifier:)` renders a paywall directly, with the same exit-offer behaviour; `.purchaseOffering(_:)` chooses the offering it sells.

## Offer codes and refunds

```swift
try await Purchases.shared.presentCodeRedemptionSheet()   // the redemption arrives through the listener

let status = try await Purchases.shared.beginRefundRequest(forProduct: "com.myapp.monthly") // .success / .userCancelled
try await Purchases.shared.beginRefundRequest(forTransactionId: "2000000123456789")
```

Apple decides on a refund later; a granted refund arrives as a revoked transaction and removes the entitlement.

## Login / Logout

```swift
// After your auth confirms the user — merges anonymous purchases into them.
let info = try await Purchases.shared.login("firebase-uid-123")

// On logout — reverts to a fresh anonymous id (the identified user keeps everything).
let anon = try await Purchases.shared.logout()

await Purchases.shared.isAnonymous   // Bool
await Purchases.shared.appUserId     // current id
```

## Web Checkout (Stripe)

```swift
let session = try await Purchases.shared.createCheckoutSession(
    priceId: "price_1ABC...",
    successUrl: "https://myapp.com/success",
    cancelUrl: "https://myapp.com/cancel"
)
// Open session.url in a browser / SFSafariViewController.
```

## Lower-level API client

For advanced use you can talk to the REST API directly:

```swift
let api = BillingBearAPI(apiKey: "pk_live_...")
let info = try await api.fetchEntitlements(appUserId: "user-1")
let paywall = try await api.fetchPaywall(identifier: "main", appUserId: "user-1") // [String: Any]? (nil on 404)
```

## Endpoints

| Method | Path |
| --- | --- |
| `GET` | `/subscription/entitlements/{appUserId}` |
| `POST` | `/subscription/confirm` |
| `POST` | `/subscription/restore` |
| `POST` | `/v1/customers/login` |
| `POST` | `/v1/customers/logout` |
| `POST` | `/v1/checkout/session` |
| `POST` | `/v1/subscribers/{appUserId}/non-subscription` |
| `POST` | `/v1/subscribers/{appUserId}/apple/promotional-offer-signature` |
| `GET` | `/v1/paywalls/by-identifier/{identifier}` |
| `POST` | `/v1/paywalls/by-identifier/{identifier}/exposures` |
| `POST` | `/v1/placements/{placement}/evaluate` |
| `GET` | `/v1/subscribers/{appUserId}/offerings` |

All requests send `Authorization: Bearer <pk_ key>` and `Content-Type: application/json`.

## Testing

```bash
swift test
```

The unit suite uses a `URLProtocol` stub (no real network) to assert entitlement decoding/mapping, error mapping, the checkout request body, login/logout, paywall 404→nil handling, base-URL normalisation, and anonymous-id persistence.

The purchase-core suites (`PurchaseCoreTests`, `CustomerInfoCoreTests`, `StoreFeaturesTests`, `NonSubscriptionContractTests`, `PlacementPresentationTests`) run headless against protocol mocks: `MockStoreKit` (a `StoreKitClient`: transaction updates, unfinished transactions, purchases, finishes, offers, sheets) and `MockHTTPClient` (a `BillingBearHTTPClient`). `BillingBearAPI(httpClient:)` accepts any `BillingBearHTTPClient`, so host apps can test the same way.
