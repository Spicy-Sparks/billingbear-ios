import XCTest
@testable import BillingBear

/// Intro eligibility, promotional and win-back offers, offer codes, refund requests.
final class StoreFeaturesTests: XCTestCase {

    // MARK: Intro eligibility

    func testIntroEligibilityPrefersStoreKitAndFallsBackToHistory() async throws {
        let h = await Harness.make(observe: false) { _, _ in .json(200, Fixture.entitlements(premium: true, productId: "com.app.monthly")) }
        h.store.setIntro([
            "com.app.trial": .eligible,
            "com.app.used": .ineligible,
            "com.app.none": .noIntroOfferExists,
            "com.app.coins": .unknown,
        ])

        let result = await h.purchases.checkTrialOrIntroDiscountEligibility(productIdentifiers: [
            "com.app.trial", "com.app.used", "com.app.none", "com.app.coins", "com.app.monthly", "com.app.missing",
        ])

        XCTAssertEqual(result["com.app.trial"]?.status, .eligible)
        XCTAssertEqual(result["com.app.used"]?.status, .ineligible)
        XCTAssertEqual(result["com.app.none"]?.status, .noIntroOfferExists)
        XCTAssertEqual(result["com.app.coins"]?.status, .unknown)
        // StoreKit could not load these: the subscriber's history decides.
        XCTAssertEqual(result["com.app.monthly"]?.status, .ineligible, "the current subscription's product")
        XCTAssertEqual(result["com.app.missing"]?.status, .unknown, "premium on another product: unknown")
    }

    func testIntroEligibilityHintForAFreeSubscriberIsEligible() async throws {
        let h = await Harness.make(observe: false) { _, _ in .json(200, Fixture.entitlements(premium: false)) }
        let result = await h.purchases.checkTrialOrIntroDiscountEligibility(productIdentifiers: ["com.app.unloadable"])
        XCTAssertEqual(result["com.app.unloadable"]?.status, .eligible)
    }

    func testIntroEligibilityWithNoHistoryAtAllIsUnknown() async throws {
        let h = await Harness.make(observe: false) { _, _ in .networkError }
        let result = await h.purchases.checkTrialOrIntroDiscountEligibility(productIdentifiers: ["com.app.unloadable"])
        XCTAssertEqual(result["com.app.unloadable"]?.status, .unknown)
    }

    // MARK: Promotional offers

    private struct RecordingSigner: PromotionalOfferSigner {
        let requests: RequestBox
        func signPromotionalOffer(_ request: PromotionalOfferSigningRequest) async throws -> PromotionalOffer {
            requests.append(request)
            return PromotionalOffer(
                offerId: request.offerId,
                productId: request.productId,
                keyIdentifier: "KEY123",
                nonce: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
                signature: Data("sig".utf8).base64EncodedString(),
                timestamp: 1_800_000_000_000
            )
        }
    }

