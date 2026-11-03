import XCTest
@testable import BillingBear

/// Customer info: fetch policies, read de-duplication, stale-read protection, the stream and
/// delegate, persistence and offline entitlements.
final class CustomerInfoCoreTests: XCTestCase {

    private func premiumResponder(_ premium: Bool = true) -> (RecordedRequest, Int) -> MockReply {
        { _, _ in .json(200, Fixture.entitlements(premium: premium)) }
    }

    // MARK: Fetch policies

    func testCachedOrFetchedServesAFreshCacheThenRefetchesWhenStale() async throws {
        let clock = TestClock()
        let h = await Harness.make(clock: clock, observe: false, responder: premiumResponder())

        _ = try await h.purchases.customerInfo()
        _ = try await h.purchases.customerInfo()
        XCTAssertEqual(h.http.requests("GET", "/subscription/entitlements/u1").count, 1)

        clock.advance(301)
        _ = try await h.purchases.customerInfo()
        XCTAssertEqual(h.http.requests("GET", "/subscription/entitlements/u1").count, 2)

        _ = try await h.purchases.customerInfo(fetchPolicy: .fetchCurrent)
        XCTAssertEqual(h.http.requests("GET", "/subscription/entitlements/u1").count, 3)

        let cached = try await h.purchases.customerInfo(fetchPolicy: .fromCacheOnly)
        XCTAssertTrue(cached.isPremium)
        XCTAssertEqual(h.http.requests("GET", "/subscription/entitlements/u1").count, 3)
    }

    func testFromCacheOnlyWithoutCacheIsEmptyAndOffline() async throws {
        let h = await Harness.make(observe: false, responder: premiumResponder())
        let info = try await h.purchases.customerInfo(fetchPolicy: .fromCacheOnly)
        XCTAssertFalse(info.isPremium)
        XCTAssertEqual(info.appUserId, "u1")
        XCTAssertTrue(h.http.requests.isEmpty)
    }

    func testConcurrentReadsShareOneRequest() async throws {
        let h = await Harness.make(observe: false, responder: premiumResponder())
        h.http.delay { _, _ in 100_000_000 }

        async let a = h.purchases.customerInfo(fetchPolicy: .fetchCurrent)
        async let b = h.purchases.customerInfo(fetchPolicy: .fetchCurrent)
        async let c = h.purchases.customerInfo()
        let results = try await [a, b, c]

        XCTAssertTrue(results.allSatisfy(\.isPremium))
        XCTAssertEqual(h.http.requests("GET", "/subscription/entitlements/u1").count, 1)
    }

    func testAReadThatStartedBeforeAPurchaseNeverDowngradesTheBuyer() async throws {
        let h = await Harness.make(observe: false)
        // The first read is slow and answers "free"; the purchase confirms meanwhile.
        h.http.delay { request, count in
            request.path.hasPrefix("/subscription/entitlements/") && count == 1 ? 300_000_000 : 0
        }
        h.store.setPurchaseHandler { _, _ in .success(.verified(Fixture.transaction("tx-race"))) }

        async let slowRead = h.purchases.customerInfo(fetchPolicy: .fetchCurrent)
        try? await Task.sleep(nanoseconds: 50_000_000)
        let purchase = try await h.purchases.purchase(productId: "com.app.monthly")
        let read = try await slowRead

        XCTAssertTrue(purchase.customerInfo.isPremium)
        XCTAssertTrue(read.isPremium, "the stale read answers with what the purchase wrote")
        let cached = try await h.purchases.customerInfo(fetchPolicy: .fromCacheOnly)
        XCTAssertTrue(cached.isPremium)
    }

    // MARK: Stream and delegate

    func testStreamStartsWithTheLastKnownValueAndSkipsRepeats() async throws {
        let premium = LockedFlag()
        let h = await Harness.make(observe: false) { _, _ in .json(200, Fixture.entitlements(premium: premium.isSet)) }
        _ = try await h.purchases.customerInfo()

        var iterator = h.purchases.customerInfoStream.makeAsyncIterator()
        let first = await iterator.next()
        XCTAssertEqual(first?.isPremium, false)

        _ = try await h.purchases.customerInfo(fetchPolicy: .fetchCurrent) // same value: not repeated
        premium.set()
        _ = try await h.purchases.customerInfo(fetchPolicy: .fetchCurrent)
        let second = await iterator.next()
        XCTAssertEqual(second?.isPremium, true)
    }

