import Foundation

// MARK: - Store-agnostic transaction values
//
// StoreKit's `Transaction` and `Product` have no public initialisers, so the purchase core works on
// these plain values instead. The StoreKit 2 adapter (`StoreKit2Client`) maps every StoreKit object
// into them; unit tests build them directly. Nothing here imports StoreKit.

/// The kind of App Store product a transaction is for. Decides which backend endpoint validates it:
/// subscriptions go to `/subscription/confirm`, one-time products to `/v1/subscribers/{id}/non-subscription`.
public enum StoreProductType: String, Codable, Sendable, Equatable {
    case autoRenewable
    case nonRenewable
    case consumable
    case nonConsumable
    case unknown

    /// True for consumables and non-consumables (the backend's one-time purchase path).
    public var isOneTime: Bool { self == .consumable || self == .nonConsumable }
}

/// A verified-or-not App Store transaction, as the SDK sees it.
public struct StoreTransaction: Sendable, Equatable {
    public let transactionId: String
    public let originalTransactionId: String
    public let productId: String
    public let productType: StoreProductType
    public let purchaseDate: Date
    public let expirationDate: Date?
    /// Set when Apple took the purchase back (refund, Family Sharing removal). A revoked transaction
    /// grants nothing.
    public let revocationDate: Date?
    /// True when the customer moved to a higher tier in the same subscription group: the replacement
    /// transaction carries the entitlement, this one no longer does.
    public let isUpgraded: Bool
    /// The buyer token the purchase was made with (`Product.PurchaseOption.appAccountToken`).
    public let appAccountToken: UUID?
    public let isFamilyShared: Bool
    /// The signed JWS StoreKit verified. Sent to the backend as the receipt (the backend still asks
    /// Apple's App Store Server API for the authoritative transaction).
    public let jwsRepresentation: String?
    /// For a subscription in Apple's billing grace period (the renewal charge failed, access continues):
    /// when the grace period ends. Access runs until then although `expirationDate` has passed.
    public let gracePeriodExpirationDate: Date?
    /// The subscription group of an auto-renewable subscription.
    public let subscriptionGroupId: String?

    public init(
        transactionId: String,
        originalTransactionId: String,
        productId: String,
        productType: StoreProductType,
        purchaseDate: Date,
        expirationDate: Date? = nil,
        revocationDate: Date? = nil,
        isUpgraded: Bool = false,
        appAccountToken: UUID? = nil,
        isFamilyShared: Bool = false,
        jwsRepresentation: String? = nil,
        gracePeriodExpirationDate: Date? = nil,
        subscriptionGroupId: String? = nil
    ) {
        self.transactionId = transactionId
        self.originalTransactionId = originalTransactionId
        self.productId = productId
        self.productType = productType
        self.purchaseDate = purchaseDate
        self.expirationDate = expirationDate
        self.revocationDate = revocationDate
        self.isUpgraded = isUpgraded
        self.appAccountToken = appAccountToken
        self.isFamilyShared = isFamilyShared
        self.jwsRepresentation = jwsRepresentation
        self.gracePeriodExpirationDate = gracePeriodExpirationDate
        self.subscriptionGroupId = subscriptionGroupId
    }

    /// When access really ends: the grace period's end when it is later than the paid period's.
    public var accessExpirationDate: Date? {
        guard let expirationDate else { return nil }
        guard let grace = gracePeriodExpirationDate else { return expirationDate }
        return max(expirationDate, grace)
    }

    /// True while the transaction still grants access at `date`: not revoked, not upgraded away and,
    /// for anything that expires, not yet expired. Consumables never grant lasting access.
    public func grantsAccess(at date: Date) -> Bool {
        guard revocationDate == nil, !isUpgraded, productType != .consumable else { return false }
        if let accessExpirationDate { return accessExpirationDate > date }
        return true
    }
}

/// StoreKit's verification verdict for a transaction.
enum StoreTransactionResult: Sendable, Equatable {
    case verified(StoreTransaction)
    /// StoreKit could not verify the JWS. Never granted, never finished.
    case unverified(StoreTransaction, reason: String)
}

/// Options for one store purchase.
struct StorePurchaseOptions: Sendable, Equatable {
    var appAccountToken: UUID?
    var promotionalOffer: PromotionalOffer?
    var winBackOfferId: String?
    var simulatesAskToBuyInSandbox: Bool = false
}

/// What the store sheet ended with.
enum StorePurchaseOutcome: Sendable, Equatable {
    case success(StoreTransactionResult)
    case userCancelled
    /// Ask to Buy / Strong Customer Authentication: the purchase completes later, through
    /// `Transaction.updates`.
    case pending
}

// MARK: - Public offer / eligibility / refund values

/// Introductory offer (free trial or intro price) eligibility, with RevenueCat's raw values.
public enum IntroEligibilityStatus: Int, Codable, Sendable, Equatable {
    /// Not determinable: the product could not be loaded, or it is not an auto-renewable subscription.
    case unknown = 0
    /// The customer already used an introductory offer in this subscription group.
    case ineligible = 1
    /// The customer can redeem the product's introductory offer.
    case eligible = 2
    /// The product has no introductory offer configured.
    case noIntroOfferExists = 3
}

