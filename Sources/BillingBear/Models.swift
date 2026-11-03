import Foundation

// MARK: - Customer / Entitlements
//
// These mirror the shapes produced by the React Native SDK (`sdk/react-native/src/types.ts`)
// and the JSON returned by the BillingBear backend at GET /subscription/entitlements/{appUserId}.
//
// The backend returns numeric enums for `status` and `store`; we decode the raw wire shape in
// `RawEntitlementsResponse` (in BillingBearAPI) and map them to the friendly types below, exactly
// like `fetchEntitlements` does in the RN SDK.

/// A single named entitlement (e.g. "premium", "pro") the user currently holds.
public struct EntitlementInfo: Codable, Equatable, Sendable {
    public let identifier: String
    public let isActive: Bool
    public let expiresAt: String?

    public init(identifier: String, isActive: Bool, expiresAt: String?) {
        self.identifier = identifier
        self.isActive = isActive
        self.expiresAt = expiresAt
    }
}

/// Status of the user's active subscription, mirroring the RN SDK string union.
public enum SubscriptionStatus: String, Codable, Equatable, Sendable {
    case active
    case expired
    case cancelled
    case pending
}

/// Detail about the user's currently-active subscription, if any.
public struct SubscriptionInfo: Codable, Equatable, Sendable {
    public let status: SubscriptionStatus
    public let store: String
    public let productId: String
    public let expiresAt: String?
    public let startsAt: String?
    public let cancelledAt: String?
    public let willRenew: Bool
    public let isGracePeriod: Bool
    /// When the store first failed to charge the renewal (billing retry / grace), or nil.
    public let billingIssueDetectedAt: String?
    /// When the grace period ends, or nil.
    public let gracePeriodExpiresAt: String?
    /// When the customer turned auto-renew off while still subscribed, or nil.
    public let unsubscribeDetectedAt: String?
    /// "trial", "intro" or "normal" when the backend knows it.
    public let periodType: String?

    public init(
        status: SubscriptionStatus,
        store: String,
        productId: String,
        expiresAt: String?,
        startsAt: String?,
        cancelledAt: String?,
        willRenew: Bool,
        isGracePeriod: Bool
    ) {
        self.init(
            status: status, store: store, productId: productId, expiresAt: expiresAt, startsAt: startsAt,
            cancelledAt: cancelledAt, willRenew: willRenew, isGracePeriod: isGracePeriod,
            billingIssueDetectedAt: nil, gracePeriodExpiresAt: nil, unsubscribeDetectedAt: nil, periodType: nil
        )
    }

    @_disfavoredOverload
    public init(
        status: SubscriptionStatus,
        store: String,
        productId: String,
        expiresAt: String?,
        startsAt: String?,
        cancelledAt: String?,
        willRenew: Bool,
        isGracePeriod: Bool,
        billingIssueDetectedAt: String?,
        gracePeriodExpiresAt: String?,
        unsubscribeDetectedAt: String?,
        periodType: String?
    ) {
        self.status = status
        self.store = store
        self.productId = productId
        self.expiresAt = expiresAt
        self.startsAt = startsAt
        self.cancelledAt = cancelledAt
        self.willRenew = willRenew
        self.isGracePeriod = isGracePeriod
        self.billingIssueDetectedAt = billingIssueDetectedAt
        self.gracePeriodExpiresAt = gracePeriodExpiresAt
        self.unsubscribeDetectedAt = unsubscribeDetectedAt
        self.periodType = periodType
    }
}

/// A one-time / consumable purchase the backend recorded for the customer.
public struct NonSubscriptionTransaction: Codable, Equatable, Sendable {
    public let productId: String
    public let transactionId: String
    public let store: String
    public let isConsumable: Bool
    public let purchasedAt: String?
    /// Set when the store refunded it (a refunded non-consumable no longer grants anything).
    public let refundedAt: String?

    public init(productId: String, transactionId: String, store: String, isConsumable: Bool, purchasedAt: String?, refundedAt: String?) {
        self.productId = productId
        self.transactionId = transactionId
        self.store = store
        self.isConsumable = isConsumable
        self.purchasedAt = purchasedAt
        self.refundedAt = refundedAt
    }
}

