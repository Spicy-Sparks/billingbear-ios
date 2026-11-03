import XCTest
@testable import BillingBear

/// The one-time purchase contract of POST /v1/subscribers/{id}/non-subscription: `claimOrphanOnly`
/// per call site, the `revoked` / `refundedAt` / `transferred` / `keptByOriginalOwner` answer, and
/// what the SDK does with it (finish on any 200, re-read the entitlements, expose the record).
final class NonSubscriptionContractTests: XCTestCase {

    private static let path = "/v1/subscribers/u1/non-subscription"

    private static func record(
        _ transactionId: String,
        product: String = "com.app.lifetime",
        consumable: Bool = false,
        granted: Bool = false,
        already: Bool = false,
        extra: String = ""
    ) -> String {
        #"{"productId":"\#(product)","transactionId":"\#(transactionId)","isConsumable":\#(consumable),"entitlementGranted":\#(granted),"alreadyRecorded":\#(already)\#(extra)}"#
    }

    /// Answers the record with `answer`, and entitlements as `premium()` says.
    private func harness(
        answer: @escaping (RecordedRequest) -> MockReply = { _ in .json(200, NonSubscriptionContractTests.record("t")) },
        premium: @escaping () -> Bool = { false }
    ) async -> Harness {
        await Harness.make { request, count in
            if request.method == "POST" && request.path == Self.path { return answer(request) }
            if request.path.hasPrefix("/subscription/entitlements/") { return .json(200, Fixture.entitlements(premium: premium())) }
            return Harness.defaultResponder()(request, count)
        }
    }

    // MARK: Decoding

