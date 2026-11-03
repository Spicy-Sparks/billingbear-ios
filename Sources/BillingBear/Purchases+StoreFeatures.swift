import Foundation
import StoreKit

// MARK: - Store features: intro eligibility, promotional and win-back offers, offer codes, refunds
//
// RevenueCat's names and shapes (`checkTrialOrIntroDiscountEligibility`, `getPromotionalOffer`,
// `eligibleWinBackOffers`, `presentCodeRedemptionSheet`, `beginRefundRequest`), the React Native
// SDK's behaviour. Anything these flows produce (a redeemed offer code, a purchase with an offer, a
// refund Apple granted) arrives as a transaction and goes through the normal pipeline.

extension Purchases {

    // MARK: Intro eligibility

    /// Introductory offer (free trial / intro price) eligibility per product id.
    ///
    /// StoreKit answers authoritatively whenever it can load the product: it sees an offer redeemed on
    /// another product of the same subscription group. Only when the product cannot be loaded does the
    /// SDK fall back to the RN SDK's subscriber-history hint (the current subscription's product is
    /// ineligible; nothing at all owned means eligible; anything else is unknown). Treat a hint as copy
    /// guidance only; StoreKit decides at purchase time.
    public func checkTrialOrIntroDiscountEligibility(productIdentifiers: [String]) async -> [String: IntroEligibility] {
        guard let store else {
            return Dictionary(productIdentifiers.map { ($0, IntroEligibility(status: .unknown)) }, uniquingKeysWith: { first, _ in first })
        }
        let native = await store.introEligibility(productIds: productIdentifiers)

        var history: CustomerInfo?
        var historyLoaded = false
        var result: [String: IntroEligibility] = [:]
        for id in productIdentifiers {
            if let known = native[id] ?? nil {
                result[id] = IntroEligibility(status: known)
                continue
            }
            if !historyLoaded {
                historyLoaded = true
                history = (try? await customerInfo()) ?? ownCachedCustomerInfo(_appUserId)
            }
            guard let history else {
                result[id] = IntroEligibility(status: .unknown)
                continue
            }
            if let active = history.activeSubscription?.productId, active == id {
                result[id] = IntroEligibility(status: .ineligible)
            } else if !history.isPremium {
                result[id] = IntroEligibility(status: .eligible)
            } else {
                result[id] = IntroEligibility(status: .unknown)
            }
        }
        return result
    }

    /// Introductory offer eligibility for one StoreKit product.
    @available(iOS 15.0, macOS 12.0, *)
    public func checkTrialOrIntroDiscountEligibility(product: StoreKit.Product) async -> IntroEligibilityStatus {
        guard let subscription = product.subscription else { return .unknown }
        guard subscription.introductoryOffer != nil else { return .noIntroOfferExists }
        return await subscription.isEligibleForIntroOffer ? .eligible : .ineligible
    }

    // MARK: Promotional offers

    /// A signed promotional offer for `offerId` (the identifier configured in App Store Connect), ready
    /// for `purchase(product:promotionalOffer:)`.
    ///
    /// BillingBear signs it with the project's App Store In-App Purchase key, for this subscriber's
    /// appAccountToken — the token the purchase carries, which StoreKit checks the signature against.
    /// `PurchasesOptions.promotionalOfferSigner`, when set, signs instead (your own backend). Errors:
    /// `.productNotFound` (offer not configured), `.notConfigured` (the project has no In-App Purchase
    /// key), `.networkError` (offline or rate limited), `.validationError` (rejected request).
    public func getPromotionalOffer(productId: String, offerId: String) async throws -> PromotionalOffer {
        let api = try requireApi()
        let appUserId = _appUserId
        let token = AppAccountToken.token(for: appUserId)
        guard let signer = options.promotionalOfferSigner else {
            return try await api.signPromotionalOffer(
                appUserId: appUserId,
                productId: productId,
                offerId: offerId,
                appAccountToken: token
            )
        }
        let request = PromotionalOfferSigningRequest(
            productId: productId,
            offerId: offerId,
            appUserId: appUserId,
            applicationUsername: token.uuidString.lowercased(),
            bundleId: api.bundleId
        )
        let offer = try await signer.signPromotionalOffer(request)
        guard offer.offerId == offerId, offer.productId.isEmpty || offer.productId == productId else {
            throw PurchasesError("The signer returned an offer for a different product or offer id", code: .validationError)
        }
        return offer
    }

    /// RevenueCat-style overload: sign a promotional `Product.SubscriptionOffer` of `product`.
    @available(iOS 15.0, macOS 12.0, *)
    public func getPromotionalOffer(
        forProductDiscount discount: StoreKit.Product.SubscriptionOffer,
        product: StoreKit.Product
    ) async throws -> PromotionalOffer {
        guard discount.type == .promotional, let offerId = discount.id else {
            throw PurchasesError("Only promotional offers with an identifier can be signed", code: .storeError)
        }
        return try await getPromotionalOffer(productId: product.id, offerId: offerId)
    }

    // MARK: Win-back offers

    /// The win-back offers (iOS 18+) this customer is eligible for on `product`, best first.
    @available(iOS 18.0, macOS 15.0, *)
    public func eligibleWinBackOffers(forProduct product: StoreKit.Product) async throws -> [WinBackOffer] {
        try await eligibleWinBackOffers(forProductId: product.id)
    }

    /// As `eligibleWinBackOffers(forProduct:)`, by product id. Empty before iOS 18.
    public func eligibleWinBackOffers(forProductId productId: String) async throws -> [WinBackOffer] {
        let store = try requireStore()
        return try await store.eligibleWinBackOffers(productId: productId)
    }

    /// Purchase by product id redeeming a win-back offer (iOS 18+).
    @_disfavoredOverload // `purchases.purchase` keeps meaning purchase(product:)
    public func purchase(productId: String, winBackOffer: WinBackOffer) async throws -> PurchaseResult {
        var options = StorePurchaseOptions()
        options.winBackOfferId = winBackOffer.id
        return try await performPurchase(productId: productId, product: nil, options: options)
    }

    /// Purchase by product id redeeming a signed promotional offer.
    @_disfavoredOverload // `purchases.purchase` keeps meaning purchase(product:)
    public func purchase(productId: String, promotionalOffer: PromotionalOffer) async throws -> PurchaseResult {
        try await purchaseRedeeming(productId: productId, product: nil, promotionalOffer: promotionalOffer)
    }

    // MARK: Offer codes

    /// Present the App Store offer-code redemption sheet (iOS). A redeemed code arrives through
    /// `Transaction.updates`, is validated and finished by the SDK, and the new entitlement reaches
    /// `customerInfoStream` and the delegate.
    public func presentCodeRedemptionSheet() async throws {
        try await requireStore().presentCodeRedemptionSheet()
    }

    // MARK: Refunds

    /// Present Apple's refund request sheet for the latest transaction of `productId` (iOS 15+).
    /// Apple decides later; a granted refund arrives as a revoked transaction and removes access.
    public func beginRefundRequest(forProduct productId: String) async throws -> RefundRequestStatus {
        try await requireStore().beginRefundRequest(productId: productId)
    }

    /// Present Apple's refund request sheet for one transaction id (RN SDK parity).
    public func beginRefundRequest(forTransactionId transactionId: String) async throws -> RefundRequestStatus {
        try await requireStore().beginRefundRequest(transactionId: transactionId)
    }
}