/// The user's full subscription state. Returned by `Purchases.customerInfo()`.
public struct CustomerInfo: Codable, Equatable, Sendable {
    public let appUserId: String
    public let isPremium: Bool
    public let entitlements: [String: EntitlementInfo]
    public let activeSubscription: SubscriptionInfo?
    /// One-time / consumable purchases (empty for subscription-only apps).
    public let nonSubscriptionTransactions: [NonSubscriptionTransaction]
    /// When the entitlements run out (grants included), or nil when nothing expires / nothing is held.
    public let latestExpirationDate: String?
    /// True when this value was computed on the device because BillingBear could not be reached: a
    /// provisional grant from StoreKit's verified purchases on top of the last server answer. The next
    /// successful fetch replaces it.
    public let isOfflineComputed: Bool

    public init(
        appUserId: String,
        isPremium: Bool,
        entitlements: [String: EntitlementInfo],
        activeSubscription: SubscriptionInfo?
    ) {
        self.init(
            appUserId: appUserId, isPremium: isPremium, entitlements: entitlements, activeSubscription: activeSubscription,
            nonSubscriptionTransactions: [], latestExpirationDate: activeSubscription?.expiresAt, isOfflineComputed: false
        )
    }

    @_disfavoredOverload
    public init(
        appUserId: String,
        isPremium: Bool,
        entitlements: [String: EntitlementInfo],
        activeSubscription: SubscriptionInfo?,
        nonSubscriptionTransactions: [NonSubscriptionTransaction],
        latestExpirationDate: String?,
        isOfflineComputed: Bool
    ) {
        self.appUserId = appUserId
        self.isPremium = isPremium
        self.entitlements = entitlements
        self.activeSubscription = activeSubscription
        self.nonSubscriptionTransactions = nonSubscriptionTransactions
        self.latestExpirationDate = latestExpirationDate
        self.isOfflineComputed = isOfflineComputed
    }

    private enum CodingKeys: String, CodingKey {
        case appUserId, isPremium, entitlements, activeSubscription
        case nonSubscriptionTransactions, latestExpirationDate, isOfflineComputed
    }

    // Tolerant decoding: values written by an older SDK (or a trimmed payload) lack the newer keys.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        appUserId = try c.decode(String.self, forKey: .appUserId)
        isPremium = try c.decode(Bool.self, forKey: .isPremium)
        entitlements = try c.decodeIfPresent([String: EntitlementInfo].self, forKey: .entitlements) ?? [:]
        activeSubscription = try c.decodeIfPresent(SubscriptionInfo.self, forKey: .activeSubscription)
        nonSubscriptionTransactions = try c.decodeIfPresent([NonSubscriptionTransaction].self, forKey: .nonSubscriptionTransactions) ?? []
        latestExpirationDate = try c.decodeIfPresent(String.self, forKey: .latestExpirationDate)
        isOfflineComputed = try c.decodeIfPresent(Bool.self, forKey: .isOfflineComputed) ?? false
    }

    /// The store's subscription-management page for the active subscription's store, or nil for web
    /// (Stripe/Paddle) and no-subscription states.
    public var managementURL: URL? {
        switch activeSubscription?.store {
        case "apple": return URL(string: "https://apps.apple.com/account/subscriptions")
        case "google": return URL(string: "https://play.google.com/store/account/subscriptions")
        case "amazon": return URL(string: "https://www.amazon.com/gp/css/order-history")
        case "huawei": return URL(string: "https://subscription.cloud.huawei.com")
        default: return nil
        }
    }

    func replacing(isPremium: Bool, entitlements: [String: EntitlementInfo], isOfflineComputed: Bool) -> CustomerInfo {
        CustomerInfo(
            appUserId: appUserId,
            isPremium: isPremium,
            entitlements: entitlements,
            activeSubscription: activeSubscription,
            nonSubscriptionTransactions: nonSubscriptionTransactions,
            latestExpirationDate: latestExpirationDate,
            isOfflineComputed: isOfflineComputed
        )
    }

    func replacing(latestExpirationDate: String?) -> CustomerInfo {
        CustomerInfo(
            appUserId: appUserId,
            isPremium: isPremium,
            entitlements: entitlements,
            activeSubscription: activeSubscription,
            nonSubscriptionTransactions: nonSubscriptionTransactions,
            latestExpirationDate: latestExpirationDate,
            isOfflineComputed: isOfflineComputed
        )
    }

    static func empty(appUserId: String) -> CustomerInfo {
        CustomerInfo(appUserId: appUserId, isPremium: false, entitlements: [:], activeSubscription: nil)
    }
}