    func testTheRecordCarriesTheStoresVerdict() throws {
        let json = Self.record("t1", extra: #","revoked":true,"refundedAt":"2026-11-01T10:00:00Z","transferred":false,"keptByOriginalOwner":true"#)
        let decoded = try JSONDecoder().decode(NonSubscriptionPurchaseResult.self, from: Data(json.utf8))
        XCTAssertEqual(decoded, NonSubscriptionPurchaseResult(
            productId: "com.app.lifetime", transactionId: "t1", isConsumable: false, entitlementGranted: false,
            alreadyRecorded: false, revoked: true, refundedAt: "2026-11-01T10:00:00Z", transferred: false, keptByOriginalOwner: true))

        let withdrawn = try JSONDecoder().decode(NonSubscriptionPurchaseResult.self, from: Data(
            Self.record("t2", extra: #","revoked":true,"refundedAt":null"#).utf8))
        XCTAssertTrue(withdrawn.revoked)
        XCTAssertNil(withdrawn.refundedAt, "a Family Sharing withdrawal refunds nobody")
    }

    func testAnOlderServersRecordDecodesWithTheNewFieldsOff() throws {
        let decoded = try JSONDecoder().decode(NonSubscriptionPurchaseResult.self, from: Data(Fixture.nonSubscriptionRecorded.utf8))
        XCTAssertFalse(decoded.revoked)
        XCTAssertNil(decoded.refundedAt)
        XCTAssertFalse(decoded.transferred)
        XCTAssertFalse(decoded.keptByOriginalOwner)

        let odd = try JSONDecoder().decode(NonSubscriptionPurchaseResult.self, from: Data(
            Self.record("t3", extra: #","revoked":"yes","refundedAt":12,"transferred":null"#).utf8))
        XCTAssertFalse(odd.revoked, "an unexpected shape never fails a purchase the server accepted")
        XCTAssertNil(odd.refundedAt)
    }

    // MARK: claimOrphanOnly per call site

    func testAPurchaseMayMoveAPurchaseAnotherSubscriberHolds() async throws {
        let h = await harness(answer: { _ in .json(200, Self.record("tx-buy", granted: true, extra: #","transferred":true"#)) })
        h.store.setPurchaseHandler { productId, _ in
            .success(.verified(Fixture.transaction("tx-buy", product: productId, type: .nonConsumable)))
        }

        let result = try await h.purchases.purchase(productId: "com.app.lifetime")

        let body = try XCTUnwrap(h.http.requests("POST", Self.path).first?.body)
        XCTAssertEqual(body["claimOrphanOnly"] as? Bool, false)
        XCTAssertEqual(result.nonSubscriptionRecord?.transferred, true)
        XCTAssertEqual(result.nonSubscriptionRecord?.transactionId, "tx-buy")
    }

    func testTransactionUpdatesAreASilentSync() async throws {
        let h = await harness()
        h.store.emit(.verified(Fixture.transaction("tx-update", product: "com.app.coins", type: .consumable)))

        await eventually { h.store.finishedIds == ["tx-update"] }
        XCTAssertEqual(h.http.requests("POST", Self.path).first?.body?["claimOrphanOnly"] as? Bool, true)
    }

    func testTheUnfinishedReplayIsASilentSync() async throws {
        let store = Fixture.transaction("tx-unfinished", product: "com.app.lifetime", type: .nonConsumable)
        let h = await harness()
        h.store.setUnfinished([.verified(store)])
        await h.purchases.replayUnfinishedTransactions()

        await eventually { h.store.finishedIds.contains("tx-unfinished") }
        let bodies = h.http.requests("POST", Self.path).compactMap { $0.body }
        XCTAssertFalse(bodies.isEmpty)
        XCTAssertTrue(bodies.allSatisfy { $0["claimOrphanOnly"] as? Bool == true })
    }

    func testABackgroundRetryOfAPurchaseIsASilentSync() async throws {
        // The purchase's own attempt fails for the network (four tries inside one call); the retry the
        // SDK schedules afterwards runs with nobody waiting for it.
        let attempts = Counter()
        let h = await harness(answer: { _ in
            attempts.increment() <= 4 ? .networkError : .json(200, Self.record("tx-retry"))
        })
        h.store.setPurchaseHandler { productId, _ in
            .success(.verified(Fixture.transaction("tx-retry", product: productId, type: .nonConsumable)))
        }
        do {
            _ = try await h.purchases.purchase(productId: "com.app.lifetime")
            XCTFail("expected a network error")
        } catch let error as PurchasesError {
            XCTAssertEqual(error.code, .networkError)
        }

        await eventually(timeout: 5) { h.store.finishedIds == ["tx-retry"] }
        let flags = h.http.requests("POST", Self.path).map { $0.body?["claimOrphanOnly"] as? Bool }
        XCTAssertEqual(flags.count, 5)
        XCTAssertEqual(Array(flags.prefix(4)), [false, false, false, false], "the purchase itself is explicit")
        XCTAssertEqual(flags.last, true, "the background retry is not")
    }

    func testRestoreIsExplicitAndSyncPurchasesIsSilent() async throws {
        let h = await harness()
        h.store.setEntitlements([
            Fixture.transaction("tx-sub"),
            Fixture.transaction("tx-lifetime", product: "com.app.lifetime", type: .nonConsumable),
        ])

        _ = try await h.purchases.restore()
        let restoreRecord = try XCTUnwrap(h.http.requests("POST", Self.path).last?.body)
        let restoreSub = try XCTUnwrap(h.http.requests("POST", "/subscription/restore").last?.body)
        XCTAssertEqual(restoreRecord["claimOrphanOnly"] as? Bool, false)
        XCTAssertNil(restoreSub["claimOrphanOnly"], "an explicit subscription restore follows the transfer policy, as always")

        _ = try await h.purchases.syncPurchases()
        let syncRecord = try XCTUnwrap(h.http.requests("POST", Self.path).last?.body)
        let syncSub = try XCTUnwrap(h.http.requests("POST", "/subscription/restore").last?.body)
        XCTAssertEqual(syncRecord["claimOrphanOnly"] as? Bool, true)
        XCTAssertEqual(syncSub["claimOrphanOnly"] as? Bool, true, "a silent sync never takes a subscription from its owner")
        XCTAssertEqual(h.http.requests("POST", Self.path).count, 2)
    }

    func testAConfirmNeverCarriesTheRestoreFlag() async throws {
        let h = await harness()
        h.store.emit(.verified(Fixture.transaction("tx-renewal")))
        await eventually { h.store.finishedIds == ["tx-renewal"] }
        let confirm = try XCTUnwrap(h.http.requests("POST", "/subscription/confirm").first?.body)
        XCTAssertNil(confirm["claimOrphanOnly"])
    }

    // MARK: revoked

    func testARevokedAnswerIsFinishedAndTheEntitlementsAreReadAgain() async throws {
        let granted = LockedFlag()
        granted.set()
        let h = await harness(
            answer: { _ in
                // The store took the purchase back: its grant is gone on the server.
                granted.reset()
                return .json(200, Self.record("tx-refunded", already: true, extra: #","revoked":true,"refundedAt":"2026-11-01T10:00:00Z""#))
            },
            premium: { granted.isSet })
        // A premium answer is cached before the purchase.
        let before = try await h.purchases.customerInfo(fetchPolicy: .fetchCurrent)
        XCTAssertTrue(before.isPremium)
        let readsBefore = h.http.requests.filter { $0.path.hasPrefix("/subscription/entitlements/") }.count
        h.store.setPurchaseHandler { productId, _ in
            .success(.verified(Fixture.transaction("tx-refunded", product: productId, type: .nonConsumable)))
        }

        let result = try await h.purchases.purchase(productId: "com.app.lifetime")

        XCTAssertEqual(h.store.finishedIds, ["tx-refunded"], "finished on the 200, whatever the flags say")
        XCTAssertEqual(result.nonSubscriptionRecord?.revoked, true)
        XCTAssertEqual(result.nonSubscriptionRecord?.refundedAt, "2026-11-01T10:00:00Z")
        XCTAssertFalse(result.customerInfo.isPremium)
        XCTAssertGreaterThan(h.http.requests.filter { $0.path.hasPrefix("/subscription/entitlements/") }.count, readsBefore)
        let cached = try await h.purchases.customerInfo(fetchPolicy: .fromCacheOnly)
        XCTAssertFalse(cached.isPremium, "the cached premium state was replaced")
    }

    func testARevokedAnswerToABackgroundSyncIsFinishedAndPublished() async throws {
        let h = await harness(answer: { _ in
            .json(200, Self.record("tx-bg-revoked", consumable: true, extra: #","revoked":true"#))
        })
        let delegate = await MainActor.run { RecordingDelegate() }
        h.purchases.delegate = delegate
        h.store.emit(.verified(Fixture.transaction("tx-bg-revoked", product: "com.app.coins", type: .consumable)))

        await eventually { h.store.finishedIds == ["tx-bg-revoked"] }
        await eventually { await MainActor.run { delegate.synced == ["tx-bg-revoked"] } }
        let failures = await MainActor.run { delegate.failures.count }
        XCTAssertEqual(failures, 0, "a revoked purchase is an answer, not a failure")
        XCTAssertGreaterThanOrEqual(h.http.requests.filter { $0.path.hasPrefix("/subscription/entitlements/") }.count, 1)
        withExtendedLifetime(delegate) {}
    }

    func testAKeptByItsOwnerAnswerIsStillASettledPurchase() async throws {
        let h = await harness(answer: { _ in .json(200, Self.record("tx-kept", already: true, extra: #","keptByOriginalOwner":true"#)) })
        h.store.setPurchaseHandler { productId, _ in
            .success(.verified(Fixture.transaction("tx-kept", product: productId, type: .nonConsumable)))
        }
        let result = try await h.purchases.purchase(productId: "com.app.lifetime")
        XCTAssertEqual(result.nonSubscriptionRecord?.keptByOriginalOwner, true)
        XCTAssertEqual(h.store.finishedIds, ["tx-kept"])
    }

    func testASubscriptionPurchaseHasNoOneTimeRecord() async throws {
        let h = await Harness.make()
        h.store.setPurchaseHandler { productId, _ in .success(.verified(Fixture.transaction("tx-sub-buy", product: productId))) }
        let result = try await h.purchases.purchase(productId: "com.app.monthly")
        XCTAssertNil(result.nonSubscriptionRecord)
    }

    // MARK: Refunds BillingBear has not seen

    private static func entitlementsWithRecord(_ transactionId: String, premium: Bool, refundedAt: String? = nil) -> String {
        let refunded = refundedAt.map { "\"\($0)\"" } ?? "null"
        return """
        {"userId":null,"isPremium":\(premium),"entitlements":\(premium ? #"["premium"]"# : "[]"),"subscription":null,
         "nonSubscriptionTransactions":[{"productId":"com.app.lifetime","transactionId":"\(transactionId)","store":2,
           "isConsumable":false,"purchasedAt":"2026-10-01T00:00:00Z","refundedAt":\(refunded)}]}
        """
    }

    func testARefundBillingBearMissedIsTakenBackByTheRepostAndFinished() async throws {
        let takenBack = LockedFlag()
        let h = await Harness.make { request, _ in
            if request.path == Self.path {
                takenBack.set()
                return .json(200, Self.record("tx-missed", already: true, extra: #","revoked":true,"refundedAt":"2026-11-02T00:00:00Z""#))
            }
            return .json(200, Self.entitlementsWithRecord("tx-missed", premium: !takenBack.isSet,
                                                          refundedAt: takenBack.isSet ? "2026-11-02T00:00:00Z" : nil))
        }
        h.store.emit(.verified(Fixture.transaction("tx-missed", product: "com.app.lifetime", type: .nonConsumable, revoked: true)))

        await eventually { h.store.finishedIds == ["tx-missed"] }
        let posts = h.http.requests("POST", Self.path)
        XCTAssertEqual(posts.count, 1, "no App Store notification needed: BillingBear asked Apple and took it back")
        XCTAssertEqual(posts.first?.body?["claimOrphanOnly"] as? Bool, true)
        let info = try await h.purchases.customerInfo(fetchPolicy: .fromCacheOnly)
        XCTAssertFalse(info.isPremium, "the entitlements were read again after the revoked answer")
    }

    func testARevokedTransactionBillingBearNeverRecordedIsNotPosted() async throws {
        // An older server would record (and grant) a purchase it never saw: only recorded ones are re-posted.
        let h = await Harness.make { request, _ in
            request.path == Self.path
                ? .json(200, Self.record("tx-unknown"))
                : .json(200, Fixture.entitlements(premium: false))
        }
        h.store.emit(.verified(Fixture.transaction("tx-unknown", product: "com.app.lifetime", type: .nonConsumable, revoked: true)))
        await eventually { h.store.finishedIds == ["tx-unknown"] }
        XCTAssertTrue(h.http.requests("POST", Self.path).isEmpty)
    }

    // MARK: A 200 settles the transaction

    func testAPurchaseBillingBearAcceptedIsFinishedEvenWhenTheReadAfterItFails() async throws {
        let recorded = LockedFlag()
        let readsWork = LockedFlag()
        readsWork.set()
        let h = await Harness.make { request, _ in
            if request.path == Self.path {
                recorded.set()
                readsWork.reset()
                return .json(200, Self.record("tx-paid", granted: true))
            }
            guard readsWork.isSet else { return .networkError }
            return .json(200, Fixture.entitlements(premium: recorded.isSet))
        }
        _ = try await h.purchases.customerInfo(fetchPolicy: .fetchCurrent)
        h.store.setPurchaseHandler { productId, _ in
            .success(.verified(Fixture.transaction("tx-paid", product: productId, type: .nonConsumable)))
        }

        let result = try await h.purchases.purchase(productId: "com.app.lifetime")

        XCTAssertEqual(h.store.finishedIds, ["tx-paid"], "BillingBear has the purchase: finished although the read failed")
        XCTAssertEqual(result.nonSubscriptionRecord?.entitlementGranted, true)
        XCTAssertEqual(PaywallPurchaseOutcome(purchase: result), .completed)
        XCTAssertEqual(h.http.requests("POST", Self.path).count, 1)

        // The cached state predates the purchase: the next ordinary read asks BillingBear.
        readsWork.set()
        let info = try await h.purchases.customerInfo()
        XCTAssertTrue(info.isPremium)
    }

    func testARestoreFinishesTheOneTimePurchasesBillingBearAccepted() async throws {
        let h = await harness()
        h.store.setUnfinished([.verified(Fixture.transaction("tx-restored", product: "com.app.lifetime", type: .nonConsumable))])
        h.store.setEntitlements([Fixture.transaction("tx-restored", product: "com.app.lifetime", type: .nonConsumable)])
        _ = try await h.purchases.restore()
        await eventually { h.store.finishedIds.contains("tx-restored") }
    }

    func testARestoreWhoseFinalReadFailsLeavesTheCacheOutdated() async throws {
        let readsWork = LockedFlag()
        readsWork.set()
        let recorded = LockedFlag()
        let h = await Harness.make { request, _ in
            if request.path == Self.path {
                recorded.set()
                readsWork.reset()
                return .json(200, Self.record("tx-restore-read", granted: true))
            }
            guard readsWork.isSet else { return .networkError }
            return .json(200, Fixture.entitlements(premium: recorded.isSet))
        }
        let before = try await h.purchases.customerInfo(fetchPolicy: .fetchCurrent)
        XCTAssertFalse(before.isPremium)
        h.store.setEntitlements([Fixture.transaction("tx-restore-read", product: "com.app.lifetime", type: .nonConsumable)])

        do {
            _ = try await h.purchases.restore()
            XCTFail("the final read failed")
        } catch let error as PurchasesError {
            XCTAssertEqual(error.code, .networkError)
        }

        readsWork.set()
        let after = try await h.purchases.customerInfo()
        XCTAssertTrue(after.isPremium, "the restore reached BillingBear: the cached free state is not fresh any more")
    }

    func testAPurchaseWhoseRefundWasAlreadySeenIsNotReportedAsASuccess() async throws {
        let h = await harness(answer: { _ in .json(200, Self.record("tx-gone", granted: true)) })
        // The refund reaches the app first (BillingBear never recorded the purchase for this
        // subscriber, so there is nothing to post): then StoreKit answers purchase() with the same
        // transaction, unrevoked.
        h.store.emit(.verified(Fixture.transaction("tx-gone", product: "com.app.lifetime", type: .nonConsumable, revoked: true)))
        await eventually { h.store.finishedIds == ["tx-gone"] }
        h.store.setPurchaseHandler { productId, _ in
            .success(.verified(Fixture.transaction("tx-gone", product: productId, type: .nonConsumable)))
        }

        do {
            _ = try await h.purchases.purchase(productId: "com.app.lifetime")
            XCTFail("a refunded purchase is not a success")
        } catch let error as PurchasesError {
            XCTAssertEqual(error.code, .storeError)
        }
        XCTAssertTrue(h.http.requests("POST", Self.path).isEmpty, "the older, unrevoked snapshot is never recorded")
    }

    // MARK: An explicit purchase after a silent sync

    /// Silent records are kept by another subscriber; explicit ones transfer.
    private func ownershipHarness() async -> Harness {
        await harness(answer: { request in
            request.body?["claimOrphanOnly"] as? Bool == false
                ? .json(200, Self.record("tx-owned", granted: true, already: true, extra: #","transferred":true"#))
                : .json(200, Self.record("tx-owned", already: true, extra: #","keptByOriginalOwner":true"#))
        })
    }

    func testBuyingWhatASilentSyncLeftWithItsOwnerRecordsItAgainExplicitly() async throws {
        let h = await ownershipHarness()
        let owned = Fixture.transaction("tx-owned", product: "com.app.lifetime", type: .nonConsumable)
        h.store.emit(.verified(owned))
        await eventually { h.store.finishedIds == ["tx-owned"] }
        h.store.setPurchaseHandler { _, _ in .success(.verified(owned)) }

        let bought = try await h.purchases.purchase(productId: "com.app.lifetime")

        XCTAssertEqual(h.http.requests("POST", Self.path).map { $0.body?["claimOrphanOnly"] as? Bool }, [true, false])
        XCTAssertEqual(bought.nonSubscriptionRecord?.transferred, true, "the customer's purchase follows the transfer policy")

        // Bought explicitly once: a second purchase() answers from that record.
        let again = try await h.purchases.purchase(productId: "com.app.lifetime")
        XCTAssertEqual(h.http.requests("POST", Self.path).count, 2)
        XCTAssertEqual(again.nonSubscriptionRecord?.transferred, true, "the completed revision keeps its record")
    }

    func testAPurchaseJoiningASilentSyncThatLeftItWithItsOwnerRecordsItAgainExplicitly() async throws {
        let h = await ownershipHarness()
        h.http.delay { request, _ in
            request.path == Self.path && request.body?["claimOrphanOnly"] as? Bool == true ? 300_000_000 : 0
        }
        let owned = Fixture.transaction("tx-owned", product: "com.app.lifetime", type: .nonConsumable)
        h.store.emit(.verified(owned))
        await eventually { h.http.requests("POST", Self.path).count == 1 }
        h.store.setPurchaseHandler { _, _ in .success(.verified(owned)) }

        let bought = try await h.purchases.purchase(productId: "com.app.lifetime")

        XCTAssertEqual(h.http.requests("POST", Self.path).map { $0.body?["claimOrphanOnly"] as? Bool }, [true, false])
        XCTAssertEqual(bought.nonSubscriptionRecord?.transferred, true)
    }

    func testASilentSyncThatAlreadyCreditedThisCustomerAnswersThePurchase() async throws {
        let h = await harness(answer: { _ in .json(200, Self.record("tx-mine", granted: true)) })
        let mine = Fixture.transaction("tx-mine", product: "com.app.lifetime", type: .nonConsumable)
        h.store.emit(.verified(mine))
        await eventually { h.store.finishedIds == ["tx-mine"] }
        h.store.setPurchaseHandler { _, _ in .success(.verified(mine)) }

        let bought = try await h.purchases.purchase(productId: "com.app.lifetime")
        XCTAssertEqual(h.http.requests("POST", Self.path).count, 1, "nothing to move: answered from the silent record")
        XCTAssertEqual(bought.nonSubscriptionRecord?.entitlementGranted, true)
    }

    // MARK: The outcome a paywall host reports

    private func purchaseResult(_ record: NonSubscriptionPurchaseResult?, premium: Bool = false) -> PurchaseResult {
        PurchaseResult(
            customerInfo: CustomerInfo(
                appUserId: "u1", isPremium: premium,
                entitlements: premium ? ["premium": EntitlementInfo(identifier: "premium", isActive: true, expiresAt: nil)] : [:],
                activeSubscription: nil),
            productId: "com.app.lifetime", transactionId: "t", nonSubscriptionRecord: record)
    }

    private func record(
        consumable: Bool = false, granted: Bool = false, revoked: Bool = false, kept: Bool = false
    ) -> NonSubscriptionPurchaseResult {
        NonSubscriptionPurchaseResult(
            productId: "com.app.lifetime", transactionId: "t", isConsumable: consumable, entitlementGranted: granted,
            alreadyRecorded: true, revoked: revoked, keptByOriginalOwner: kept)
    }

    func testAPurchaseThatUnlocksNothingHereIsReportedAsFailed() {
        XCTAssertEqual(PaywallPurchaseOutcome(purchase: purchaseResult(nil, premium: true)), .completed)
        XCTAssertEqual(PaywallPurchaseOutcome(purchase: purchaseResult(record(granted: true))), .completed)
        XCTAssertEqual(PaywallPurchaseOutcome(purchase: purchaseResult(record(revoked: true), premium: true)), .failed,
                       "the store took it back")
        XCTAssertEqual(PaywallPurchaseOutcome(purchase: purchaseResult(record(kept: true))), .failed,
                       "a non-consumable another account keeps, with no access here")
        XCTAssertEqual(PaywallPurchaseOutcome(purchase: purchaseResult(record(kept: true), premium: true)), .failed,
                       "kept by its owner: other access the customer has does not make this purchase theirs")
        XCTAssertEqual(PaywallPurchaseOutcome(purchase: purchaseResult(record(consumable: true, kept: true))), .completed,
                       "a consumable is never restored to anyone: it was still bought here")
    }

    // MARK: Promotional offer 429

    func testTheSignatureEndpointsOwnRateLimitIsANetworkError() async throws {
        let path = "/v1/subscribers/u1/apple/promotional-offer-signature"
        let h = await Harness.make(observe: false) { request, count in
            request.path == path
                ? .json(429, #"{"code":"rate_limited","message":"Too many promotional offer requests","error":{"code":"rate_limited","message":"Too many promotional offer requests"}}"#)
                : Harness.defaultResponder()(request, count)
        }
        do {
            _ = try await h.purchases.getPromotionalOffer(productId: "com.app.yearly", offerId: "comeback50")
            XCTFail("expected a rate limit")
        } catch let error as PurchasesError {
            XCTAssertEqual(error.code, .networkError, "back off and try again, like the gateway's 429")
            XCTAssertEqual(error.statusCode, 429)
            XCTAssertEqual(error.serverCode, BillingBearAPI.PromotionalOfferErrorCode.rateLimited)
        }
        XCTAssertEqual(h.http.requests("POST", path).count, 1, "never retried: the customer is waiting")
    }
}

/// Request counter shared with a responder closure (test-only).
private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func increment() -> Int { lock.lock(); defer { lock.unlock() }; value += 1; return value }
}
