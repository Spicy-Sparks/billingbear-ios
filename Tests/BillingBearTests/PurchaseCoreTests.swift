import XCTest
@testable import BillingBear

/// The purchase core: Transaction.updates listener, unfinished replay, validation → finish ordering,
/// revocations, upgrades, one-time products, retries, Ask to Buy, reconfigure.
final class PurchaseCoreTests: XCTestCase {

    // MARK: Transaction.updates

    func testUpdateIsValidatedWithTheServerBeforeItIsFinished() async throws {
        let h = await Harness.make()
        h.store.emit(.verified(Fixture.transaction("tx-1")))

        await eventually { h.store.finishedIds == ["tx-1"] }
        let confirm = try XCTUnwrap(h.http.requests("POST", "/subscription/confirm").first)
        XCTAssertEqual(confirm.body?["appUserId"] as? String, "u1")
        XCTAssertEqual(confirm.body?["providerType"] as? Int, 2)
        XCTAssertEqual(confirm.body?["transactionId"] as? String, "tx-1")
        XCTAssertEqual(confirm.body?["originalTransactionId"] as? String, "orig-tx-1")
        XCTAssertEqual(confirm.body?["productId"] as? String, "com.app.monthly")
        XCTAssertEqual(confirm.body?["receipt"] as? String, "jws-tx-1")
        XCTAssertEqual(confirm.body?["bundleId"] as? String, "com.test.app")
        XCTAssertEqual(confirm.providerData?["appAccountToken"] as? String, "a834e82f-da33-5e3b-95dc-2978401465f4")

        let events = h.log.all
        let confirmIndex = try XCTUnwrap(events.firstIndex(of: "POST /subscription/confirm"))
        let finishIndex = try XCTUnwrap(events.firstIndex(of: "finish tx-1"))
        XCTAssertLessThan(confirmIndex, finishIndex, "a transaction is finished only after the backend accepted it")

        let info = try await h.purchases.customerInfo(fetchPolicy: .fromCacheOnly)
        XCTAssertTrue(info.isPremium)
    }

    func testTransientFailureLeavesTheTransactionUnfinishedThenRetries() async throws {
        let h = await Harness.make()
        let delegate = await MainActor.run { RecordingDelegate() }
        h.purchases.delegate = delegate
        let fallback = Harness.defaultResponder()
        // BillingBearAPI retries 4 times inside one call: the first sync fails, the background retry succeeds.
        h.http.respond { request, count in
            if request.path == "/subscription/confirm" && count <= 4 { return .json(503, "{}") }
            return fallback(request, count)
        }

        h.store.emit(.verified(Fixture.transaction("tx-retry")))

        await eventually { h.store.finishedIds == ["tx-retry"] }
        XCTAssertEqual(h.http.requests("POST", "/subscription/confirm").count, 5)
        await eventually { await MainActor.run { delegate.synced == ["tx-retry"] } }
        let failures = await MainActor.run { delegate.failures.map { $0.1.statusCode } }
        XCTAssertEqual(failures, [503])
        withExtendedLifetime(delegate) {}
    }

