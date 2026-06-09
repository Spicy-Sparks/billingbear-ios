import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import BillingBear

// MARK: - URLProtocol stub
//
// Intercepts every request issued by the test URLSession so no real network I/O occurs.
// A handler closure inspects the outgoing URLRequest and returns the (status, body) to reply with.
final class StubURLProtocol: URLProtocol {
    // Handler receives the request; returns status code + response body data.
    static var handler: ((URLRequest) throws -> (Int, Data))?
    // Captures the most recent request body so tests can assert on what was sent.
    static var lastRequest: URLRequest?
    static var lastBody: Data?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        StubURLProtocol.lastRequest = request
        // URLProtocol strips httpBody for stream-based bodies; reconstruct from httpBodyStream.
        if let body = request.httpBody {
            StubURLProtocol.lastBody = body
        } else if let stream = request.httpBodyStream {
            StubURLProtocol.lastBody = StubURLProtocol.readStream(stream)
        } else {
            StubURLProtocol.lastBody = nil
        }

        guard let handler = StubURLProtocol.handler else {
            client?.urlProtocol(self, didFailWithError: NSError(domain: "StubURLProtocol", code: -1))
            return
        }
        do {
            let (status, data) = try handler(request)
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: status,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}

    private static func readStream(_ stream: InputStream) -> Data {
        stream.open()
        defer { stream.close() }
        var data = Data()
        let bufferSize = 1024
        var buffer = [UInt8](repeating: 0, count: bufferSize)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: bufferSize)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return data
    }
}

final class BillingBearTests: XCTestCase {

    private func makeAPI(baseURL: String = "https://api.billingbear.io") -> BillingBearAPI {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        let session = URLSession(configuration: config)
        return BillingBearAPI(apiKey: "pk_test_123", baseURL: baseURL, session: session)
    }

    override func tearDown() {
        StubURLProtocol.handler = nil
        StubURLProtocol.lastRequest = nil
        StubURLProtocol.lastBody = nil
        super.tearDown()
    }

    // MARK: Entitlement decoding

    func testFetchEntitlementsDecodesAndMaps() async throws {
        let json = """
        {
          "userId": "user-1",
          "isPremium": true,
          "entitlements": ["premium", "pro"],
          "subscription": {
            "status": 1,
            "store": 2,
            "productId": "com.app.premium",
            "expiresAt": "2026-12-31T23:59:59Z",
            "startsAt": "2026-01-01T00:00:00Z",
            "cancelledAt": null,
            "willRenew": true,
            "isGracePeriod": false
          }
        }
        """
        StubURLProtocol.handler = { _ in (200, Data(json.utf8)) }

        let api = makeAPI()
        let info = try await api.fetchEntitlements(appUserId: "user-1")

        XCTAssertEqual(info.appUserId, "user-1")
        XCTAssertTrue(info.isPremium)
        XCTAssertEqual(info.entitlements.count, 2)
        XCTAssertEqual(info.entitlements["premium"]?.isActive, true)
        XCTAssertEqual(info.entitlements["premium"]?.expiresAt, "2026-12-31T23:59:59Z")
        XCTAssertEqual(info.activeSubscription?.status, .active)
        XCTAssertEqual(info.activeSubscription?.store, "apple")
        XCTAssertEqual(info.activeSubscription?.productId, "com.app.premium")
        XCTAssertEqual(info.activeSubscription?.willRenew, true)
        XCTAssertEqual(info.activeSubscription?.isGracePeriod, false)
    }

    func testFetchEntitlementsNoSubscription() async throws {
        let json = """
        { "userId": null, "isPremium": false, "entitlements": [], "subscription": null }
        """
        StubURLProtocol.handler = { _ in (200, Data(json.utf8)) }

        let api = makeAPI()
        let info = try await api.fetchEntitlements(appUserId: "anon")
        XCTAssertFalse(info.isPremium)
        XCTAssertTrue(info.entitlements.isEmpty)
        XCTAssertNil(info.activeSubscription)
    }

