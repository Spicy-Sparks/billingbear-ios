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
        self.status = status
        self.store = store
        self.productId = productId
        self.expiresAt = expiresAt
        self.startsAt = startsAt
        self.cancelledAt = cancelledAt
        self.willRenew = willRenew
        self.isGracePeriod = isGracePeriod
    }
}

/// The user's full subscription state. Returned by `Purchases.customerInfo()`.
public struct CustomerInfo: Codable, Equatable, Sendable {
    public let appUserId: String
    public let isPremium: Bool
    public let entitlements: [String: EntitlementInfo]
    public let activeSubscription: SubscriptionInfo?

    public init(
        appUserId: String,
        isPremium: Bool,
        entitlements: [String: EntitlementInfo],
        activeSubscription: SubscriptionInfo?
    ) {
        self.appUserId = appUserId
        self.isPremium = isPremium
        self.entitlements = entitlements
        self.activeSubscription = activeSubscription
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