    @MainActor
    func testDelegateGetsTheLastKnownValueWhenSetThenEveryChange() async throws {
        let premium = LockedFlag()
        let h = await Harness.make(observe: false) { _, _ in .json(200, Fixture.entitlements(premium: premium.isSet)) }
        _ = try await h.purchases.customerInfo()

        let delegate = RecordingDelegate()
        h.purchases.delegate = delegate
        await eventually { await MainActor.run { delegate.updates.count == 1 } }
        XCTAssertEqual(delegate.updates.first?.isPremium, false)

        premium.set()
        _ = try await h.purchases.customerInfo(fetchPolicy: .fetchCurrent)
        await eventually { await MainActor.run { delegate.updates.count == 2 } }
        XCTAssertEqual(delegate.updates.last?.isPremium, true)
        XCTAssertTrue(h.purchases.delegate === delegate)
    }

    // MARK: Offline entitlements

    func testNetworkFailureServesTheCacheWithinTheOfflineWindow() async throws {
        let clock = TestClock()
        let offline = LockedFlag()
        let h = await Harness.make(options: PurchasesOptions(offlineEntitlement: nil), clock: clock, observe: false) { _, _ in
            offline.isSet ? .networkError : .json(200, Fixture.entitlements(premium: true))
        }
        _ = try await h.purchases.customerInfo()
        offline.set()

        clock.advance(3_600)
        let withinWindow = try await h.purchases.customerInfo()
        XCTAssertTrue(withinWindow.isPremium)
        XCTAssertFalse(withinWindow.isOfflineComputed)

        clock.advance(86_400)
        do {
            _ = try await h.purchases.customerInfo()
            XCTFail("past the window the cached grant is not honoured")
        } catch let error as PurchasesError {
            XCTAssertEqual(error.code, .networkError)
        }
    }

    func testNetworkFailureGrantsProvisionallyFromStoreKit() async throws {
        let h = await Harness.make(observe: false) { _, _ in .networkError }
        h.store.setEntitlements([Fixture.transaction("tx-active")])

        let info = try await h.purchases.customerInfo()

        XCTAssertTrue(info.isPremium)
        XCTAssertTrue(info.isOfflineComputed)
        XCTAssertEqual(info.entitlements["premium"]?.isActive, true)
        XCTAssertNil(h.defaults.data(forKey: Purchases.customerInfoCacheKey))
    }

    func testExpiredRevokedUpgradedConsumableOrNonRenewingPurchasesGrantNothingOffline() async throws {
        let clock = TestClock()
        let h = await Harness.make(clock: clock, observe: false) { _, _ in .networkError }
        h.store.setEntitlements([
            Fixture.transaction("tx-expired", expires: clock.now.addingTimeInterval(-60)),
            Fixture.transaction("tx-revoked", revoked: true),
            Fixture.transaction("tx-upgraded", upgraded: true),
            Fixture.transaction("tx-coins", product: "com.app.coins", type: .consumable),
            Fixture.transaction("tx-season-pass", product: "com.app.season", type: .nonRenewable),
        ])

        do {
            _ = try await h.purchases.customerInfo()
            XCTFail("nothing on the device grants access")
        } catch let error as PurchasesError {
            XCTAssertEqual(error.code, .networkError)
        }
    }

    func testAServerErrorFallsBackToTheServerAnswerNotToAProvisionalGrant() async throws {
        let phase = Phase()
        let h = await Harness.make(observe: false) { _, _ in
            switch phase.value {
            case 0: return .json(200, Fixture.entitlements(premium: false))
            case 1: return .networkError
            default: return .json(500, "{}")
            }
        }
        h.store.setEntitlements([Fixture.transaction("tx-active")])

        let server = try await h.purchases.customerInfo(fetchPolicy: .fetchCurrent)
        XCTAssertFalse(server.isPremium)
        phase.value = 1
        let provisional = try await h.purchases.customerInfo(fetchPolicy: .fetchCurrent)
        XCTAssertTrue(provisional.isOfflineComputed)

        // A provisional value is never fresh: the default policy asks BillingBear again.
        phase.value = 2
        let requestsBefore = h.http.requests("GET", "/subscription/entitlements/u1").count
        let afterError = try await h.purchases.customerInfo()
        XCTAssertGreaterThan(h.http.requests("GET", "/subscription/entitlements/u1").count, requestsBefore)
        XCTAssertFalse(afterError.isPremium, "a 500 falls back to what the server said, not the device's guess")
        XCTAssertFalse(afterError.isOfflineComputed)
    }

