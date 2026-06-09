# BillingBear iOS SDK

Native Swift SDK for [BillingBear](https://api.billingbear.io) subscription management, using **StoreKit 2** and async/await. Mirrors the [`@billingbear/purchases`](../react-native) React Native SDK: anonymous-first user management, entitlement lookups, login/logout, web checkout, and on-device purchase validation.

- Swift 5.9+, SwiftPM
- iOS 15+ / macOS 12+
- Zero third-party dependencies

## Install (Swift Package Manager)

In Xcode: **File > Add Package Dependencies…** and point at this repository, or add to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/billingbear/billingbear-ios", from: "1.0.0")
]
```

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
// Iterates StoreKit current entitlements and validates each with the backend.
```

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
| `GET` | `/v1/paywalls/by-identifier/{identifier}` |

All requests send `Authorization: Bearer <pk_ key>` and `Content-Type: application/json`.

## Testing

```bash
swift test
```

The unit suite uses a `URLProtocol` stub (no real network) to assert entitlement decoding/mapping, error mapping, the checkout request body, login/logout, paywall 404→nil handling, base-URL normalisation, and anonymous-id persistence.