    func testFetchEntitlementsSendsBearerAuthAndPath() async throws {
        StubURLProtocol.handler = { _ in
            (200, Data("{ \"userId\": null, \"isPremium\": false, \"entitlements\": [], \"subscription\": null }".utf8))
        }
        let api = makeAPI()
        _ = try await api.fetchEntitlements(appUserId: "user 1")

        let req = try XCTUnwrap(StubURLProtocol.lastRequest)
        XCTAssertEqual(req.value(forHTTPHeaderField: "Authorization"), "Bearer pk_test_123")
        // appUserId must be percent-encoded into the path. (URL.path returns the
        // DECODED path, so assert against the encoded absolute URL.)
        XCTAssertEqual(req.url?.absoluteString, "https://api.billingbear.io/subscription/entitlements/user%201")
    }

    // MARK: Error mapping

    func testErrorBodyMappedToValidationError() async throws {
        let json = "{ \"error\": { \"error\": \"bad key\" } }"
        StubURLProtocol.handler = { _ in (401, Data(json.utf8)) }

        let api = makeAPI()
        do {
            _ = try await api.fetchEntitlements(appUserId: "x")
            XCTFail("Expected error")
        } catch let error as PurchasesError {
            XCTAssertEqual(error.code, .validationError)
            XCTAssertEqual(error.statusCode, 401)
            XCTAssertEqual(error.message, "bad key")
        }
    }

    // MARK: Checkout request body

    func testCreateCheckoutSessionBuildsBodyAndDecodes() async throws {
        StubURLProtocol.handler = { _ in
            (200, Data("{ \"url\": \"https://checkout.stripe.com/abc\", \"sessionId\": \"cs_123\" }".utf8))
        }
        let api = makeAPI()
        let req = CheckoutSessionRequest(
            priceId: "price_1ABC",
            successUrl: "https://app.example.com/ok",
            cancelUrl: "https://app.example.com/no",
            metadata: ["plan": "pro"]
        )
        let session = try await api.createCheckoutSession(appUserId: "user-42", request: req)

        XCTAssertEqual(session.url, "https://checkout.stripe.com/abc")
        XCTAssertEqual(session.sessionId, "cs_123")

        // Assert the POST body merged appUserId with the request fields.
        let request = try XCTUnwrap(StubURLProtocol.lastRequest)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.path, "/v1/checkout/session")