    final class RequestBox: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [PromotionalOfferSigningRequest] = []
        func append(_ r: PromotionalOfferSigningRequest) { lock.lock(); items.append(r); lock.unlock() }
        var all: [PromotionalOfferSigningRequest] { lock.lock(); defer { lock.unlock() }; return items }
    }

    func testPromotionalOfferIsSignedForThePurchasesAppAccountTokenAndRedeemed() async throws {
        let box = RequestBox()
        let h = await Harness.make(options: PurchasesOptions(promotionalOfferSigner: RecordingSigner(requests: box)), observe: false)
        h.store.setPurchaseHandler { productId, _ in .success(.verified(Fixture.transaction("tx-promo", product: productId))) }

        let offer = try await h.purchases.getPromotionalOffer(productId: "com.app.yearly", offerId: "comeback50")
        let request = try XCTUnwrap(box.all.first)
        XCTAssertEqual(request.applicationUsername, "a834e82f-da33-5e3b-95dc-2978401465f4")
        XCTAssertEqual(request.appUserId, "u1")
        XCTAssertEqual(request.bundleId, "com.test.app")

        let result = try await h.purchases.purchase(productId: "com.app.yearly", promotionalOffer: offer)
        XCTAssertTrue(result.customerInfo.isPremium)
        let options = try XCTUnwrap(h.store.purchases.first?.1)
        XCTAssertEqual(options.promotionalOffer, offer)
        XCTAssertEqual(options.appAccountToken?.uuidString.lowercased(), request.applicationUsername,
                       "Apple only accepts the signature when applicationUsername == the purchase's appAccountToken")
    }

    func testPromotionalOfferForAnotherProductIsRejectedBeforeTheSheet() async throws {
        let h = await Harness.make(observe: false)
        let offer = PromotionalOffer(offerId: "o", productId: "com.app.other", keyIdentifier: "K", nonce: UUID(), signature: "c2ln", timestamp: 1)
        do {
            _ = try await h.purchases.purchase(productId: "com.app.yearly", promotionalOffer: offer)
            XCTFail("expected a mismatch error")
        } catch let error as PurchasesError {
            XCTAssertEqual(error.code, .storeError)
        }
        XCTAssertTrue(h.store.purchases.isEmpty)
    }

    private static let signaturePath = "/v1/subscribers/u1/apple/promotional-offer-signature"
    private static let signed = #"{"keyIdentifier":"KEY9","nonce":"AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE","timestamp":1800000000000,"signature":"MEUCIQDde3Np","applicationUsername":"a834e82f-da33-5e3b-95dc-2978401465f4","productId":"com.app.yearly","offerId":"comeback50"}"#

    private static func errorBody(_ code: String, _ message: String) -> String {
        #"{"code":"\#(code)","message":"\#(message)","error":{"error":"\#(code)","description":"\#(message)"}}"#
    }

    func testBillingBearSignsThePromotionalOfferByDefaultForThePurchasesToken() async throws {
        let h = await Harness.make(observe: false) { request, count in
            request.path == Self.signaturePath ? .json(200, Self.signed) : Harness.defaultResponder()(request, count)
        }
        h.store.setPurchaseHandler { productId, _ in .success(.verified(Fixture.transaction("tx-promo", product: productId))) }

        let offer = try await h.purchases.getPromotionalOffer(productId: "com.app.yearly", offerId: "comeback50")

        let request = try XCTUnwrap(h.http.requests("POST", Self.signaturePath).first)
        XCTAssertEqual(request.body?["productId"] as? String, "com.app.yearly")
        XCTAssertEqual(request.body?["offerId"] as? String, "comeback50")
        XCTAssertEqual(request.body?["appAccountToken"] as? String, "a834e82f-da33-5e3b-95dc-2978401465f4")
        XCTAssertEqual(request.body?["bundleId"] as? String, "com.test.app", "picks the app and its In-App Purchase key")
        XCTAssertEqual(request.headers["Authorization"], "Bearer pk_test_123")
        XCTAssertNil(request.headers[BillingBearAPI.endUserTokenHeader], "no provider, no end-user token")
        XCTAssertEqual(offer, PromotionalOffer(
            offerId: "comeback50", productId: "com.app.yearly", keyIdentifier: "KEY9",
            nonce: UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")!, signature: "MEUCIQDde3Np", timestamp: 1_800_000_000_000
        ))

        _ = try await h.purchases.purchase(productId: "com.app.yearly", promotionalOffer: offer)
        let options = try XCTUnwrap(h.store.purchases.first?.1)
        XCTAssertEqual(options.promotionalOffer, offer)
        XCTAssertEqual(options.appAccountToken?.uuidString.lowercased(), "a834e82f-da33-5e3b-95dc-2978401465f4",
                       "StoreKit checks the signature against the purchase's appAccountToken")
    }

    func testPromotionalOfferErrorsAreMappedToClearCodes() async throws {
        typealias C = BillingBearAPI.PromotionalOfferErrorCode
        let cases: [(MockReply, PurchaseErrorCode, Int, String?)] = [
            (.json(400, Self.errorBody(C.invalidRequest, "offerId is required")), .validationError, 400, C.invalidRequest),
            (.json(400, Self.errorBody(C.appAccountTokenMismatch, "appAccountToken is not the one derived for this subscriber")), .validationError, 400, C.appAccountTokenMismatch),
            (.json(400, Self.errorBody(C.productNotInProject, "productId is not an Apple product of this project")), .productNotFound, 400, C.productNotInProject),
            (.json(404, Self.errorBody(C.offerNotConfigured, "That offer is not configured for this project")), .productNotFound, 404, C.offerNotConfigured),
            (.json(404, Self.errorBody(C.subscriberNotFound, "Unknown subscriber")), .validationError, 404, C.subscriberNotFound),
            (.json(409, Self.errorBody(C.appleIapKeyMissing, "No App Store In-App Purchase key is configured for this app")), .notConfigured, 409, C.appleIapKeyMissing),
            (.json(409, Self.errorBody(C.appleIapKeyInvalid, "The App Store In-App Purchase key configured for this app cannot be read")), .notConfigured, 409, C.appleIapKeyInvalid),
            (.json(429, ""), .networkError, 429, nil),
            (.json(429, Self.errorBody(C.rateLimited, "Too many promotional offer requests")), .networkError, 429, C.rateLimited),
            (.json(401, #"{"error":{"error":"Unauthorized","description":"end-user token required"}}"#), .notConfigured, 401, nil),
            (.networkError, .networkError, 0, nil),
        ]
        for (reply, code, status, serverCode) in cases {
            let h = await Harness.make(observe: false) { request, _ in
                request.path == Self.signaturePath ? reply : .json(200, Fixture.entitlements(premium: false))
            }
            do {
                _ = try await h.purchases.getPromotionalOffer(productId: "com.app.yearly", offerId: "comeback50")
                XCTFail("expected \(code) for \(reply)")
            } catch let error as PurchasesError {
                XCTAssertEqual(error.code, code, "\(reply)")
                XCTAssertEqual(error.statusCode, status, "\(reply)")
                XCTAssertEqual(error.serverCode, serverCode, "\(reply)")
                XCTAssertFalse(error.message.isEmpty)
            }
            XCTAssertEqual(h.http.requests("POST", Self.signaturePath).count, 1, "never retried: the customer is waiting")
        }
    }

    func testAnInvalidRequestCarriesTheServersMessage() async throws {
        let h = await Harness.make(observe: false) { request, _ in
            request.path == Self.signaturePath
                ? .json(400, Self.errorBody("invalid_request", "appAccountToken must be a UUID"))
                : .json(200, Fixture.entitlements(premium: false))
        }
        do {
            _ = try await h.purchases.getPromotionalOffer(productId: "com.app.yearly", offerId: "comeback50")
            XCTFail()
        } catch let error as PurchasesError {
            XCTAssertTrue(error.message.contains("appAccountToken must be a UUID"), error.message)
        }
    }

    func testTheEndUserTokenIsSentForTheSubscriberWhenTheAppProvidesOne() async throws {
        let asked = RequestBox()
        let provider: EndUserTokenProvider = { appUserId in
            asked.append(PromotionalOfferSigningRequest(productId: "", offerId: "", appUserId: appUserId, applicationUsername: "", bundleId: nil))
            return "eut_for_\(appUserId)"
        }
        let h = await Harness.make(options: PurchasesOptions(endUserTokenProvider: provider), observe: false) { request, _ in
            if request.path == Self.signaturePath { return .json(200, Self.signed) }
            if request.path.hasPrefix("/v1/customer-center/") { return .json(200, "{}") }
            return .json(200, Fixture.entitlements(premium: false))
        }

        _ = try await h.purchases.getPromotionalOffer(productId: "com.app.yearly", offerId: "comeback50")
        try await h.purchases.ccRefund(subscriptionId: "sub-1")

        XCTAssertEqual(h.http.requests("POST", Self.signaturePath).first?.headers[BillingBearAPI.endUserTokenHeader], "eut_for_u1")
        XCTAssertEqual(h.http.requests("POST", "/v1/customer-center/u1/subscriptions/sub-1/refund").first?.headers[BillingBearAPI.endUserTokenHeader], "eut_for_u1")
        XCTAssertEqual(asked.all.map(\.appUserId), ["u1", "u1"])
    }

    func testAFailingEndUserTokenProviderFailsTheCallWithoutSendingIt() async throws {
        struct Unavailable: Error {}
        let provider: EndUserTokenProvider = { _ in throw Unavailable() }
        let h = await Harness.make(options: PurchasesOptions(endUserTokenProvider: provider), observe: false)
        do {
            _ = try await h.purchases.getPromotionalOffer(productId: "com.app.yearly", offerId: "comeback50")
            XCTFail("a provider failure fails the call")
        } catch let error as PurchasesError {
            XCTAssertTrue(error.message.contains("end-user token provider"), error.message)
        }
        XCTAssertTrue(h.http.requests.isEmpty)
    }

    func testASignatureForAnotherProductOrOfferIsRejected() async throws {
        let other = #"{"keyIdentifier":"K","nonce":"aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee","timestamp":1,"signature":"c2ln","applicationUsername":"a834e82f-da33-5e3b-95dc-2978401465f4","productId":"com.app.monthly","offerId":"comeback50"}"#
        let h = await Harness.make(observe: false) { request, _ in
            request.path == Self.signaturePath ? .json(200, other) : .json(200, Fixture.entitlements(premium: false))
        }
        do {
            _ = try await h.purchases.getPromotionalOffer(productId: "com.app.yearly", offerId: "comeback50")
            XCTFail("a signature for another product cannot redeem this one")
        } catch let error as PurchasesError {
            XCTAssertEqual(error.code, .validationError)
        }
    }

    func testASignatureForAnotherAccountTokenIsRejectedBeforeTheSheet() async throws {
        let foreign = #"{"keyIdentifier":"K","nonce":"aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee","timestamp":1,"signature":"c2ln","applicationUsername":"11111111-2222-3333-4444-555555555555"}"#
        let h = await Harness.make(observe: false) { request, _ in
            request.path == Self.signaturePath ? .json(200, foreign) : .json(200, Fixture.entitlements(premium: false))
        }
        do {
            _ = try await h.purchases.getPromotionalOffer(productId: "com.app.yearly", offerId: "comeback50")
            XCTFail("Apple would reject a signature for another applicationUsername")
        } catch let error as PurchasesError {
            XCTAssertEqual(error.code, .validationError)
        }
    }

    func testTheHostSignerOverridesBillingBear() async throws {
        let box = RequestBox()
        let h = await Harness.make(options: PurchasesOptions(promotionalOfferSigner: RecordingSigner(requests: box)), observe: false)
        _ = try await h.purchases.getPromotionalOffer(productId: "com.app.yearly", offerId: "comeback50")
        XCTAssertEqual(box.all.count, 1)
        XCTAssertTrue(h.http.requests.isEmpty)
    }

    func testSignerAnswerForAnotherOfferIsRejected() async throws {
        struct WrongSigner: PromotionalOfferSigner {
            func signPromotionalOffer(_ request: PromotionalOfferSigningRequest) async throws -> PromotionalOffer {
                PromotionalOffer(offerId: "other", productId: request.productId, keyIdentifier: "K", nonce: UUID(), signature: "c2ln", timestamp: 1)
            }
        }
        let h = await Harness.make(options: PurchasesOptions(promotionalOfferSigner: WrongSigner()), observe: false)
        do {
            _ = try await h.purchases.getPromotionalOffer(productId: "com.app.yearly", offerId: "comeback50")
            XCTFail("expected a mismatch")
        } catch let error as PurchasesError {
            XCTAssertEqual(error.code, .validationError)
        }
    }

    // MARK: Win-back offers

    func testWinBackOffersComeFromStoreKitAndAreRedeemedById() async throws {
        let h = await Harness.make(observe: false)
        let offer = WinBackOffer(id: "wb-3-months", displayPrice: "€1.99", price: 1.99, period: "P1M", periodCount: 3, paymentMode: "payAsYouGo")
        h.store.setWinBack(["com.app.monthly": [offer]])
        h.store.setPurchaseHandler { productId, _ in .success(.verified(Fixture.transaction("tx-wb", product: productId))) }

        let offers = try await h.purchases.eligibleWinBackOffers(forProductId: "com.app.monthly")
        XCTAssertEqual(offers, [offer])

        _ = try await h.purchases.purchase(productId: "com.app.monthly", winBackOffer: offer)
        XCTAssertEqual(h.store.purchases.first?.1.winBackOfferId, "wb-3-months")
        XCTAssertEqual(h.store.finishedIds, ["tx-wb"])
    }

    // MARK: Offer codes

    func testOfferCodeSheetIsPresentedAndTheRedemptionArrivesAsAnUpdate() async throws {
        let h = await Harness.make()
        try await h.purchases.presentCodeRedemptionSheet()
        XCTAssertEqual(h.store.codeSheets, 1)

        h.store.emit(.verified(Fixture.transaction("tx-code")))
        await eventually { h.store.finishedIds == ["tx-code"] }
    }

    // MARK: Refunds

    func testRefundRequestsGoToTheStoreForTheGivenProductOrTransaction() async throws {
        let h = await Harness.make(observe: false)
        h.store.setRefundStatus(.userCancelled)

        let byProduct = try await h.purchases.beginRefundRequest(forProduct: "com.app.monthly")
        let byTransaction = try await h.purchases.beginRefundRequest(forTransactionId: "123")

        XCTAssertEqual([byProduct, byTransaction], [.userCancelled, .userCancelled])
        XCTAssertEqual(h.store.refunds, ["product:com.app.monthly", "transaction:123"])
        XCTAssertTrue(h.http.requests.isEmpty)
    }

    // MARK: Source compatibility with 1.0.0

    func testOneZeroZeroSignaturesStillResolve() async throws {
        let h = await Harness.make(observe: false) { _, _ in .json(200, Fixture.entitlements(premium: true)) }
        // Function references keep their 1.0.0 types.
        let fetch: () async throws -> CustomerInfo = h.purchases.customerInfo
        let info = try await fetch()
        XCTAssertTrue(info.isPremium)
        let untypedFetch = h.purchases.customerInfo
        _ = try await untypedFetch()
        // Resolves to purchase(product:), as in 1.0.0 (an ambiguity here fails the build).
        let untypedPurchase = h.purchases.purchase
        _ = untypedPurchase
        let untypedInit = BillingBearAPI.init
        _ = untypedInit("pk_test", "https://api.billingbear.io", nil, .shared, { _ in })
        // (configure(…) is synchronous on the actor, so it cannot be referenced from outside: only calls,
        // which the 1.0.0 overloads keep resolving.)
        let p = Purchases(defaults: h.defaults)
        await p.configure(apiKey: "pk_test", appUserId: "u", baseURL: "https://api.billingbear.io", bundleId: nil, speed: .init(prefetchEnabled: false), country: nil)
        await p.configure(api: BillingBearAPI(apiKey: "pk_test"), appUserId: "u", cache: nil, speed: .init(prefetchEnabled: false))
        let makeAPI: (String, String, String?, URLSession, @escaping @Sendable (UInt64) async -> Void) -> BillingBearAPI =
            BillingBearAPI.init(apiKey:baseURL:bundleId:session:sleep:)
        _ = makeAPI
        let makeInfo: (String, Bool, [String: EntitlementInfo], SubscriptionInfo?) -> CustomerInfo =
            CustomerInfo.init(appUserId:isPremium:entitlements:activeSubscription:)
        XCTAssertEqual(makeInfo("u", false, [:], nil).appUserId, "u")
        let makeSubscription: (SubscriptionStatus, String, String, String?, String?, String?, Bool, Bool) -> SubscriptionInfo =
            SubscriptionInfo.init(status:store:productId:expiresAt:startsAt:cancelledAt:willRenew:isGracePeriod:)
        XCTAssertEqual(makeSubscription(.active, "apple", "p", nil, nil, nil, true, false).productId, "p")
    }

    // MARK: Not configured

    func testStoreFeaturesRequireConfigure() async throws {
        let purchases = Purchases(defaults: UserDefaults(suiteName: "bb.nc.\(UUID().uuidString)")!)
        do {
            try await purchases.presentCodeRedemptionSheet()
            XCTFail()
        } catch let error as PurchasesError {
            XCTAssertEqual(error.code, .notConfigured)
        }
        let eligibility = await purchases.checkTrialOrIntroDiscountEligibility(productIdentifiers: ["p", "p"])
        XCTAssertEqual(eligibility["p"]?.status, .unknown)
    }
}