/// How `customerInfo(fetchPolicy:)` balances the cache against the network (RevenueCat's
/// `CacheFetchPolicy`, with the React Native SDK's semantics).
public enum CacheFetchPolicy: Sendable, Equatable {
    /// Never touch the network: the cached value for this subscriber, even stale, or an empty one.
    case fromCacheOnly
    /// Always ask the backend.
    case fetchCurrent
    /// The cache while it is fresh (`PurchasesOptions.customerInfoCacheTTL`), else the backend.
    case cachedOrFetched
    /// Same as `cachedOrFetched`, spelled out for callers that want to be explicit about staleness.
    case notStaleCachedOrFetched
}

/// Purchase-core settings. Every field has a default, so `PurchasesOptions()` is the normal setup.
public struct PurchasesOptions: Sendable {
    /// Finish StoreKit transactions once BillingBear validated them (default). Set false in observer
    /// mode, when your own StoreKit code finishes them; the SDK still syncs every transaction.
    public var finishTransactions: Bool
    /// How long a customer info stays fresh for `cachedOrFetched`. Default 5 minutes.
    public var customerInfoCacheTTL: TimeInterval
    /// How old the last server answer may be and still be served when BillingBear is unreachable.
    /// Default 24 hours (the React Native SDK's disk-cache window). 0 disables the cached fallback.
    public var offlineEntitlementsWindow: TimeInterval
    /// The entitlement an active on-device purchase grants while BillingBear is unreachable (the RN
    /// SDK's default "premium"). nil disables the StoreKit-computed offline grant.
    public var offlineEntitlement: String?
    /// Optional override: sign promotional offers on your own backend instead of BillingBear (which signs
    /// them with the project's App Store In-App Purchase key by default).
    public var promotionalOfferSigner: (any PromotionalOfferSigner)?
    /// End-user tokens for per-subscriber calls (Customer Center, virtual-currency spends, promotional
    /// offers). Required when the project has "require end-user token" on.
    public var endUserTokenProvider: EndUserTokenProvider?

    public init(
        finishTransactions: Bool = true,
        customerInfoCacheTTL: TimeInterval = 300,
        offlineEntitlementsWindow: TimeInterval = 86_400,
        offlineEntitlement: String? = "premium",
        promotionalOfferSigner: (any PromotionalOfferSigner)? = nil,
        endUserTokenProvider: EndUserTokenProvider? = nil
    ) {
        self.finishTransactions = finishTransactions
        self.customerInfoCacheTTL = customerInfoCacheTTL
        self.offlineEntitlementsWindow = offlineEntitlementsWindow
        self.offlineEntitlement = offlineEntitlement
        self.promotionalOfferSigner = promotionalOfferSigner
        self.endUserTokenProvider = endUserTokenProvider
    }
}

// MARK: - Products / Offerings

/// A purchasable product. Price metadata is populated from StoreKit where available.
public struct Product: Codable, Equatable, Sendable {
    public let productId: String
    public let title: String
    public let description: String
    public let price: Double
    public let currency: String
    public let localizedPrice: String
    public let offerToken: String?
    public let period: String?

    public init(
        productId: String,
        title: String,
        description: String,
        price: Double,
        currency: String,
        localizedPrice: String,
        offerToken: String? = nil,
        period: String? = nil
    ) {
        self.productId = productId
        self.title = title
        self.description = description
        self.price = price
        self.currency = currency
        self.localizedPrice = localizedPrice
        self.offerToken = offerToken
        self.period = period
    }
}

/// A named package wrapping a single `Product`.
public struct Package: Codable, Equatable, Sendable {
    public let identifier: String
    public let product: Product

    public init(identifier: String, product: Product) {
        self.identifier = identifier
        self.product = product
    }
}