    func testASubscriptionInItsBillingGracePeriodStillGrantsOffline() async throws {
        let clock = TestClock()
        let h = await Harness.make(clock: clock, observe: false) { _, _ in .networkError }
        let graceEnd = clock.now.addingTimeInterval(6 * 86_400)
        h.store.setEntitlements([StoreTransaction(
            transactionId: "tx-grace", originalTransactionId: "orig", productId: "com.app.monthly", productType: .autoRenewable,
            purchaseDate: clock.now.addingTimeInterval(-32 * 86_400), expirationDate: clock.now.addingTimeInterval(-86_400),
            gracePeriodExpirationDate: graceEnd
        )])

        let info = try await h.purchases.customerInfo()

        XCTAssertTrue(info.isPremium)
        XCTAssertEqual(info.entitlements["premium"]?.expiresAt, ISO8601.string(graceEnd))
    }

    func testServerErrorNeverFabricatesAnOfflineGrant() async throws {
        let h = await Harness.make(observe: false) { _, _ in .json(500, "{}") }
        h.store.setEntitlements([Fixture.transaction("tx-active")])

        do {
            _ = try await h.purchases.customerInfo()
            XCTFail("a server rejection is not an outage")
        } catch let error as PurchasesError {
            XCTAssertEqual(error.statusCode, 500)
        }
    }

    func testOfflineGrantNeverDowngradesTheCache() {
        let cache = CustomerInfo(
            appUserId: "u1",
            isPremium: true,
            entitlements: ["pro": EntitlementInfo(identifier: "pro", isActive: true, expiresAt: "2027-01-01T00:00:00Z")],
            activeSubscription: nil
        )
        let offline = OfflineEntitlements.compute(
            appUserId: "u1",
            transactions: [Fixture.transaction("tx")],
            entitlement: "premium",
            now: Date(timeIntervalSince1970: 1_800_000_000)
        )
        let merged = OfflineEntitlements.merge(cache: cache, offline: offline)
        XCTAssertEqual(merged?.entitlements["pro"]?.isActive, true)
        XCTAssertEqual(merged?.entitlements["premium"]?.isActive, true)
        XCTAssertEqual(merged?.isPremium, true)
        XCTAssertEqual(merged?.isOfflineComputed, true)

        // Nothing added beyond the cache: the cache stays authoritative, not provisional.
        let same = OfflineEntitlements.merge(cache: cache.replacing(isPremium: true, entitlements: [
            "premium": EntitlementInfo(identifier: "premium", isActive: true, expiresAt: nil),
        ], isOfflineComputed: false), offline: offline)
        XCTAssertEqual(same?.isOfflineComputed, false)
        XCTAssertEqual(OfflineEntitlements.merge(cache: cache, offline: nil), cache)
    }