        let body = try XCTUnwrap(StubURLProtocol.lastBody)
        let obj = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(obj["appUserId"] as? String, "user-42")
        XCTAssertEqual(obj["priceId"] as? String, "price_1ABC")
        XCTAssertEqual(obj["successUrl"] as? String, "https://app.example.com/ok")
        XCTAssertEqual(obj["cancelUrl"] as? String, "https://app.example.com/no")
        XCTAssertEqual((obj["metadata"] as? [String: Any])?["plan"] as? String, "pro")
    }

    // MARK: Login / Logout

    func testLoginReturnsResolvedAppUserId() async throws {
        StubURLProtocol.handler = { req in
            if req.url?.path == "/v1/customers/login" {
                return (200, Data("{ \"appUserId\": \"firebase-uid\", \"wasMerged\": true }".utf8))
            }
            return (200, Data("{ \"userId\": \"firebase-uid\", \"isPremium\": true, \"entitlements\": [\"premium\"], \"subscription\": null }".utf8))
        }
        let api = makeAPI()
        let resolved = try await api.login(anonymousAppUserId: "anon-1", identifiedAppUserId: "firebase-uid")
        XCTAssertEqual(resolved, "firebase-uid")
    }

    func testLogoutReturnsNewAnonymousId() async throws {
        StubURLProtocol.handler = { _ in
            (200, Data("{ \"newAnonymousAppUserId\": \"$anon:new\" }".utf8))
        }
        let api = makeAPI()
        let newId = try await api.logout(appUserId: "firebase-uid")
        XCTAssertEqual(newId, "$anon:new")
    }

    // MARK: Validate flow

    func testValidatePurchasePostsConfirmThenRefetches() async throws {
        var sawConfirm = false
        StubURLProtocol.handler = { req in
            if req.url?.path == "/subscription/confirm" {
                sawConfirm = true
                return (200, Data("{}".utf8))
            }
            return (200, Data("{ \"userId\": \"u\", \"isPremium\": true, \"entitlements\": [\"premium\"], \"subscription\": null }".utf8))
        }
        let api = makeAPI()
        let validate = ValidateRequest(
            appUserId: "u",
            providerType: ProviderType.apple,
            transactionId: "1000",
            originalTransactionId: "1000",
            productId: "com.app.premium"
        )
        let info = try await api.validatePurchase(appUserId: "u", request: validate)
        XCTAssertTrue(sawConfirm)
        XCTAssertTrue(info.isPremium)
    }

    // MARK: Paywall 404 -> nil

    func testGetPaywallReturnsNilOn404() async throws {
        StubURLProtocol.handler = { _ in (404, Data("{}".utf8)) }
        let api = makeAPI()
        let res = try await api.getPaywall(identifier: "main")
        XCTAssertNil(res)
    }

    func testGetPaywallDecodesDocument() async throws {
        let json = """
        {
          "identifier": "main",
          "versionId": "v_123",
          "versionNumber": 3,
          "publishedAt": "2026-01-01T00:00:00Z",
          "document": {
            "version": 1,
            "layout": "minimal",
            "theme": { "primaryColor": "#5b5bd6", "background": "#0a0a0a", "textColor": "#ffffff" },
            "header": { "title": "Go Premium" },
            "features": [{ "icon": "star", "text": "Unlimited" }],
            "products": [{ "identifier": "yearly", "label": "Yearly", "highlight": true }],
            "cta": { "text": "Continue", "shape": "pill" },
            "footer": { "restoreText": "Restore" }
          }
        }
        """
        StubURLProtocol.handler = { _ in (200, Data(json.utf8)) }
        let api = makeAPI()
        let res = try await api.getPaywall(identifier: "main", appUserId: "u1")
        XCTAssertEqual(res?.identifier, "main")
        XCTAssertEqual(res?.versionNumber, 3)
        XCTAssertEqual(res?.document.layout, .minimal)
        XCTAssertEqual(res?.document.header.title, "Go Premium")
        XCTAssertEqual(res?.document.products.first?.highlight, true)
        XCTAssertEqual(res?.document.cta.shape, "pill")
    }

    // MARK: Paywall document transforms

    func testInterpolateResolvesVariables() {
        let out = PaywallTransforms.interpolate("Hi {{ user.firstName }}!", ["user.firstName": "Marco"])
        XCTAssertEqual(out, "Hi Marco!")
    }

    func testInterpolateLeavesUnknownPlaceholder() {
        let out = PaywallTransforms.interpolate("Hi {{missing}}", ["x": "y"])
        XCTAssertEqual(out, "Hi {{missing}}")
    }

    func testProductVisibilityFiltersByPlatform() {
        var product = PaywallProduct(identifier: "p", label: "P")
        product.visibility = PaywallProductVisibility(platforms: ["android"])
        let ctx = PaywallUserContext(platform: "ios")
        XCTAssertFalse(PaywallTransforms.isProductVisible(product, ctx))
    }

    // MARK: Base URL trailing-slash normalisation

    func testBaseURLTrailingSlashStripped() async throws {
        StubURLProtocol.handler = { _ in
            (200, Data("{ \"userId\": null, \"isPremium\": false, \"entitlements\": [], \"subscription\": null }".utf8))
        }
        let api = makeAPI(baseURL: "https://api.billingbear.io/")
        _ = try await api.fetchEntitlements(appUserId: "u")
        let req = try XCTUnwrap(StubURLProtocol.lastRequest)
        XCTAssertEqual(req.url?.absoluteString, "https://api.billingbear.io/subscription/entitlements/u")
    }

    // MARK: Anonymous id persistence (Purchases actor)

    func testAnonymousIdPersistsAcrossConfigure() async throws {
        let suite = try XCTUnwrap(UserDefaults(suiteName: "bb.tests.\(UUID().uuidString)"))
        defer { suite.removePersistentDomain(forName: "bb.tests") }

        let p1 = Purchases(defaults: suite)
        let api = makeAPI()
        await p1.configure(api: api)
        let id1 = await p1.appUserId
        XCTAssertFalse(id1.isEmpty)
        let anon1 = await p1.isAnonymous
        XCTAssertTrue(anon1)

        // A second instance backed by the same defaults must reuse the persisted id.
        let p2 = Purchases(defaults: suite)
        await p2.configure(api: api)
        let id2 = await p2.appUserId
        XCTAssertEqual(id1, id2)
    }

    func testConfigureWithExplicitAppUserIdIsNotAnonymous() async throws {
        let suite = try XCTUnwrap(UserDefaults(suiteName: "bb.tests.\(UUID().uuidString)"))
        let p = Purchases(defaults: suite)
        let api = makeAPI()
        await p.configure(api: api, appUserId: "known-user")
        let id = await p.appUserId
        let anon = await p.isAnonymous
        XCTAssertEqual(id, "known-user")
        XCTAssertFalse(anon)
    }

    // MARK: - Component catalog: countdown helpers (pure)

    func testCountdownComponentsBreaksDownInterval() {
        // 2 days, 3 hours, 4 minutes, 5 seconds.
        let total = 2 * 86400 + 3 * 3600 + 4 * 60 + 5
        let c = PaywallTransforms.countdownComponents(remaining: total)
        XCTAssertEqual(c.days, 2)
        XCTAssertEqual(c.hours, 3)
        XCTAssertEqual(c.minutes, 4)
        XCTAssertEqual(c.seconds, 5)
    }

    func testCountdownComponentsClampsNegativeToZero() {
        let c = PaywallTransforms.countdownComponents(remaining: -500)
        XCTAssertEqual(c.days, 0)
        XCTAssertEqual(c.hours, 0)
        XCTAssertEqual(c.minutes, 0)
        XCTAssertEqual(c.seconds, 0)
    }

    func testFormatCountdownDaysVariant() {
        // ≥ a day → "Nd HHh MMm" with zero-padded hour/minute. Mirrors the web formatter.
        let total = 2 * 86400 + 3 * 3600 + 4 * 60 + 5
        XCTAssertEqual(PaywallTransforms.formatCountdown(remaining: total), "2d 03h 04m")
    }

    func testFormatCountdownHMSVariant() {
        // < a day → "HH:MM:SS".
        let total = 1 * 3600 + 2 * 60 + 9
        XCTAssertEqual(PaywallTransforms.formatCountdown(remaining: total), "01:02:09")
    }

    func testParseISODateWithAndWithoutFractionalSeconds() {
        let plain = PaywallTransforms.parseISODate("2026-01-01T00:00:00Z")
        XCTAssertNotNil(plain)
        let fractional = PaywallTransforms.parseISODate("2026-01-01T00:00:00.500Z")
        XCTAssertNotNil(fractional)
        // The fractional timestamp is 0.5s after the plain one.
        XCTAssertEqual(fractional!.timeIntervalSince(plain!), 0.5, accuracy: 0.001)
        XCTAssertNil(PaywallTransforms.parseISODate("not-a-date"))
        XCTAssertNil(PaywallTransforms.parseISODate(nil))
    }

    // MARK: - Component catalog: comparison-cell logic (pure)

    func testComparisonCellDefaultsToIncludedWhenUnset() {
        let product = PaywallProduct(identifier: "p", label: "Pro")
        // No featureMatches at all → every row is ✓.
        XCTAssertTrue(PaywallTransforms.comparisonCellOn(product, featureIndex: 0))
        XCTAssertTrue(PaywallTransforms.comparisonCellOn(product, featureIndex: 7))
    }

    func testComparisonCellExplicitFalseIsExcluded() {
        var product = PaywallProduct(identifier: "p", label: "Basic")
        product.featureMatches = ["1": false, "2": true]
        XCTAssertTrue(PaywallTransforms.comparisonCellOn(product, featureIndex: 0))  // unset → ✓
        XCTAssertFalse(PaywallTransforms.comparisonCellOn(product, featureIndex: 1)) // false → ×
        XCTAssertTrue(PaywallTransforms.comparisonCellOn(product, featureIndex: 2))  // true → ✓
    }

    // MARK: - Component catalog: model decode (additive fields)

    func testDecodeComparisonTableDocumentWithFeatureMatches() async throws {
        let json = """
        {
          "identifier": "compare",
          "versionId": "v1",
          "versionNumber": 1,
          "publishedAt": "2026-01-01T00:00:00Z",
          "document": {
            "version": 1,
            "layout": "comparison-table",
            "theme": { "primaryColor": "#5b5bd6", "background": "#0a0a0a", "textColor": "#ffffff" },
            "header": { "title": "Compare plans" },
            "features": [
              { "icon": "check", "text": "Ad-free" },
              { "icon": "cloud", "text": "Cloud sync" }
            ],
            "products": [
              { "identifier": "free", "label": "Free", "featureMatches": { "0": true, "1": false } },
              { "identifier": "pro", "label": "Pro", "highlight": true, "featureMatches": { "0": true, "1": true } }
            ],
            "cta": { "text": "Upgrade" },
            "footer": {}
          }
        }
        """
        StubURLProtocol.handler = { _ in (200, Data(json.utf8)) }
        let api = makeAPI()
        let res = try await api.getPaywall(identifier: "compare")
        let doc = try XCTUnwrap(res?.document)
        XCTAssertEqual(doc.layout, .comparisonTable)
        XCTAssertEqual(doc.features.count, 2)
        let pro = try XCTUnwrap(doc.products.first(where: { $0.identifier == "pro" }))
        XCTAssertTrue(PaywallTransforms.comparisonCellOn(pro, featureIndex: 1))
        let free = try XCTUnwrap(doc.products.first(where: { $0.identifier == "free" }))
        XCTAssertFalse(PaywallTransforms.comparisonCellOn(free, featureIndex: 1))
    }

    func testDecodeTrialToggleTabsAndTimeline() throws {
        let json = """
        {
          "version": 1,
          "layout": "vertical-features",
          "theme": { "primaryColor": "#5b5bd6", "background": "#0a0a0a", "textColor": "#ffffff" },
          "header": { "title": "Go Premium" },
          "features": [{ "icon": "star", "text": "Unlimited" }],
          "products": [
            { "identifier": "trial_yearly", "label": "Yearly", "trialDays": 7 },
            { "identifier": "yearly", "label": "Yearly (no trial)" }
          ],
          "cta": { "text": "Continue" },
          "footer": {},
          "trialToggle": {
            "label": "Enable free trial",
            "caption": "7 days free, cancel anytime",
            "defaultOn": true
          },
          "tabs": {
            "tabs": [
              { "id": "personal", "label": "Personal", "productIds": ["trial_yearly"] },
              { "id": "family", "label": "Family", "badge": "Popular", "productIds": ["yearly"] }
            ],
            "defaultTabId": "personal"
          },
          "timeline": {
            "heading": "How your trial works",
            "steps": [
              { "label": "Today", "title": "Full access", "description": "Everything unlocked", "icon": "lock" },
              { "label": "Day 7", "title": "Billing starts", "description": "Cancel anytime before" }
            ]
          }
        }
        """
        let doc = try JSONDecoder().decode(PaywallDocument.self, from: Data(json.utf8))

        let toggle = try XCTUnwrap(doc.trialToggle)
        XCTAssertEqual(toggle.label, "Enable free trial")
        XCTAssertEqual(toggle.defaultOn, true)

        let tabs = try XCTUnwrap(doc.tabs)
        XCTAssertEqual(tabs.tabs.count, 2)
        XCTAssertEqual(tabs.defaultTabId, "personal")
        XCTAssertEqual(tabs.tabs[1].badge, "Popular")
        XCTAssertEqual(tabs.tabs[0].productIds, ["trial_yearly"])

        let timeline = try XCTUnwrap(doc.timeline)
        XCTAssertEqual(timeline.heading, "How your trial works")
        XCTAssertEqual(timeline.steps.count, 2)
        XCTAssertEqual(timeline.steps.first?.label, "Today")
        XCTAssertEqual(timeline.steps.first?.icon, "lock")
        XCTAssertNil(timeline.steps[1].icon)
    }

    func testDecodeUrgencyWithEndsAtForCountdown() throws {
        let json = """
        {
          "version": 1,
          "layout": "minimal",
          "theme": { "primaryColor": "#5b5bd6", "background": "#0a0a0a", "textColor": "#ffffff" },
          "header": { "title": "Sale" },
          "features": [],
          "products": [{ "identifier": "y", "label": "Yearly" }],
          "cta": { "text": "Buy" },
          "footer": {},
          "urgency": { "bannerText": "Black Friday", "endsAt": "2099-01-01T00:00:00Z", "tone": "discount" }
        }
        """
        let doc = try JSONDecoder().decode(PaywallDocument.self, from: Data(json.utf8))
        let urgency = try XCTUnwrap(doc.urgency)
        XCTAssertEqual(urgency.bannerText, "Black Friday")
        XCTAssertEqual(urgency.tone, "discount")
        let deadline = try XCTUnwrap(PaywallTransforms.parseISODate(urgency.endsAt))
        XCTAssertGreaterThan(deadline.timeIntervalSinceNow, 0)
    }

    // MARK: - Backwards compatibility: documents without the new fields still decode

    func testDecodeLegacyDocumentLeavesNewFieldsNil() throws {
        let json = """
        {
          "version": 1,
          "layout": "vertical-features",
          "theme": { "primaryColor": "#5b5bd6", "background": "#0a0a0a", "textColor": "#ffffff" },
          "header": { "title": "Go Premium" },
          "features": [{ "icon": "star", "text": "Unlimited" }],
          "products": [{ "identifier": "yearly", "label": "Yearly" }],
          "cta": { "text": "Continue" },
          "footer": {}
        }
        """
        let doc = try JSONDecoder().decode(PaywallDocument.self, from: Data(json.utf8))
        XCTAssertNil(doc.trialToggle)
        XCTAssertNil(doc.tabs)
        XCTAssertNil(doc.timeline)
        XCTAssertNil(doc.urgency)
    }

    // MARK: - Page-scoped timeline carries through pageToDocument

    func testPageToDocumentCarriesPageTimeline() throws {
        let json = """
        {
          "version": 1,
          "layout": "vertical-features",
          "theme": { "primaryColor": "#5b5bd6", "background": "#0a0a0a", "textColor": "#ffffff" },
          "header": { "title": "Welcome" },
          "features": [],
          "products": [{ "identifier": "y", "label": "Yearly" }],
          "cta": { "text": "Continue" },
          "footer": {},
          "timeline": { "steps": [{ "title": "Doc-level step" }] },
          "pages": [
            { "id": "p1", "header": { "title": "Intro" }, "timeline": { "steps": [{ "title": "Page step" }] } },
            { "id": "p2", "header": { "title": "Pricing" } }
          ]
        }
        """
        let doc = try JSONDecoder().decode(PaywallDocument.self, from: Data(json.utf8))
        let pages = try XCTUnwrap(doc.pages)

        // Page 1 overrides the timeline.
        let page1Doc = PaywallTransforms.pageToDocument(doc, pages[0])
        XCTAssertEqual(page1Doc.timeline?.steps.first?.title, "Page step")
        XCTAssertEqual(page1Doc.header.title, "Intro")

        // Page 2 has no timeline → falls through to the document-level one.
        let page2Doc = PaywallTransforms.pageToDocument(doc, pages[1])
        XCTAssertEqual(page2Doc.timeline?.steps.first?.title, "Doc-level step")
    }
}