/// A collection of packages, with monthly/yearly/weekly conveniences, mirroring the RN SDK.
public struct Offering: Codable, Equatable, Sendable {
    public let identifier: String
    public let availablePackages: [Package]
    public let monthly: Package?
    public let yearly: Package?
    public let weekly: Package?

    public init(
        identifier: String,
        availablePackages: [Package],
        monthly: Package? = nil,
        yearly: Package? = nil,
        weekly: Package? = nil
    ) {
        self.identifier = identifier
        self.availablePackages = availablePackages
        self.monthly = monthly
        self.yearly = yearly
        self.weekly = weekly
    }
}

// MARK: - Offerings (backend-configured)

/// One per-provider product reference inside a configured package.
public struct RemoteOfferingProduct: Codable, Equatable, Sendable {
    /// Store provider: "apple" | "google" | "stripe" | "paddle".
    public let provider: String
    /// The provider-specific product / SKU identifier.
    public let productId: String

    public init(provider: String, productId: String) {
        self.provider = provider
        self.productId = productId
    }
}

/// A package within a configured offering — maps a stable handle to per-provider products.
public struct RemoteOfferingPackage: Codable, Equatable, Sendable {
    public let identifier: String
    public let displayName: String
    public let description: String?
    public let displayOrder: Int
    public let products: [RemoteOfferingProduct]

    public init(identifier: String, displayName: String, description: String?, displayOrder: Int, products: [RemoteOfferingProduct]) {
        self.identifier = identifier
        self.displayName = displayName
        self.description = description
        self.displayOrder = displayOrder
        self.products = products
    }
}

/// A configured offering served by the BillingBear dashboard.
public struct RemoteOffering: Codable, Equatable, Sendable {
    public let identifier: String
    public let displayName: String
    public let description: String?
    /// True for the offering resolved as "current" for this subscriber (targeting + default).
    public let isCurrent: Bool
    public let packages: [RemoteOfferingPackage]
    /// Paywall attached to this offering to render, if any.
    public let paywall: PaywallResponse?

    public init(identifier: String, displayName: String, description: String?, isCurrent: Bool, packages: [RemoteOfferingPackage], paywall: PaywallResponse?) {
        self.identifier = identifier
        self.displayName = displayName
        self.description = description
        self.isCurrent = isCurrent
        self.packages = packages
        self.paywall = paywall
    }
}

/// Container returned by `getOfferings()` — the RevenueCat `getOfferings()` equivalent.
public struct Offerings: Codable, Equatable, Sendable {
    /// Identifier of the current offering (server-resolved via targeting), or nil.
    public let currentOfferingId: String?
    /// All active offerings for the project.
    public let offerings: [RemoteOffering]

    public init(currentOfferingId: String?, offerings: [RemoteOffering]) {
        self.currentOfferingId = currentOfferingId
        self.offerings = offerings
    }
}

// MARK: - Virtual Currencies

/// A single virtual-currency balance held by a subscriber, mirroring the RN/web SDK
/// `VirtualCurrencyBalance`. Served by GET /v1/subscribers/{appUserId}/virtual-currencies.
public struct VirtualCurrencyBalance: Codable, Equatable, Sendable {
    /// Short code identifying the currency (e.g. "GOLD", "COINS").
    public let code: String
    /// Human-readable display name (e.g. "Gold Coins").
    public let name: String
    /// Current balance for this currency.
    public let balance: Double

    public init(code: String, name: String, balance: Double) {
        self.code = code
        self.name = name
        self.balance = balance
    }
}

// MARK: - Checkout

/// Request body for POST /v1/checkout/session (appUserId is injected by the SDK).
public struct CheckoutSessionRequest: Codable, Equatable, Sendable {
    public let priceId: String
    public let successUrl: String
    public let cancelUrl: String
    public let metadata: [String: String]?

    public init(
        priceId: String,
        successUrl: String,
        cancelUrl: String,
        metadata: [String: String]? = nil
    ) {
        self.priceId = priceId
        self.successUrl = successUrl
        self.cancelUrl = cancelUrl
        self.metadata = metadata
    }
}

/// Response from POST /v1/checkout/session.
public struct CheckoutSession: Codable, Equatable, Sendable {
    public let url: String
    public let sessionId: String

    public init(url: String, sessionId: String) {
        self.url = url
        self.sessionId = sessionId
    }
}