    func testACustomOfflineEntitlementIsNotPremium() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let pro = try XCTUnwrap(OfflineEntitlements.compute(appUserId: "u", transactions: [Fixture.transaction("t")], entitlement: "pro", now: now))
        XCTAssertFalse(pro.isPremium, "the backend's isPremium means holding \"premium\"")
        XCTAssertEqual(pro.entitlements["pro"]?.isActive, true)
    }

    func testMergingAProvisionalGrantUpdatesTheLatestExpiration() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let free = CustomerInfo(appUserId: "u", isPremium: false, entitlements: [:], activeSubscription: nil)
        let subscription = Fixture.transaction("t", expires: now.addingTimeInterval(1_000))
        let offline = OfflineEntitlements.compute(appUserId: "u", transactions: [subscription], entitlement: "premium", now: now)
        let merged = try XCTUnwrap(OfflineEntitlements.merge(cache: free, offline: offline))
        XCTAssertEqual(merged.latestExpirationDate, ISO8601.string(now.addingTimeInterval(1_000)))

        let finite = CustomerInfo(
            appUserId: "u", isPremium: false,
            entitlements: ["pro": EntitlementInfo(identifier: "pro", isActive: true, expiresAt: "2027-01-01T00:00:00Z")],
            activeSubscription: nil, nonSubscriptionTransactions: [], latestExpirationDate: "2027-01-01T00:00:00Z", isOfflineComputed: false
        )
        let lifetime = OfflineEntitlements.compute(
            appUserId: "u", transactions: [Fixture.transaction("l", product: "life", type: .nonConsumable)], entitlement: "premium", now: now
        )
        XCTAssertNil(OfflineEntitlements.merge(cache: finite, offline: lifetime)?.latestExpirationDate, "a lifetime grant never expires")
        let later = OfflineEntitlements.compute(
            appUserId: "u", transactions: [Fixture.transaction("s", expires: Date(timeIntervalSince1970: 1_900_000_000))], entitlement: "premium", now: now
        )
        XCTAssertEqual(OfflineEntitlements.merge(cache: finite, offline: later)?.latestExpirationDate, ISO8601.string(Date(timeIntervalSince1970: 1_900_000_000)))
    }

    func testOfflineGrantKeepsTheMostGenerousExpiry() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let soon = Fixture.transaction("a", expires: now.addingTimeInterval(100))
        let later = Fixture.transaction("b", expires: now.addingTimeInterval(1_000))
        let info = try XCTUnwrap(OfflineEntitlements.compute(appUserId: "u", transactions: [soon, later], entitlement: "premium", now: now))
        XCTAssertEqual(info.entitlements["premium"]?.expiresAt, ISO8601.string(now.addingTimeInterval(1_000)))
        let lifetime = Fixture.transaction("c", product: "lifetime", type: .nonConsumable)
        let open = try XCTUnwrap(OfflineEntitlements.compute(appUserId: "u", transactions: [later, lifetime], entitlement: "premium", now: now))
        XCTAssertNil(open.entitlements["premium"]?.expiresAt)
        XCTAssertNil(OfflineEntitlements.compute(appUserId: "u", transactions: [later], entitlement: nil, now: now))
    }

    // MARK: Persistence

    func testLastServerAnswerIsRestoredForTheSameSubscriberAndProjectWithinTheWindow() async throws {
        let clock = TestClock()
        let suite = UserDefaults(suiteName: "bb.persist.\(UUID().uuidString)")!
        let first = await Harness.make(defaults: suite, clock: clock, observe: false, responder: premiumResponder())
        _ = try await first.purchases.customerInfo()

        let offlineResponder: (RecordedRequest, Int) -> MockReply = { _, _ in .networkError }
        clock.advance(7_200)
        let relaunch = await Harness.make(options: PurchasesOptions(offlineEntitlement: nil), defaults: suite, clock: clock, observe: false, responder: offlineResponder)
        let restored = try await relaunch.purchases.customerInfo(fetchPolicy: .fromCacheOnly)
        XCTAssertTrue(restored.isPremium)
        let offline = try await relaunch.purchases.customerInfo()
        XCTAssertTrue(offline.isPremium, "offline relaunch keeps the paying user premium")
        var iterator = relaunch.purchases.customerInfoStream.makeAsyncIterator()
        let streamed = await iterator.next()
        XCTAssertEqual(streamed?.isPremium, true)

        let otherUser = await Harness.make(appUserId: "u9", defaults: suite, clock: clock, observe: false, responder: offlineResponder)
        let other = try await otherUser.purchases.customerInfo(fetchPolicy: .fromCacheOnly)
        XCTAssertFalse(other.isPremium)

        let otherProject = await Harness.make(defaults: suite, apiKey: "pk_other", clock: clock, observe: false, responder: offlineResponder)
        let foreign = try await otherProject.purchases.customerInfo(fetchPolicy: .fromCacheOnly)
        XCTAssertFalse(foreign.isPremium)

        clock.advance(86_400)
        let tooOld = await Harness.make(defaults: suite, clock: clock, observe: false, responder: offlineResponder)
        let expired = try await tooOld.purchases.customerInfo(fetchPolicy: .fromCacheOnly)
        XCTAssertFalse(expired.isPremium)
    }

    // MARK: Identity

    func testLoginResetsTheCacheAndPublishesTheIdentifiedSubscriber() async throws {
        let h = await Harness.make(observe: false) { request, _ in
            if request.path == "/v1/customers/login" { return .json(200, #"{"appUserId":"real-user","wasMerged":true}"#) }
            if request.path == "/subscription/entitlements/real-user" { return .json(200, Fixture.entitlements(premium: true)) }
            return .json(200, Fixture.entitlements(premium: false))
        }
        _ = try await h.purchases.customerInfo()
        let info = try await h.purchases.login("real-user")

        XCTAssertTrue(info.isPremium)
        XCTAssertEqual(info.appUserId, "real-user")
        let cached = try await h.purchases.customerInfo(fetchPolicy: .fromCacheOnly)
        XCTAssertEqual(cached.appUserId, "real-user")
        var iterator = h.purchases.customerInfoStream.makeAsyncIterator()
        let streamed = await iterator.next()
        XCTAssertEqual(streamed?.appUserId, "real-user")
    }

    @MainActor
    func testObserversStopSeeingThePreviousSubscribersAccessAfterALogin() async throws {
        let h = await Harness.make(observe: false) { request, _ in
            if request.path == "/v1/customers/login" { return .json(200, #"{"appUserId":"u2","wasMerged":false}"#) }
            if request.path == "/subscription/entitlements/u1" { return .json(200, Fixture.entitlements(premium: true)) }
            return .networkError
        }
        let delegate = RecordingDelegate()
        h.purchases.delegate = delegate
        _ = try await h.purchases.customerInfo()
        var iterator = h.purchases.customerInfoStream.makeAsyncIterator()
        let before = await iterator.next()
        XCTAssertEqual(before?.isPremium, true)

        do {
            _ = try await h.purchases.login("u2")
            XCTFail("u2's first read fails and there is nothing to fall back on")
        } catch let error as PurchasesError {
            XCTAssertEqual(error.code, .networkError)
        }

        let after = await iterator.next()
        XCTAssertEqual(after?.appUserId, "u2")
        XCTAssertEqual(after?.isPremium, false)
        await eventually { await MainActor.run { delegate.updates.last?.appUserId == "u2" } }
        XCTAssertEqual(delegate.updates.last?.isPremium, false)
    }

    func testAReconfigureOfTheSameSubscriberNeverFlashesAnEmptyValue() async throws {
        let h = await Harness.make(observe: false) { _, _ in .json(200, Fixture.entitlements(premium: true)) }
        _ = try await h.purchases.customerInfo()

        // Same project, same subscriber: the persisted value is restored, nothing empty is published.
        let api = BillingBearAPI(apiKey: "pk_test_123", bundleId: "com.test.app", httpClient: h.http, sleep: { _ in })
        await h.purchases.configure(api: api, store: h.store, appUserId: "u1", now: { h.clock.now }, observeTransactions: false)

        var iterator = h.purchases.customerInfoStream.makeAsyncIterator()
        let first = await iterator.next()
        XCTAssertEqual(first?.isPremium, true)
        XCTAssertEqual(first?.appUserId, "u1")
    }

    // MARK: Decoding

    func testEntitlementsDecodeNewFieldsAndTolerateANullProduct() async throws {
        let json = """
        {"userId":null,"isPremium":true,"entitlements":["premium"],"entitlementsExpireAt":"2027-02-01T00:00:00Z",
         "subscription":{"status":1,"store":9,"productId":null,"expiresAt":"2027-01-01T00:00:00Z","startsAt":null,
           "cancelledAt":null,"willRenew":false,"isGracePeriod":true,"billingIssueDetectedAt":"2026-12-30T00:00:00Z",
           "gracePeriodExpiresAt":"2027-01-01T00:00:00Z","unsubscribeDetectedAt":null,"periodType":"normal"},
         "nonSubscriptionTransactions":[{"productId":"coins","transactionId":"t1","store":2,"isConsumable":true,
           "purchasedAt":"2026-11-01T00:00:00Z","refundedAt":null}]}
        """
        let http = MockHTTPClient { _, _ in .json(200, json) }
        let api = BillingBearAPI(apiKey: "pk", httpClient: http, sleep: { _ in })
        let info = try await api.fetchEntitlements(appUserId: "u")

        XCTAssertEqual(info.activeSubscription?.store, "amazon")
        XCTAssertEqual(info.activeSubscription?.productId, "")
        XCTAssertEqual(info.activeSubscription?.billingIssueDetectedAt, "2026-12-30T00:00:00Z")
        XCTAssertEqual(info.activeSubscription?.periodType, "normal")
        XCTAssertEqual(info.latestExpirationDate, "2027-02-01T00:00:00Z")
        XCTAssertEqual(info.nonSubscriptionTransactions.first?.productId, "coins")
        XCTAssertEqual(info.managementURL?.absoluteString, "https://www.amazon.com/gp/css/order-history")
    }

    func testAnExplicitNullEntitlementExpiryMeansNothingExpires() async throws {
        let lifetime = #"{"userId":null,"isPremium":true,"entitlements":["premium"],"entitlementsExpireAt":null,"subscription":{"status":1,"store":2,"productId":"m","expiresAt":"2027-01-01T00:00:00Z","startsAt":null,"cancelledAt":null,"willRenew":true,"isGracePeriod":false}}"#
        let older = #"{"userId":null,"isPremium":true,"entitlements":["premium"],"subscription":{"status":1,"store":2,"productId":"m","expiresAt":"2027-01-01T00:00:00Z","startsAt":null,"cancelledAt":null,"willRenew":true,"isGracePeriod":false}}"#
        let lifetimeAPI = BillingBearAPI(apiKey: "pk", httpClient: MockHTTPClient { _, _ in .json(200, lifetime) }, sleep: { _ in })
        let olderAPI = BillingBearAPI(apiKey: "pk", httpClient: MockHTTPClient { _, _ in .json(200, older) }, sleep: { _ in })

        let withGrant = try await lifetimeAPI.fetchEntitlements(appUserId: "u")
        XCTAssertNil(withGrant.latestExpirationDate, "a lifetime grant on top of a subscription never expires")
        let fromOlderServer = try await olderAPI.fetchEntitlements(appUserId: "u")
        XCTAssertEqual(fromOlderServer.latestExpirationDate, "2027-01-01T00:00:00Z")
    }

    func testCustomerInfoDecodesValuesWrittenBeforeTheNewFields() throws {
        let legacy = #"{"appUserId":"u","isPremium":true,"entitlements":{"premium":{"identifier":"premium","isActive":true,"expiresAt":null}},"activeSubscription":null}"#
        let info = try JSONDecoder().decode(CustomerInfo.self, from: Data(legacy.utf8))
        XCTAssertTrue(info.isPremium)
        XCTAssertFalse(info.isOfflineComputed)
        XCTAssertEqual(info.nonSubscriptionTransactions, [])
        XCTAssertNil(info.managementURL)
    }

    // MARK: App account token

    func testAppAccountTokenMatchesRFC4122AndTheReactNativeSDK() {
        let dns = UUID(uuidString: "6ba7b810-9dad-11d1-80b4-00c04fd430c8")!
        XCTAssertEqual(AppAccountToken.uuidV5(namespace: dns, name: "example.com").uuidString.lowercased(), "cfbff0d1-9375-5685-968c-48ce8b15ae17")
        // Vectors produced by sdk/react-native/lib/appAccountToken.js appAccountTokenFor().
        XCTAssertEqual(AppAccountToken.token(for: "user-1").uuidString.lowercased(), "68d671ba-43bc-58e5-9892-a57ef3878915")
        XCTAssertEqual(
            AppAccountToken.token(for: "$BillingBearAnonymousID:2C7E1B1A-0F43-4B0B-9E36-7A1D7A8B9C0D").uuidString.lowercased(),
            "189b6be3-a396-5a96-b5bb-c425f6e1c614"
        )
        XCTAssertEqual(AppAccountToken.token(for: "café").uuidString.lowercased(), "29140d40-aed8-50c7-b1b6-38f330ca551a")
    }
}

final class Phase: @unchecked Sendable {
    private let lock = NSLock()
    private var current = 0
    var value: Int {
        get { lock.lock(); defer { lock.unlock() }; return current }
        set { lock.lock(); current = newValue; lock.unlock() }
    }
}
