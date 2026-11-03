import Foundation
import StoreKit

#if canImport(UIKit)
import UIKit
#endif

/// `StoreKitClient` on top of StoreKit 2. One shared instance per process, so the transactions it
/// hands out can be finished later from the object StoreKit gave us (no stream re-scan).
final class StoreKit2Client: StoreKitClient, @unchecked Sendable {

    static let shared = StoreKit2Client()

    private let cache = StoreObjectCache()

    // MARK: Transactions

    func transactionUpdates() -> AsyncStream<StoreTransactionResult> {
        AsyncStream { continuation in
            let task = Task.detached { [cache] in
                for await result in StoreKit.Transaction.updates {
                    continuation.yield(await Self.map(result, cache: cache))
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func unfinishedTransactions() async -> [StoreTransactionResult] {
        var results: [StoreTransactionResult] = []
        for await result in StoreKit.Transaction.unfinished {
            results.append(await Self.map(result, cache: cache))
        }
        return results
    }

    func currentEntitlements() async -> [StoreTransaction] {
        var transactions: [StoreTransaction] = []
        for await result in StoreKit.Transaction.currentEntitlements {
            guard case .verified(let transaction) = result, transaction.revocationDate == nil else { continue }
            await cache.store(transaction: transaction)
            // currentEntitlements keeps a subscription in its billing grace period although its paid
            // period has expired: carry the grace end so the SDK sees access until then.
            var grace: Date?
            if let expiration = transaction.expirationDate, expiration <= Date() {
                grace = await Self.gracePeriodExpiration(for: transaction)
            }
            transactions.append(Self.makeTransaction(transaction, jws: result.jwsRepresentation, gracePeriodExpirationDate: grace))
        }
        return transactions
    }

    private static func gracePeriodExpiration(for transaction: StoreKit.Transaction) async -> Date? {
        guard transaction.productType == .autoRenewable,
              let groupID = transaction.subscriptionGroupID,
              let statuses = try? await StoreKit.Product.SubscriptionInfo.status(for: groupID) else { return nil }
        for status in statuses where status.state == .inGracePeriod {
            guard case .verified(let renewal) = status.renewalInfo,
                  renewal.originalTransactionID == transaction.originalID else { continue }
            return renewal.gracePeriodExpirationDate
        }
        return nil
    }

    func latestTransaction(ofSubscription transaction: StoreTransaction) async throws -> StoreTransaction? {
        // The group's statuses carry each subscription's latest transaction, whatever its product. A
        // failure to read them is thrown, never replaced by the product's own latest transaction: after
        // a downgrade that one is the expired period of the previous product.
        if let groupId = transaction.subscriptionGroupId {
            let statuses: [StoreKit.Product.SubscriptionInfo.Status]
            do {
                statuses = try await StoreKit.Product.SubscriptionInfo.status(for: groupId)
            } catch {
                throw Self.mapStoreError(error)
            }
            var newest: (StoreKit.Transaction, String)?
            for status in statuses {
                switch status.transaction {
                case .verified(let candidate):
                    guard String(candidate.originalID) == transaction.originalTransactionId else { continue }
                    if newest == nil || candidate.purchaseDate > newest!.0.purchaseDate {
                        newest = (candidate, status.transaction.jwsRepresentation)
                    }
                case .unverified(let candidate, let error):
                    // This subscription's current state exists but cannot be trusted: fail closed.
                    if String(candidate.originalID) == transaction.originalTransactionId {
                        throw PurchasesError("StoreKit could not verify the subscription's current transaction: \(error.localizedDescription)", code: .storeError)
                    }
                }
            }
            if let (latest, jws) = newest { return Self.makeTransaction(latest, jws: jws) }
        }
        // No group, or the group no longer lists this subscription: the product's own latest transaction.
        guard let result = await StoreKit.Transaction.latest(for: transaction.productId) else { return nil }
        switch result {
        case .verified(let latest):
            return Self.makeTransaction(latest, jws: result.jwsRepresentation)
        case .unverified(_, let error):
            throw PurchasesError("StoreKit could not verify the product's latest transaction: \(error.localizedDescription)", code: .storeError)
        }
    }

    func finish(_ transaction: StoreTransaction) async {
        if let held = await cache.takeTransaction(transaction.transactionId) {
            await held.finish()
            return
        }
        // Not handed out by this process (or already finished): look it up among the unfinished ones.
        // Finishing is idempotent, so a transaction that is already gone is simply done.
        for await result in StoreKit.Transaction.unfinished {
            guard case .verified(let candidate) = result, String(candidate.id) == transaction.transactionId else { continue }
            await candidate.finish()
            return
        }
    }

    // MARK: Purchase

    func purchase(productId: String, product: Any?, options: StorePurchaseOptions) async throws -> StorePurchaseOutcome {
        let resolved = try await resolveProduct(productId, given: product as? StoreKit.Product)

        var purchaseOptions: Set<StoreKit.Product.PurchaseOption> = []
        if let token = options.appAccountToken {
            purchaseOptions.insert(.appAccountToken(token))
        }
        if options.simulatesAskToBuyInSandbox {
            purchaseOptions.insert(.simulatesAskToBuyInSandbox(true))
        }
        if let offer = options.promotionalOffer {
            guard let signature = Data(base64Encoded: offer.signature) else {
                throw PurchasesError("The promotional offer signature is not valid base64", code: .storeError)
            }
            purchaseOptions.insert(.promotionalOffer(
                offerID: offer.offerId,
                keyID: offer.keyIdentifier,
                nonce: offer.nonce,
                signature: signature,
                timestamp: offer.timestamp
            ))
        }
        if let winBackOfferId = options.winBackOfferId {
            guard #available(iOS 18.0, macOS 15.0, *) else {
                throw PurchasesError("Win-back offers require iOS 18", code: .storeError)
            }
            guard let offer = resolved.subscription?.winBackOffers.first(where: { $0.id == winBackOfferId }) else {
                throw PurchasesError("Win-back offer \(winBackOfferId) not found on \(productId)", code: .productNotFound)
            }
            purchaseOptions.insert(.winBackOffer(offer))
        }

        let result: StoreKit.Product.PurchaseResult
        do {
            result = try await resolved.purchase(options: purchaseOptions)
        } catch {
            throw Self.mapStoreError(error)
        }
        switch result {
        case .success(let verification):
            return .success(await Self.map(verification, cache: cache))
        case .userCancelled:
            return .userCancelled
        case .pending:
            return .pending
        @unknown default:
            throw PurchasesError("Unknown purchase result", code: .unknown)
        }
    }

    // MARK: Offers

    func introEligibility(productIds: [String]) async -> [String: IntroEligibilityStatus?] {
        var result: [String: IntroEligibilityStatus?] = [:]
        for id in productIds {
            guard let product = try? await resolveProduct(id, given: nil) else {
                result[id] = .some(nil)
                continue
            }
            guard let subscription = product.subscription else {
                result[id] = .unknown
                continue
            }
            guard subscription.introductoryOffer != nil else {
                result[id] = .noIntroOfferExists
                continue
            }
            result[id] = await subscription.isEligibleForIntroOffer ? .eligible : .ineligible
        }
        return result
    }

    func eligibleWinBackOffers(productId: String) async throws -> [WinBackOffer] {
        guard #available(iOS 18.0, macOS 15.0, *) else { return [] }
        let product = try await resolveProduct(productId, given: nil)
        guard let subscription = product.subscription else { return [] }
        // Eligibility lives on the group's renewal info: Apple lists the win-back offers this
        // customer can redeem, best first.
        var eligibleIds: [String] = []
        for status in try await subscription.status {
            if case .verified(let renewal) = status.renewalInfo {
                for id in renewal.eligibleWinBackOfferIDs where !eligibleIds.contains(id) {
                    eligibleIds.append(id)
                }
            }
        }
        let offers = subscription.winBackOffers
        return eligibleIds.compactMap { id in
            guard let offer = offers.first(where: { $0.id == id }) else { return nil }
            return WinBackOffer(
                id: id,
                displayPrice: offer.displayPrice,
                price: offer.price,
                period: Self.isoPeriod(offer.period),
                periodCount: offer.periodCount,
                paymentMode: Self.paymentMode(offer.paymentMode)
            )
        }
    }

    // MARK: Sheets

    func presentCodeRedemptionSheet() async throws {
        #if os(iOS)
        if #available(iOS 16.0, *) {
            let scene = try await Self.activeScene()
            do {
                try await AppStore.presentOfferCodeRedeemSheet(in: scene)
            } catch {
                throw Self.mapStoreError(error)
            }
        } else {
            await MainActor.run { SKPaymentQueue.default().presentCodeRedemptionSheet() }
        }
        #else
        throw PurchasesError("The offer code redemption sheet is only available on iOS", code: .storeError)
        #endif
    }

    func beginRefundRequest(productId: String) async throws -> RefundRequestStatus {
        #if os(iOS)
        guard let latest = await StoreKit.Transaction.latest(for: productId),
              case .verified(let transaction) = latest else {
            throw PurchasesError("No verified App Store transaction for \(productId)", code: .productNotFound)
        }
        let scene = try await Self.activeScene()
        do {
            return Self.mapRefund(try await transaction.beginRefundRequest(in: scene))
        } catch {
            throw Self.mapStoreError(error)
        }
        #else
        throw PurchasesError("Refund requests are only available on iOS", code: .storeError)
        #endif
    }

    func beginRefundRequest(transactionId: String) async throws -> RefundRequestStatus {
        #if os(iOS)
        guard let id = UInt64(transactionId) else {
            throw PurchasesError("Invalid transaction id \(transactionId)", code: .storeError)
        }
        let scene = try await Self.activeScene()
        do {
            return Self.mapRefund(try await StoreKit.Transaction.beginRefundRequest(for: id, in: scene))
        } catch {
            throw Self.mapStoreError(error)
        }
        #else
        throw PurchasesError("Refund requests are only available on iOS", code: .storeError)
        #endif
    }

    // MARK: Helpers

    private func resolveProduct(_ productId: String, given: StoreKit.Product?) async throws -> StoreKit.Product {
        if let given {
            await cache.store(product: given)
            return given
        }
        if let cached = await cache.product(productId) { return cached }
        let loaded: [StoreKit.Product]
        do {
            loaded = try await StoreKit.Product.products(for: [productId])
        } catch {
            throw Self.mapStoreError(error)
        }
        guard let product = loaded.first else {
            throw PurchasesError("Product \(productId) not found in the App Store", code: .productNotFound)
        }
        await cache.store(product: product)
        return product
    }

    private static func map(
        _ result: VerificationResult<StoreKit.Transaction>,
        cache: StoreObjectCache
    ) async -> StoreTransactionResult {
        switch result {
        case .verified(let transaction):
            await cache.store(transaction: transaction)
            return .verified(makeTransaction(transaction, jws: result.jwsRepresentation))
        case .unverified(let transaction, let error):
            return .unverified(makeTransaction(transaction, jws: result.jwsRepresentation), reason: error.localizedDescription)
        }
    }

    static func makeTransaction(_ transaction: StoreKit.Transaction, jws: String?, gracePeriodExpirationDate: Date? = nil) -> StoreTransaction {
        StoreTransaction(
            transactionId: String(transaction.id),
            originalTransactionId: String(transaction.originalID),
            productId: transaction.productID,
            productType: productType(transaction.productType),
            purchaseDate: transaction.purchaseDate,
            expirationDate: transaction.expirationDate,
            revocationDate: transaction.revocationDate,
            isUpgraded: transaction.isUpgraded,
            appAccountToken: transaction.appAccountToken,
            isFamilyShared: transaction.ownershipType == .familyShared,
            jwsRepresentation: jws,
            gracePeriodExpirationDate: gracePeriodExpirationDate,
            subscriptionGroupId: transaction.subscriptionGroupID
        )
    }

    private static func productType(_ type: StoreKit.Product.ProductType) -> StoreProductType {
        switch type {
        case .autoRenewable: return .autoRenewable
        case .nonRenewable: return .nonRenewable
        case .consumable: return .consumable
        case .nonConsumable: return .nonConsumable
        default: return .unknown
        }
    }

    private static func isoPeriod(_ period: StoreKit.Product.SubscriptionPeriod) -> String {
        switch period.unit {
        case .day: return "P\(period.value)D"
        case .week: return "P\(period.value)W"
        case .month: return "P\(period.value)M"
        case .year: return "P\(period.value)Y"
        @unknown default: return "P\(period.value)D"
        }
    }

    private static func paymentMode(_ mode: StoreKit.Product.SubscriptionOffer.PaymentMode) -> String {
        switch mode {
        case .freeTrial: return "freeTrial"
        case .payAsYouGo: return "payAsYouGo"
        case .payUpFront: return "payUpFront"
        default: return "unknown"
        }
    }

    private static func mapRefund(_ status: StoreKit.Transaction.RefundRequestStatus) -> RefundRequestStatus {
        switch status {
        case .userCancelled: return .userCancelled
        case .success: return .success
        @unknown default: return .success
        }
    }

    static func mapStoreError(_ error: Error) -> PurchasesError {
        if let error = error as? PurchasesError { return error }
        if let storeKitError = error as? StoreKitError {
            switch storeKitError {
            case .userCancelled:
                return PurchasesError("User cancelled the purchase", code: .userCancelled)
            case .networkError:
                return PurchasesError(storeKitError.localizedDescription, code: .networkError)
            default:
                return PurchasesError(storeKitError.localizedDescription, code: .storeError)
            }
        }
        return PurchasesError(error.localizedDescription, code: .storeError)
    }

    #if os(iOS)
    @MainActor
    private static func activeScene() throws -> UIWindowScene {
        let scene = UIApplication.shared.connectedScenes
            .first { $0.activationState == .foregroundActive } as? UIWindowScene
        guard let scene else {
            throw PurchasesError("No active window scene to present the App Store sheet", code: .storeError)
        }
        return scene
    }
    #endif
}

/// Products and transactions StoreKit handed us, kept so a later purchase/finish uses the same object.
private actor StoreObjectCache {
    private var products: [String: StoreKit.Product] = [:]
    private var transactions: [String: StoreKit.Transaction] = [:]

    func store(product: StoreKit.Product) { products[product.id] = product }
    func product(_ id: String) -> StoreKit.Product? { products[id] }

    func store(transaction: StoreKit.Transaction) { transactions[String(transaction.id)] = transaction }
    /// The held transaction, removed: once finished it is never needed again.
    func takeTransaction(_ id: String) -> StoreKit.Transaction? { transactions.removeValue(forKey: id) }
}