    func testServerRejectionIsNeitherFinishedNorRetried() async throws {
        let h = await Harness.make()
        let delegate = await MainActor.run { RecordingDelegate() }
        h.purchases.delegate = delegate
        h.http.respond { request, _ in
            request.path == "/subscription/confirm" ? .json(400, #"{"error":{"message":"bad receipt"}}"#) : .json(200, Fixture.entitlements(premium: false))
        }

        h.store.emit(.verified(Fixture.transaction("tx-bad")))

        await eventually { await MainActor.run { delegate.failures.count == 1 } }
        await settle()
        XCTAssertEqual(h.store.finishedIds, [], "never finish what the backend did not accept")
        XCTAssertEqual(h.http.requests("POST", "/subscription/confirm").count, 1)
        let error = await MainActor.run { delegate.failures.first?.1 }
        XCTAssertEqual(error?.statusCode, 400)
        XCTAssertEqual(error?.message, "bad receipt")
        withExtendedLifetime(delegate) {}
    }

    func testUnverifiedTransactionIsNeitherSentNorFinished() async throws {
        let h = await Harness.make()
        let delegate = await MainActor.run { RecordingDelegate() }
        h.purchases.delegate = delegate

        h.store.emit(.unverified(Fixture.transaction("tx-forged"), reason: "bad signature"))

        await eventually { await MainActor.run { delegate.failures.count == 1 } }
        XCTAssertTrue(h.http.requests.isEmpty)
        XCTAssertEqual(h.store.finishedIds, [])
        let code = await MainActor.run { delegate.failures.first?.1.code }
        XCTAssertEqual(code, .storeError)
        withExtendedLifetime(delegate) {}
    }

    // MARK: Revocations and upgrades

    func testRevokedSubscriptionIsConfirmedSoTheServerLearnsTheRefund() async throws {
        let h = await Harness.make { request, _ in
            if request.path == "/subscription/confirm" { return .json(200, "{}") }
            return .json(200, Fixture.entitlements(premium: false))
        }
        h.store.emit(.verified(Fixture.transaction("tx-refunded", revoked: true)))

        await eventually { h.store.finishedIds == ["tx-refunded"] }
        XCTAssertEqual(h.http.requests("POST", "/subscription/confirm").count, 1)
        let info = try await h.purchases.customerInfo(fetchPolicy: .fromCacheOnly)
        XCTAssertFalse(info.isPremium)
    }

    func testRevokedSubscriptionTheServerRejectsStaysUnfinished() async throws {
        let h = await Harness.make { request, _ in
            if request.path == "/subscription/confirm" { return .json(401, "{}") }
            return .json(200, Fixture.entitlements(premium: true))
        }
        h.store.emit(.verified(Fixture.transaction("tx-gone", revoked: true)))

        await eventually { h.http.requests("POST", "/subscription/confirm").count == 1 }
        await settle()
        XCTAssertEqual(h.store.finishedIds, [], "a refund the server never reconciled must stay replayable")
    }

    func testRefundOfAnAlreadyValidatedPurchaseIsConfirmedAgain() async throws {
        let refunded = LockedFlag()
        let h = await Harness.make { request, _ in
            if request.path == "/subscription/confirm" {
                if request.body?["transactionId"] as? String == "tx-1", refunded.isSet { return .json(200, "{}") }
                return .json(200, "{}")
            }
            return .json(200, Fixture.entitlements(premium: !refunded.isSet))
        }
        h.store.emit(.verified(Fixture.transaction("tx-1")))
        await eventually { h.store.finishedIds == ["tx-1"] }

        // Apple refunds it: the same transaction id comes back through updates, now revoked.
        refunded.set()
        h.store.emit(.verified(Fixture.transaction("tx-1", revoked: true)))

        await eventually { h.http.requests("POST", "/subscription/confirm").count == 2 }
        await eventually { h.store.finishedIds == ["tx-1", "tx-1"] }
        let info = try await h.purchases.customerInfo(fetchPolicy: .fromCacheOnly)
        XCTAssertFalse(info.isPremium)
    }

    func testRefundedOneTimePurchaseWaitsUntilBillingBearRecordedTheRefund() async throws {
        let checks = LockedFlag()
        let h = await Harness.make { request, count in
            if request.path.hasSuffix("/non-subscription") {
                // A server that predates revocation-aware records: the re-post of the recorded purchase
                // is answered idempotently, without `revoked`.
                return .json(200, #"{"productId":"com.app.lifetime","transactionId":"tx-lifetime","isConsumable":false,"entitlementGranted":false,"alreadyRecorded":true}"#)
            }
            guard request.path.hasPrefix("/subscription/entitlements/") else { return .json(500, "{}") }
            if count >= 3 { checks.set() }
            let refundedAt = count >= 3 ? #""2026-11-02T00:00:00Z""# : "null"
            return .json(200, """
            {"userId":null,"isPremium":\(count < 3),"entitlements":\(count < 3 ? #"["premium"]"# : "[]"),"subscription":null,
             "nonSubscriptionTransactions":[{"productId":"com.app.lifetime","transactionId":"tx-lifetime","store":2,
               "isConsumable":false,"purchasedAt":"2026-10-01T00:00:00Z","refundedAt":\(refundedAt)}]}
            """)
        }
        h.store.emit(.verified(Fixture.transaction("tx-lifetime", product: "com.app.lifetime", type: .nonConsumable, revoked: true)))

        await eventually { h.store.finishedIds == ["tx-lifetime"] }
        XCTAssertTrue(checks.isSet, "finished only once the server's record carried the refund")
        XCTAssertGreaterThanOrEqual(h.http.requests("GET", "/subscription/entitlements/u1").count, 3)
        let reposts = h.http.requests("POST", "/v1/subscribers/u1/non-subscription")
        XCTAssertEqual(reposts.count, 2, "re-posted (silently) only while BillingBear's record lacked the refund")
        XCTAssertTrue(reposts.allSatisfy { $0.body?["claimOrphanOnly"] as? Bool == true })
        let info = try await h.purchases.customerInfo(fetchPolicy: .fromCacheOnly)
        XCTAssertFalse(info.isPremium)
    }

    func testUpgradedTransactionIsFinishedWithoutConfirmingOnceBillingBearAnswers() async throws {
        let reachable = LockedFlag()
        let h = await Harness.make { request, _ in
            guard reachable.isSet else { return .networkError }
            return request.path.hasPrefix("/subscription/entitlements/") ? .json(200, Fixture.entitlements(premium: true)) : .json(404, "{}")
        }
        // Apple marks the upgraded-away transaction revoked as of the upgrade.
        h.store.emit(.verified(Fixture.transaction("tx-old-tier", revoked: true, upgraded: true)))

        await eventually { h.http.requests("GET", "/subscription/entitlements/u1").count >= 4 }
        XCTAssertEqual(h.store.finishedIds, [], "not finished while BillingBear is unreachable")

        reachable.set()
        await h.purchases.handleStoreResult(.verified(Fixture.transaction("tx-old-tier", revoked: true, upgraded: true)), source: .unfinished)
        await eventually { h.store.finishedIds == ["tx-old-tier"] }
        XCTAssertTrue(h.http.requests("POST", "/subscription/confirm").isEmpty, "confirming it would expire the subscription")
    }

    func testAnOlderRenewalConfirmsTheSubscriptionsLatestTransaction() async throws {
        let h = await Harness.make()
        let newer = StoreTransaction(
            transactionId: "tx-renewal-3", originalTransactionId: "orig-tx-renewal-1", productId: "com.app.monthly",
            productType: .autoRenewable, purchaseDate: Date(timeIntervalSince1970: 1_799_900_000),
            expirationDate: Date(timeIntervalSince1970: 1_802_500_000), jwsRepresentation: "jws-3"
        )
        h.store.setLatest(["com.app.monthly": newer])
        let older = StoreTransaction(
            transactionId: "tx-renewal-1", originalTransactionId: "orig-tx-renewal-1", productId: "com.app.monthly",
            productType: .autoRenewable, purchaseDate: Date(timeIntervalSince1970: 1_794_700_000),
            expirationDate: Date(timeIntervalSince1970: 1_797_300_000), jwsRepresentation: "jws-1"
        )

        h.store.emit(.verified(older))

        await eventually { h.store.finishedIds == ["tx-renewal-1"] }
        let confirm = try XCTUnwrap(h.http.requests("POST", "/subscription/confirm").first)
        XCTAssertEqual(confirm.body?["transactionId"] as? String, "tx-renewal-3",
                       "the backend takes the period of the transaction it is given: never an older one")
        XCTAssertEqual(confirm.body?["receipt"] as? String, "jws-3")
    }

    func testAReplayOfTheProductBeforeADowngradeConfirmsTheCurrentProduct() async throws {
        let h = await Harness.make()
        let yearly = StoreTransaction(
            transactionId: "tx-yearly", originalTransactionId: "orig-sub", productId: "com.app.yearly",
            productType: .autoRenewable, purchaseDate: Date(timeIntervalSince1970: 1_768_000_000),
            expirationDate: Date(timeIntervalSince1970: 1_799_500_000), subscriptionGroupId: "group"
        )
        let monthly = StoreTransaction(
            transactionId: "tx-monthly", originalTransactionId: "orig-sub", productId: "com.app.monthly",
            productType: .autoRenewable, purchaseDate: Date(timeIntervalSince1970: 1_799_500_000),
            expirationDate: Date(timeIntervalSince1970: 1_802_100_000), subscriptionGroupId: "group"
        )
        // The downgrade took effect: the subscription's latest transaction is on another product.
        h.store.setLatest(["orig-sub": monthly])

        h.store.emit(.verified(yearly))

        await eventually { h.store.finishedIds == ["tx-yearly"] }
        let confirm = try XCTUnwrap(h.http.requests("POST", "/subscription/confirm").first)
        XCTAssertEqual(confirm.body?["transactionId"] as? String, "tx-monthly")
        XCTAssertEqual(confirm.body?["productId"] as? String, "com.app.monthly")
    }

    func testWhenTheSubscriptionsCurrentStateCannotBeReadNothingIsConfirmed() async throws {
        let log = EventLog()
        let http = MockHTTPClient(log: log, responder: Harness.defaultResponder())
        let store = MockStoreKit(log: log)
        let gate = LockedFlag()
        let purchases = Purchases(defaults: UserDefaults(suiteName: "bb.status.\(UUID().uuidString)")!)
        await purchases.configure(
            api: BillingBearAPI(apiKey: "pk_test", httpClient: http, sleep: { _ in }),
            store: store,
            appUserId: "u1",
            retrySleep: { _ in await waitFor(gate) }
        )
        // The subscription moved to monthly; its old yearly transaction is replayed.
        store.setLatest(["orig-tx-old": StoreTransaction(
            transactionId: "tx-current", originalTransactionId: "orig-tx-old", productId: "com.app.monthly",
            productType: .autoRenewable, purchaseDate: Date(timeIntervalSince1970: 1_799_900_000)
        )])
        store.setLatestFails(true)

        store.emit(.verified(Fixture.transaction("tx-old", product: "com.app.yearly")))
        await settle(200)
        XCTAssertTrue(http.requests("POST", "/subscription/confirm").isEmpty, "never guess which period to confirm")
        XCTAssertEqual(store.finishedIds, [])

        // StoreKit answers again: the retry confirms the subscription's current transaction.
        store.setLatestFails(false)
        gate.set()
        await eventually { store.finishedIds == ["tx-old"] }
        XCTAssertEqual(http.requests("POST", "/subscription/confirm").first?.body?["transactionId"] as? String, "tx-current")
    }

    func testARenewalSupersededByAnUpgradeIsNotConfirmed() async throws {
        let h = await Harness.make()
        h.store.setLatest(["com.app.monthly": StoreTransaction(
            transactionId: "tx-2", originalTransactionId: "orig-tx-1", productId: "com.app.monthly",
            productType: .autoRenewable, purchaseDate: Date(timeIntervalSince1970: 1_799_900_000),
            revocationDate: Date(timeIntervalSince1970: 1_799_950_000), isUpgraded: true
        )])

        h.store.emit(.verified(Fixture.transaction("tx-1")))

        await eventually { h.store.finishedIds == ["tx-1"] }
        XCTAssertTrue(h.http.requests("POST", "/subscription/confirm").isEmpty)
        XCTAssertEqual(h.http.requests("GET", "/subscription/entitlements/u1").count, 1)
    }

    func testARefundOverlappingTheOriginalRecordNeverGrantsTheRefundedPurchase() async throws {
        let refundRecorded = LockedFlag()
        let recorded = LockedFlag()
        let h = await Harness.make { request, _ in
            if request.path.hasSuffix("/non-subscription") {
                recorded.set()
                return .json(200, #"{"productId":"com.app.lifetime","transactionId":"tx-l","isConsumable":false,"entitlementGranted":true,"alreadyRecorded":false}"#)
            }
            let refundedAt = refundRecorded.isSet ? #""2026-11-02T00:00:00Z""# : "null"
            let records = recorded.isSet
                ? #"[{"productId":"com.app.lifetime","transactionId":"tx-l","store":2,"isConsumable":false,"purchasedAt":null,"refundedAt":"# + refundedAt + "}]"
                : "[]"
            return .json(200, #"{"userId":null,"isPremium":false,"entitlements":[],"subscription":null,"nonSubscriptionTransactions":"# + records + "}")
        }
        h.http.delay { request, _ in request.path.hasSuffix("/non-subscription") ? 300_000_000 : 0 }

        h.store.emit(.verified(Fixture.transaction("tx-l", product: "com.app.lifetime", type: .nonConsumable)))
        await eventually { recorded.isSet || h.http.requests("POST", "/v1/subscribers/u1/non-subscription").count == 1 }
        // The refund arrives while the original record is still in flight.
        h.store.emit(.verified(Fixture.transaction("tx-l", product: "com.app.lifetime", type: .nonConsumable, revoked: true)))

        await settle(700)
        XCTAssertEqual(h.store.finishedIds, [], "neither revision finishes before BillingBear recorded the refund")
        // The original record, then silent re-posts of the recorded purchase (which never grant it again)
        // answered here as an older server would: without `revoked`.
        let posts = h.http.requests("POST", "/v1/subscribers/u1/non-subscription")
        XCTAssertGreaterThanOrEqual(posts.count, 1)
        XCTAssertTrue(posts.dropFirst().allSatisfy { $0.body?["claimOrphanOnly"] as? Bool == true })

        // Next foreground, after Apple's refund notification reached BillingBear: StoreKit still lists the
        // revoked transaction as unfinished.
        refundRecorded.set()
        h.store.setUnfinished([.verified(Fixture.transaction("tx-l", product: "com.app.lifetime", type: .nonConsumable, revoked: true))])
        await h.purchases.handleForeground()
        // A retry still re-posting with the old state may be joined first; the next one finishes it.
        await eventually { h.store.finishedIds == ["tx-l"] }
    }

    func testFamilySharingRevocationIsDoneOnceBillingBearAnswers() async throws {
        let h = await Harness.make { request, _ in
            if request.path.hasSuffix("/non-subscription") {
                // An older server: no `revoked` in the answer. A withdrawal never gets a refund date.
                return .json(200, #"{"productId":"com.app.lifetime","transactionId":"tx-shared","isConsumable":false,"entitlementGranted":false,"alreadyRecorded":true}"#)
            }
            return .json(200, #"{"userId":null,"isPremium":false,"entitlements":[],"subscription":null,"nonSubscriptionTransactions":[{"productId":"com.app.lifetime","transactionId":"tx-shared","store":2,"isConsumable":false,"purchasedAt":null,"refundedAt":null}]}"#)
        }
        let shared = StoreTransaction(
            transactionId: "tx-shared", originalTransactionId: "orig", productId: "com.app.lifetime", productType: .nonConsumable,
            purchaseDate: Date(timeIntervalSince1970: 1_799_000_000), revocationDate: Date(timeIntervalSince1970: 1_799_500_000),
            isFamilyShared: true
        )
        h.store.emit(.verified(shared))

        await eventually { h.store.finishedIds == ["tx-shared"] }
        XCTAssertEqual(h.http.requests("POST", "/v1/subscribers/u1/non-subscription").count, 1,
                       "posted once so a current server takes the grant back; done once BillingBear answered")
    }

    func testRefundedOneTimePurchaseIsNeverRecordedAgain() async throws {
        let h = await Harness.make()
        h.store.emit(.verified(Fixture.transaction("tx-lifetime", product: "com.app.lifetime", type: .nonConsumable, revoked: true)))

        await eventually { h.store.finishedIds == ["tx-lifetime"] }
        XCTAssertTrue(h.http.requests("POST", "/v1/subscribers/u1/non-subscription").isEmpty)
        XCTAssertTrue(h.http.requests("POST", "/subscription/confirm").isEmpty)
    }

    // MARK: One-time products

    func testConsumableGoesToTheOneTimePurchasePath() async throws {
        let h = await Harness.make()
        h.store.emit(.verified(Fixture.transaction("tx-coins", product: "com.app.coins", type: .consumable)))

        await eventually { h.store.finishedIds == ["tx-coins"] }
        let record = try XCTUnwrap(h.http.requests("POST", "/v1/subscribers/u1/non-subscription").first)
        XCTAssertEqual(record.body?["providerType"] as? Int, 2)
        XCTAssertEqual(record.body?["transactionId"] as? String, "tx-coins")
        XCTAssertEqual(record.body?["productId"] as? String, "com.app.coins")
        XCTAssertEqual(record.providerData?["bundleId"] as? String, "com.test.app")
        XCTAssertEqual(record.providerData?["appAccountToken"] as? String, "a834e82f-da33-5e3b-95dc-2978401465f4")
        XCTAssertTrue(h.http.requests("POST", "/subscription/confirm").isEmpty)
    }

    // MARK: Unfinished replay

    func testUnfinishedTransactionsAreReplayedAtConfigureAndValidatedOnce() async throws {
        let log = EventLog()
        let http = MockHTTPClient(log: log, responder: Harness.defaultResponder())
        let store = MockStoreKit(log: log)
        let transaction = Fixture.transaction("tx-left-over")
        store.setUnfinished([.verified(transaction)])
        let purchases = Purchases(defaults: UserDefaults(suiteName: "bb.core.\(UUID().uuidString)")!)
        let api = BillingBearAPI(apiKey: "pk_test", httpClient: http, sleep: { _ in })
        await purchases.configure(api: api, store: store, appUserId: "u1")
        // StoreKit also hands unfinished transactions to Transaction.updates at launch.
        store.emit(.verified(transaction))

        await eventually { store.finishedIds.contains("tx-left-over") }
        await settle()
        XCTAssertEqual(http.requests("POST", "/subscription/confirm").count, 1)
    }

    func testForegroundReplaysWhatIsStillUnfinished() async throws {
        let h = await Harness.make()
        await settle()
        h.store.setUnfinished([.verified(Fixture.transaction("tx-approved-while-away"))])

        await h.purchases.handleForeground()

        XCTAssertEqual(h.store.finishedIds, ["tx-approved-while-away"])
    }

    // MARK: Reconfigure

    func testReconfigureKeepsOneListenerAndUsesTheNewSubscriber() async throws {
        let h = await Harness.make()
        let api = BillingBearAPI(apiKey: "pk_test_123", bundleId: "com.test.app", httpClient: h.http, sleep: { _ in })
        await h.purchases.configure(api: api, store: h.store, appUserId: "u2")
        XCTAssertEqual(h.store.updatesCallCount, 1, "a reconfigure must not start a second Transaction.updates listener")

        h.store.emit(.verified(Fixture.transaction("tx-after-reconfigure")))

        await eventually { h.store.finishedIds == ["tx-after-reconfigure"] }
        let confirm = try XCTUnwrap(h.http.requests("POST", "/subscription/confirm").first)
        XCTAssertEqual(confirm.body?["appUserId"] as? String, "u2")
    }

    func testReconfigureDuringAValidationRevalidatesUnderTheNewProject() async throws {
        let h = await Harness.make()
        // Project A answers slowly.
        h.http.delay { request, _ in request.path == "/subscription/confirm" ? 300_000_000 : 0 }
        let transaction = Fixture.transaction("tx-moving")
        h.store.setUnfinished([.verified(transaction)])
        h.store.emit(.verified(transaction))
        await eventually { h.http.requests("POST", "/subscription/confirm").count == 1 }

        let httpB = MockHTTPClient(log: h.log, responder: Harness.defaultResponder())
        let apiB = BillingBearAPI(apiKey: "pk_project_b", bundleId: "com.test.app", httpClient: httpB, sleep: { _ in })
        await h.purchases.configure(api: apiB, store: h.store, appUserId: "u1", now: { h.clock.now })

        await eventually { httpB.requests("POST", "/subscription/confirm").count == 1 }
        await eventually { h.store.finishedIds == ["tx-moving"] }
        await settle(500)
        XCTAssertEqual(h.store.finishedIds, ["tx-moving"], "project A's late answer must not finish or complete anything")
    }

    func testABackgroundSyncAnswerOlderThanAPurchaseNeverOverwritesIt() async throws {
        let granted = LockedFlag()
        let h = await Harness.make { request, count in
            if request.path == "/subscription/confirm" {
                if request.body?["transactionId"] as? String == "tx-buy" { granted.set() }
                return .json(200, "{}")
            }
            // The renewal's entitlement read captures the state before the purchase…
            if request.path.hasPrefix("/subscription/entitlements/") && count == 1 {
                return .json(200, Fixture.entitlements(premium: false))
            }
            return .json(200, Fixture.entitlements(premium: granted.isSet))
        }
        // …and only arrives after the purchase committed premium.
        h.http.delay { request, count in
            request.path.hasPrefix("/subscription/entitlements/") && count == 1 ? 300_000_000 : 0
        }
        h.store.emit(.verified(Fixture.transaction("tx-renewal")))
        await eventually { h.http.requests("GET", "/subscription/entitlements/u1").count == 1 }

        h.store.setPurchaseHandler { _, _ in .success(.verified(Fixture.transaction("tx-buy"))) }
        let purchase = try await h.purchases.purchase(productId: "com.app.monthly")
        XCTAssertTrue(purchase.customerInfo.isPremium)

        await eventually { h.store.finishedIds.contains("tx-renewal") }
        let info = try await h.purchases.customerInfo(fetchPolicy: .fromCacheOnly)
        XCTAssertTrue(info.isPremium, "the stale renewal answer is re-read, not applied")
    }

    func testRenewalsOfOneSubscriptionReachTheServerInOrder() async throws {
        final class ServerState: @unchecked Sendable {
            private let lock = NSLock(); private var last: String?
            var lastConfirmed: String? { lock.lock(); defer { lock.unlock() }; return last }
            func confirmed(_ id: String?) { lock.lock(); last = id; lock.unlock() }
        }
        let server = ServerState()
        let fallback = Harness.defaultResponder()
        let h = await Harness.make { request, count in
            // The subscription takes the period of the confirm that lands LAST.
            if request.path == "/subscription/confirm" { server.confirmed(request.body?["transactionId"] as? String) }
            return fallback(request, count)
        }
        h.http.delay { request, _ in
            request.path == "/subscription/confirm" && request.body?["transactionId"] as? String == "tx-r1" ? 300_000_000 : 0
        }
        func renewal(_ id: String, at seconds: TimeInterval) -> StoreTransaction {
            StoreTransaction(transactionId: id, originalTransactionId: "orig-sub", productId: "com.app.monthly",
                             productType: .autoRenewable, purchaseDate: Date(timeIntervalSince1970: seconds),
                             expirationDate: Date(timeIntervalSince1970: seconds + 2_600_000))
        }
        let r1 = renewal("tx-r1", at: 1_797_000_000)
        let r2 = renewal("tx-r2", at: 1_799_600_000)
        h.store.setLatest(["com.app.monthly": r1])
        h.store.emit(.verified(r1))
        await eventually { h.http.requests("POST", "/subscription/confirm").count == 1 }

        // The next renewal arrives while the first confirm is still in flight.
        h.store.setLatest(["com.app.monthly": r2])
        h.store.emit(.verified(r2))

        await eventually { Set(h.store.finishedIds) == ["tx-r1", "tx-r2"] }
        XCTAssertEqual(server.lastConfirmed, "tx-r2", "the older period must never land after the newer one")
    }

    func testARetryOfATransactionUpgradedSinceIsNotConfirmed() async throws {
        let h = await Harness.make()
        let snapshot = Fixture.transaction("tx-tier")
        // StoreKit's current view of the same transaction: upgraded away (and revoked as of the upgrade).
        h.store.setLatest(["com.app.monthly": Fixture.transaction("tx-tier", revoked: true, upgraded: true)])

        await h.purchases.handleStoreResult(.verified(snapshot), source: .retry)

        XCTAssertTrue(h.http.requests("POST", "/subscription/confirm").isEmpty)
        XCTAssertEqual(h.store.finishedIds, ["tx-tier"])
    }

    func testAfterALoginTheSameTransactionIsValidatedForTheNewSubscriber() async throws {
        let fallback = Harness.defaultResponder()
        let h = await Harness.make { request, count in
            if request.path == "/v1/customers/login" { return .json(200, #"{"appUserId":"u2","wasMerged":false}"#) }
            return fallback(request, count)
        }
        let owned = Fixture.transaction("tx-owned")
        h.store.emit(.verified(owned))
        await eventually { h.store.finishedIds == ["tx-owned"] }

        _ = try await h.purchases.login("u2")
        h.store.setPurchaseHandler { _, _ in .success(.verified(owned)) }
        _ = try await h.purchases.purchase(productId: "com.app.monthly")

        let confirms = h.http.requests("POST", "/subscription/confirm").compactMap { $0.body?["appUserId"] as? String }
        XCTAssertEqual(confirms, ["u1", "u2"], "the new subscriber's purchase reaches the server's transfer policy")
    }

    func testWorkQueuedBeforeAReconfigureNeverReachesTheNewProject() async throws {
        let h = await Harness.make()
        h.http.delay { request, _ in request.path == "/subscription/confirm" ? 300_000_000 : 0 }
        h.store.emit(.verified(Fixture.transaction("tx-q")))
        await eventually { h.http.requests("POST", "/subscription/confirm").count == 1 }
        // Its refund queues behind the slow confirm, then the app switches project.
        h.store.emit(.verified(Fixture.transaction("tx-q", revoked: true)))
        await settle(50)

        let httpB = MockHTTPClient(log: h.log, responder: Harness.defaultResponder())
        let apiB = BillingBearAPI(apiKey: "pk_project_b", bundleId: "com.test.app", httpClient: httpB, sleep: { _ in })
        await h.purchases.configure(api: apiB, store: h.store, appUserId: "u1", now: { h.clock.now })

        await settle(600)
        XCTAssertTrue(httpB.requests("POST", "/subscription/confirm").isEmpty, "project A's queued refund was sent through project B")
        XCTAssertEqual(h.http.requests("POST", "/subscription/confirm").count, 1)
    }

    func testARetryIsNeverSentForTheNextSubscriberAfterALogout() async throws {
        let log = EventLog()
        let http = MockHTTPClient(log: log) { request, _ in
            if request.path == "/subscription/confirm" { return .json(503, "{}") }
            if request.path == "/v1/customers/logout" { return .json(200, #"{"newAnonymousAppUserId":"$BillingBearAnonymousID:next"}"#) }
            return .json(200, Fixture.entitlements(premium: false))
        }
        let store = MockStoreKit(log: log)
        let gate = LockedFlag()
        let purchases = Purchases(defaults: UserDefaults(suiteName: "bb.retry.\(UUID().uuidString)")!)
        await purchases.configure(
            api: BillingBearAPI(apiKey: "pk_test", httpClient: http, sleep: { _ in }),
            store: store,
            appUserId: "u1",
            retrySleep: { _ in await waitFor(gate) }
        )
        store.emit(.verified(Fixture.transaction("tx-a")))
        await eventually { http.requests("POST", "/subscription/confirm").count == 4 }

        _ = try await purchases.logout()
        gate.set()
        await settle(300)

        let subscribers = Set(http.requests("POST", "/subscription/confirm").compactMap { $0.body?["appUserId"] as? String })
        XCTAssertEqual(subscribers, ["u1"], "the retry must not hand u1's purchase to the next subscriber")
    }

    func testAPurchaseWhoseSheetOutlivesAReconfigureIsNotValidatedThroughEitherClientByIt() async throws {
        let h = await Harness.make()
        let gate = LockedFlag()
        let transaction = Fixture.transaction("tx-sheet")
        h.store.setPurchaseGate(gate)
        h.store.setPurchaseHandler { _, _ in .success(.verified(transaction)) }

        async let purchase = h.purchases.purchase(productId: "com.app.monthly")
        await eventually { h.store.purchases.count == 1 }
        let httpB = MockHTTPClient(log: h.log, responder: Harness.defaultResponder())
        let apiB = BillingBearAPI(apiKey: "pk_project_b", bundleId: "com.test.app", httpClient: httpB, sleep: { _ in })
        await h.purchases.configure(api: apiB, store: h.store, appUserId: "u1", now: { h.clock.now })
        h.store.setUnfinished([.verified(transaction)])
        gate.set()

        do {
            _ = try await purchase
            XCTFail("the purchase result must not be validated through the configuration that replaced it")
        } catch let error as PurchasesError {
            XCTAssertEqual(error.code, .notConfigured)
        }
        XCTAssertTrue(h.http.requests("POST", "/subscription/confirm").isEmpty)
        // The new configuration validates it through its replay.
        await eventually { httpB.requests("POST", "/subscription/confirm").count == 1 }
        await eventually { h.store.finishedIds == ["tx-sheet"] }
    }

    @MainActor
    func testACallbackAboutThePreviousSubscriberNeverReachesTheDelegateAfterALogin() async throws {
        let fallback = Harness.defaultResponder()
        let h = await Harness.make { request, count in
            if request.path == "/v1/customers/login" { return .json(200, #"{"appUserId":"u2","wasMerged":false}"#) }
            return fallback(request, count)
        }
        let delegate = RecordingDelegate()
        h.purchases.delegate = delegate
        // The main actor is busy (this test holds it) while u1's renewal completes and u2 logs in.
        h.store.emit(.verified(Fixture.transaction("tx-u1")))
        let loggedIn = LockedFlag()
        Task.detached {
            while h.store.finishedIds.isEmpty { try? await Task.sleep(nanoseconds: 2_000_000) }
            _ = try? await h.purchases.login("u2")
            loggedIn.set()
        }
        while !loggedIn.isSet { Thread.sleep(forTimeInterval: 0.005) }

        await settle()
        XCTAssertEqual(delegate.synced, [], "u1's sync callback was delivered to u2's session")
    }

    // MARK: Purchase

    func testPurchaseCarriesTheAppAccountTokenAndFinishesAfterConfirm() async throws {
        let h = await Harness.make()
        h.store.setPurchaseHandler { productId, _ in .success(.verified(Fixture.transaction("tx-buy", product: productId))) }

        let result = try await h.purchases.purchase(productId: "com.app.monthly")

        XCTAssertTrue(result.customerInfo.isPremium)
        XCTAssertEqual(result.transactionId, "tx-buy")
        XCTAssertEqual(h.store.purchases.first?.1.appAccountToken, UUID(uuidString: "a834e82f-da33-5e3b-95dc-2978401465f4"))
        XCTAssertEqual(h.store.finishedIds, ["tx-buy"])
        XCTAssertEqual(h.http.requests("POST", "/subscription/confirm").count, 1)
    }

    func testPurchaseThatFailsValidationThrowsAndStaysUnfinished() async throws {
        let h = await Harness.make { request, _ in
            request.path == "/subscription/confirm" ? .networkError : .json(200, Fixture.entitlements(premium: false))
        }
        h.store.setPurchaseHandler { _, _ in .success(.verified(Fixture.transaction("tx-offline-buy"))) }

        do {
            _ = try await h.purchases.purchase(productId: "com.app.monthly")
            XCTFail("expected a network error")
        } catch let error as PurchasesError {
            XCTAssertEqual(error.code, .networkError)
        }
        XCTAssertEqual(h.store.finishedIds, [])
    }

    func testUserCancelledAndUnverifiedPurchasesThrowTheMatchingCodes() async throws {
        let h = await Harness.make()
        h.store.setPurchaseHandler { _, _ in .userCancelled }
        do { _ = try await h.purchases.purchase(productId: "p"); XCTFail() } catch let e as PurchasesError {
            XCTAssertTrue(e.userCancelled)
        }
        h.store.setPurchaseHandler { _, _ in .success(.unverified(Fixture.transaction("tx-u"), reason: "nope")) }
        do { _ = try await h.purchases.purchase(productId: "p"); XCTFail() } catch let e as PurchasesError {
            XCTAssertEqual(e.code, .storeError)
        }
        XCTAssertTrue(h.http.requests("POST", "/subscription/confirm").isEmpty)
    }

    func testAskToBuyCompletesLaterThroughTransactionUpdates() async throws {
        let h = await Harness.make()
        let delegate = await MainActor.run { RecordingDelegate() }
        h.purchases.delegate = delegate
        h.store.setPurchaseHandler { _, _ in .pending }

        do {
            _ = try await h.purchases.purchase(productId: "com.app.monthly")
            XCTFail("expected paymentPending")
        } catch let error as PurchasesError {
            XCTAssertEqual(error.code, .paymentPending)
        }
        XCTAssertTrue(h.http.requests("POST", "/subscription/confirm").isEmpty)

        // The parent approves: StoreKit delivers the transaction through Transaction.updates.
        h.store.emit(.verified(Fixture.transaction("tx-approved")))

        await eventually { h.store.finishedIds == ["tx-approved"] }
        await eventually { await MainActor.run { delegate.synced == ["tx-approved"] } }
        await eventually { await MainActor.run { delegate.updates.last?.isPremium == true } }
        withExtendedLifetime(delegate) {}
    }

    func testPurchaseAlreadyValidatedThroughUpdatesIsNotConfirmedTwice() async throws {
        let h = await Harness.make()
        let transaction = Fixture.transaction("tx-both")
        h.store.emit(.verified(transaction))
        await eventually { h.store.finishedIds == ["tx-both"] }
        h.store.setPurchaseHandler { _, _ in .success(.verified(transaction)) }

        let result = try await h.purchases.purchase(productId: "com.app.monthly")

        XCTAssertTrue(result.customerInfo.isPremium)
        XCTAssertEqual(h.http.requests("POST", "/subscription/confirm").count, 1)
    }

    // MARK: Observer mode

    func testObserverModeSyncsButNeverFinishes() async throws {
        let h = await Harness.make(options: PurchasesOptions(finishTransactions: false))
        h.store.emit(.verified(Fixture.transaction("tx-observed")))

        await eventually { h.http.requests("POST", "/subscription/confirm").count == 1 }
        await settle()
        XCTAssertEqual(h.store.finishedIds, [])
    }

    // MARK: Restore

    func testRestoreSkipsRejectedPurchasesAndRoutesOneTimeProducts() async throws {
        let granted = LockedFlag()
        let h = await Harness.make { request, _ in
            if request.path == "/subscription/restore" {
                if request.body?["transactionId"] as? String == "tx-foreign" { return .json(400, "{}") }
                granted.set()
                return .json(200, "{}")
            }
            if request.path.hasSuffix("/non-subscription") { return .json(200, Fixture.nonSubscriptionRecorded) }
            return .json(200, Fixture.entitlements(premium: granted.isSet))
        }
        h.store.setEntitlements([
            Fixture.transaction("tx-foreign"),
            Fixture.transaction("tx-mine", product: "com.app.yearly"),
            Fixture.transaction("tx-lifetime", product: "com.app.lifetime", type: .nonConsumable),
        ])

        let info = try await h.purchases.restore()

        XCTAssertTrue(info.isPremium)
        XCTAssertEqual(h.http.requests("POST", "/subscription/restore").count, 2)
        XCTAssertEqual(h.http.requests("POST", "/v1/subscribers/u1/non-subscription").count, 1)
    }

    func testRestoreSendsASubscriptionInItsGracePeriod() async throws {
        let clock = TestClock()
        let h = await Harness.make(clock: clock, observe: false)
        h.store.setEntitlements([Fixture.transaction("tx-grace", expires: clock.now.addingTimeInterval(-3_600))])

        let info = try await h.purchases.restore()

        XCTAssertTrue(info.isPremium)
        XCTAssertEqual(h.http.requests("POST", "/subscription/restore").count, 1, "StoreKit still lists it: the server decides")
    }

    func testRestoreThrowsWhenEveryPurchaseFailedOnTheServer() async throws {
        let h = await Harness.make { request, _ in
            request.path == "/subscription/restore" ? .json(500, "{}") : .json(200, Fixture.entitlements(premium: false))
        }
        h.store.setEntitlements([Fixture.transaction("tx-1")])

        do {
            _ = try await h.purchases.restore()
            XCTFail("a failed restore must not look like 'nothing to restore'")
        } catch let error as PurchasesError {
            XCTAssertEqual(error.statusCode, 500)
        }
    }

    func testOfflineRestoreIsNotOverwrittenByAnOlderRead() async throws {
        let h = await Harness.make(observe: false) { request, _ in
            request.path == "/subscription/restore" ? .networkError : .json(200, Fixture.entitlements(premium: false))
        }
        h.http.delay { request, _ in request.path.hasPrefix("/subscription/entitlements/") ? 300_000_000 : 0 }
        h.store.setEntitlements([Fixture.transaction("tx-1")])

        async let olderRead = h.purchases.customerInfo(fetchPolicy: .fetchCurrent)
        try? await Task.sleep(nanoseconds: 50_000_000)
        let restored = try await h.purchases.restore()
        XCTAssertTrue(restored.isPremium)
        _ = try await olderRead

        let info = try await h.purchases.customerInfo(fetchPolicy: .fromCacheOnly)
        XCTAssertTrue(info.isPremium, "a read that started before the restore must not downgrade it")
    }

    func testARestoreNeverGrantsOfflineFromAPurchaseTheServerRejected() async throws {
        let h = await Harness.make(observe: false) { request, _ in
            if request.path.hasSuffix("/non-subscription") { return .json(400, #""Transaction bundle id does not match""#) }
            if request.path == "/subscription/restore" { return .networkError }
            return .json(200, Fixture.entitlements(premium: false))
        }
        h.store.setEntitlements([
            Fixture.transaction("tx-rejected-lifetime", product: "com.app.lifetime", type: .nonConsumable),
            Fixture.transaction("tx-season", product: "com.app.season", type: .nonRenewable),
        ])

        do {
            _ = try await h.purchases.restore()
            XCTFail("the only purchase that could not reach the server grants nothing offline")
        } catch let error as PurchasesError {
            XCTAssertEqual(error.code, .networkError)
        }
    }

    func testARestoreDoesNotRecordAPurchaseRefundedWhileItWaited() async throws {
        let fallback = Harness.defaultResponder()
        let h = await Harness.make { request, count in fallback(request, count) }
        h.http.delay { request, _ in request.path == "/subscription/restore" ? 300_000_000 : 0 }
        let lifetime = Fixture.transaction("tx-life", product: "com.app.lifetime", type: .nonConsumable)
        h.store.setEntitlements([Fixture.transaction("tx-sub"), lifetime])

        async let restored = h.purchases.restore()
        await eventually { h.http.requests("POST", "/subscription/restore").count == 1 }
        // Apple refunds the lifetime purchase while the subscription restore is in flight.
        h.store.emit(.verified(Fixture.transaction("tx-life", product: "com.app.lifetime", type: .nonConsumable, revoked: true)))
        await eventually { h.store.finishedIds.contains("tx-life") }
        _ = try await restored

        XCTAssertTrue(h.http.requests("POST", "/v1/subscribers/u1/non-subscription").isEmpty,
                      "recording the stale snapshot would grant the refunded purchase")
    }

    func testAnAllRejectedRestoreNeverGrantsThoseOfflineAfterward() async throws {
        let h = await Harness.make(observe: false) { request, _ in
            if request.path.hasSuffix("/non-subscription") { return .json(400, #""Transaction bundle id does not match""#) }
            return .networkError
        }
        h.store.setEntitlements([Fixture.transaction("tx-rejected", product: "com.app.lifetime", type: .nonConsumable)])

        do {
            let info = try await h.purchases.restore()
            XCTFail("returned \(info.isPremium ? "premium" : "free") instead of the read's network error")
        } catch let error as PurchasesError {
            XCTAssertEqual(error.code, .networkError)
        }
    }

    func testRestoreOfflineGrantsProvisionally() async throws {
        let h = await Harness.make { _, _ in .networkError }
        h.store.setEntitlements([Fixture.transaction("tx-1")])

        let info = try await h.purchases.restore()

        XCTAssertTrue(info.isPremium)
        XCTAssertTrue(info.isOfflineComputed)
        XCTAssertNil(h.defaults.data(forKey: Purchases.customerInfoCacheKey), "a provisional grant is never persisted")
    }
}