/// Eligibility for one product, as returned by `checkTrialOrIntroDiscountEligibility`.
public struct IntroEligibility: Sendable, Equatable {
    public let status: IntroEligibilityStatus
    public init(status: IntroEligibilityStatus) { self.status = status }
}

/// An App Store win-back offer (iOS 18+) the customer is eligible for. Pass it back to
/// `purchase(product:winBackOffer:)`; StoreKit stays the final judge at purchase time.
public struct WinBackOffer: Sendable, Equatable, Codable {
    /// The offer identifier configured in App Store Connect.
    public let id: String
    public let displayPrice: String
    public let price: Decimal
    /// ISO 8601 duration of one discounted period, e.g. "P1M".
    public let period: String
    public let periodCount: Int
    /// "freeTrial", "payAsYouGo" or "payUpFront".
    public let paymentMode: String

    public init(id: String, displayPrice: String, price: Decimal, period: String, periodCount: Int, paymentMode: String) {
        self.id = id
        self.displayPrice = displayPrice
        self.price = price
        self.period = period
        self.periodCount = periodCount
        self.paymentMode = paymentMode
    }
}

/// A signed App Store promotional offer, ready to redeem with `purchase(product:promotionalOffer:)`.
public struct PromotionalOffer: Sendable, Equatable, Codable {
    public let offerId: String
    public let productId: String
    public let keyIdentifier: String
    public let nonce: UUID
    /// Base64 signature over Apple's promotional-offer payload.
    public let signature: String
    /// Milliseconds since 1970, as signed.
    public let timestamp: Int

    public init(offerId: String, productId: String, keyIdentifier: String, nonce: UUID, signature: String, timestamp: Int) {
        self.offerId = offerId
        self.productId = productId
        self.keyIdentifier = keyIdentifier
        self.nonce = nonce
        self.signature = signature
        self.timestamp = timestamp
    }
}

/// What a promotional-offer signature has to cover. Apple's payload is
/// `appBundleId ⁣ keyIdentifier ⁣ productId ⁣ offerId ⁣ applicationUsername ⁣ nonce ⁣ timestamp`;
/// with StoreKit 2 the `applicationUsername` must be the purchase's `appAccountToken`, lowercased —
/// which is `applicationUsername` here, NOT the raw `appUserId`.
public struct PromotionalOfferSigningRequest: Sendable, Equatable {
    public let productId: String
    public let offerId: String
    public let appUserId: String
    public let applicationUsername: String
    public let bundleId: String?

    public init(productId: String, offerId: String, appUserId: String, applicationUsername: String, bundleId: String?) {
        self.productId = productId
        self.offerId = offerId
        self.appUserId = appUserId
        self.applicationUsername = applicationUsername
        self.bundleId = bundleId
    }
}

/// Optional override for promotional-offer signing: your backend, holding the App Store In-App Purchase
/// key, signs instead of BillingBear. Set it in `PurchasesOptions.promotionalOfferSigner`; sign
/// `request.applicationUsername` (the purchase's appAccountToken), not the appUserId.
public protocol PromotionalOfferSigner: Sendable {
    func signPromotionalOffer(_ request: PromotionalOfferSigningRequest) async throws -> PromotionalOffer
}

/// Result of an App Store refund request sheet.
public enum RefundRequestStatus: String, Sendable, Equatable {
    /// The request was submitted to Apple (the decision arrives later, as a revoked transaction).
    case success
    case userCancelled
}

// MARK: - Store abstraction

/// The slice of StoreKit the purchase core needs. `StoreKit2Client` implements it on top of
/// StoreKit 2; tests supply a mock.
protocol StoreKitClient: AnyObject, Sendable {
    /// `Transaction.updates`: renewals, Ask-to-Buy approvals, offer codes, refunds and purchases made
    /// on other devices, plus any unfinished transaction at launch.
    func transactionUpdates() -> AsyncStream<StoreTransactionResult>
    /// `Transaction.unfinished`.
    func unfinishedTransactions() async -> [StoreTransactionResult]
    /// Verified `Transaction.currentEntitlements` (revoked ones excluded).
    func currentEntitlements() async -> [StoreTransaction]
    /// The newest verified transaction of `transaction`'s subscription (same original transaction id),
    /// across the products of its group — a crossgrade or downgrade changes the product — revoked or not.
    /// Throws when the group's current state cannot be read: no guess may stand in for it.
    func latestTransaction(ofSubscription transaction: StoreTransaction) async throws -> StoreTransaction?
    /// Run the purchase sheet. `product` is the caller's `StoreKit.Product` when it has one (typed as
    /// `Any` so this protocol stays free of StoreKit types).
    func purchase(productId: String, product: Any?, options: StorePurchaseOptions) async throws -> StorePurchaseOutcome
    /// Finish a transaction (idempotent).
    func finish(_ transaction: StoreTransaction) async
    func introEligibility(productIds: [String]) async -> [String: IntroEligibilityStatus?]
    func eligibleWinBackOffers(productId: String) async throws -> [WinBackOffer]
    func presentCodeRedemptionSheet() async throws
    func beginRefundRequest(productId: String) async throws -> RefundRequestStatus
    func beginRefundRequest(transactionId: String) async throws -> RefundRequestStatus
}
