import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import BillingBear

// MARK: - Speed-layer integration tests (Purchases actor + cache + injected network/clock)
//
// Drives the public speed-layer surface end-to-end with an injected URLSession (StubURLProtocol),
// an injected PaywallCache (temp dir + fixed/advanceable clock), and a counting network so each
// assertion can prove "zero network on the hot path" / "background revalidate fired" / "offline
// serves cache". No app-foreground observer is registered (the test-seam configure skips it), so
// these stay deterministic.

final class SpeedLayerTests: XCTestCase {

    private final class TestClock: @unchecked Sendable {
        private let lock = NSLock()
        private var current: Date
        init(_ start: Date) { current = start }
        func now() -> Date { lock.lock(); defer { lock.unlock() }; return current }
        func advance(_ s: TimeInterval) { lock.lock(); current = current.addingTimeInterval(s); lock.unlock() }
        var fn: @Sendable () -> Date { { [weak self] in self?.now() ?? Date() } }
    }

    private var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("bbspeed-tests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() {
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
        StubURLProtocol.handler = nil
        StubURLProtocol.lastRequest = nil
        super.tearDown()
    }

    // MARK: Helpers

    private func makeAPI() -> BillingBearAPI {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        return BillingBearAPI(apiKey: "pk_test_123", baseURL: "https://api.billingbear.io", session: URLSession(configuration: config))
    }

    private func makeCache(clock: TestClock, project: String = "pk_test_123") -> PaywallCache {
        PaywallCache(store: FilePaywallCacheStore(baseDirectory: tempDir), project: project, now: clock.fn)
    }

    private func paywallEnvelope(identifier: String, version: Int, title: String) -> String {
        """
        {
          "identifier": "\(identifier)",
          "versionId": "v_\(version)", "versionNumber": \(version),
          "publishedAt": "2026-01-01T00:00:00Z",
          "document": {
            "version": 1, "layout": "minimal",
            "theme": { "primaryColor": "#5b5bd6", "background": "#0a0a0a", "textColor": "#ffffff" },
            "header": { "title": "\(title)" },
            "features": [], "products": [{ "identifier": "yearly", "label": "Yearly" }],
            "cta": { "text": "Continue" }, "footer": {}
          }
        }
        """
    }

    private func offeringsJSON(currentId: String) -> String {
        """
        { "currentOfferingId": "\(currentId)", "offerings": [] }
        """
    }

    private func decodeResponse(_ id: String, version: Int = 1, title: String = "T") throws -> PaywallResponse {
        try JSONDecoder().decode(PaywallResponse.self, from: Data(paywallEnvelope(identifier: id, version: version, title: title).utf8))
    }

    /// Wait for an actor task to drain by hopping through the actor (FIFO) a few times. Cheaper and
    /// more reliable than a fixed sleep for "did the background revalidate land yet".
    private func drain(_ purchases: Purchases, _ times: Int = 4) async {
        for _ in 0..<times { _ = await purchases.appUserId }
    }

    // MARK: prefetch writes the cache

    func testPrefetchWritesOfferingsAndDeclaredPaywallsToCache() async throws {
        let clock = TestClock(Date(timeIntervalSince1970: 1_000_000))
        let cache = makeCache(clock: clock)
        let api = makeAPI()

        let counter = RequestCounter()
        StubURLProtocol.handler = { req in
            counter.bump(req.url?.path ?? "")
            if req.url?.path.contains("/offerings") == true {
                return (200, Data(self.offeringsJSON(currentId: "default").utf8))
            }
            if req.url?.path.contains("/v1/paywalls/by-identifier/main") == true {
                return (200, Data(self.paywallEnvelope(identifier: "main", version: 7, title: "Prefetched").utf8))
            }
            return (404, Data("{}".utf8))
        }

        let purchases = Purchases(defaults: try uniqueDefaults())
        var speed = SpeedLayerConfig()
        speed.prefetchIdentifiers = ["main"]
        speed.prewarmAssets = false  // keep the test network deterministic (no extra asset GETs)
        await purchases.configure(api: api, appUserId: "u1", cache: cache, speed: speed)

        let errors = await purchases.prefetch()
        XCTAssertTrue(errors.isEmpty, "prefetch should not error: \(errors)")

        // Both offerings and the declared paywall are now in the persistent cache.
        XCTAssertEqual(cache.anyOfferings()?.currentOfferingId, "default")
        XCTAssertEqual(cache.anyPaywall("main")?.versionNumber, 7)
        XCTAssertEqual(cache.anyPaywall("main")?.document.header.title, "Prefetched")
    }

    func testPrefetchSurfacesNetworkErrorsNotSwallowed() async throws {
        let clock = TestClock(Date())
        let cache = makeCache(clock: clock)
        let api = makeAPI()
        // Offerings succeeds; the declared paywall 500s on every retry → surfaced as an error.
        StubURLProtocol.handler = { req in
            if req.url?.path.contains("/offerings") == true {
                return (200, Data(self.offeringsJSON(currentId: "default").utf8))
            }
            return (500, Data("{ \"error\": { \"message\": \"boom\" } }".utf8))
        }
        let purchases = Purchases(defaults: try uniqueDefaults())
        var speed = SpeedLayerConfig()
        speed.prefetchIdentifiers = ["broken"]
        speed.prewarmAssets = false
        await purchases.configure(api: api, appUserId: "u1", cache: cache, speed: speed)

        let errors = await purchases.prefetch()
        XCTAssertFalse(errors.isEmpty, "a 5xx paywall fetch must surface, not be swallowed")
    }

    // MARK: instant present — synchronous cached read, zero network

    func testCachedPaywallReadsSynchronouslyWithZeroNetwork() async throws {
        let clock = TestClock(Date(timeIntervalSince1970: 3_000_000))
        let cache = makeCache(clock: clock)
        try cache.writePaywall("main", response: try decodeResponse("main", version: 5, title: "Cached"))

        let api = makeAPI()
        StubURLProtocol.handler = { _ in XCTFail("no network expected on the synchronous hot path"); return (500, Data()) }

        let purchases = Purchases(defaults: try uniqueDefaults())
        await purchases.configure(api: api, appUserId: "u1", cache: cache, speed: SpeedLayerConfig(prefetchEnabled: false))

        // Synchronous, no await — the instant-present getter.
        let cached = purchases.cachedPaywall("main")
        XCTAssertEqual(cached?.versionNumber, 5)
        XCTAssertEqual(cached?.document.header.title, "Cached")
    }

    // MARK: stale-while-revalidate — fresh serves instantly, no revalidate

    func testGetPaywallCachedFreshServesFromCacheNoNetwork() async throws {
        let clock = TestClock(Date(timeIntervalSince1970: 4_000_000))
        let cache = makeCache(clock: clock)
        try cache.writePaywall("main", response: try decodeResponse("main", version: 2, title: "Fresh"))

        let api = makeAPI()
        let counter = RequestCounter()
        StubURLProtocol.handler = { req in counter.bump(req.url?.path ?? ""); return (200, Data(self.paywallEnvelope(identifier: "main", version: 99, title: "Network").utf8)) }

        let purchases = Purchases(defaults: try uniqueDefaults())
        await purchases.configure(api: api, appUserId: "u1", cache: cache, speed: SpeedLayerConfig(prefetchEnabled: false, paywallTTL: 300))

        let result = await purchases.getPaywallCached("main")
        XCTAssertEqual(result.source, .freshCache)
        XCTAssertEqual(result.response?.versionNumber, 2)
        await drain(purchases)
        XCTAssertEqual(counter.total, 0, "fresh cache must not hit the network")
    }

    // MARK: stale-while-revalidate — stale serves instantly AND revalidates in background

    func testGetPaywallCachedStaleServesStaleThenRevalidates() async throws {
        let clock = TestClock(Date(timeIntervalSince1970: 6_000_000))
        let cache = makeCache(clock: clock)
        try cache.writePaywall("main", response: try decodeResponse("main", version: 1, title: "Stale"))

        let api = makeAPI()
        let counter = RequestCounter()
        StubURLProtocol.handler = { req in
            counter.bump(req.url?.path ?? "")
            return (200, Data(self.paywallEnvelope(identifier: "main", version: 42, title: "Revalidated").utf8))
        }

        let purchases = Purchases(defaults: try uniqueDefaults())
        await purchases.configure(api: api, appUserId: "u1", cache: cache, speed: SpeedLayerConfig(prefetchEnabled: false, paywallTTL: 300))

        // Push past TTL so the entry is stale.
        clock.advance(301)

        let result = await purchases.getPaywallCached("main")
        // Stale entry returned SYNCHRONOUSLY (the old version), revalidate kicked off in background.
        XCTAssertEqual(result.source, .staleCache)
        XCTAssertEqual(result.response?.versionNumber, 1, "must serve the stale copy instantly")

        // After the background revalidate drains, the cache holds the fresh network copy.
        await drain(purchases, 8)
        // Poll briefly for the async write to land.
        var revalidated = cache.anyPaywall("main")?.versionNumber
        for _ in 0..<20 where revalidated != 42 {
            try? await Task.sleep(nanoseconds: 20_000_000)
            revalidated = cache.anyPaywall("main")?.versionNumber
        }
        XCTAssertEqual(revalidated, 42, "background revalidate should refresh the cache")
        XCTAssertGreaterThan(counter.total, 0, "stale path must trigger a background network revalidate")
    }

    // MARK: miss — live fetch, source = network, cache populated

    func testGetPaywallCachedMissDoesLiveFetchAndCaches() async throws {
        let clock = TestClock(Date(timeIntervalSince1970: 7_000_000))
        let cache = makeCache(clock: clock)
        let api = makeAPI()
        StubURLProtocol.handler = { _ in (200, Data(self.paywallEnvelope(identifier: "fresh", version: 3, title: "Live").utf8)) }

        let purchases = Purchases(defaults: try uniqueDefaults())
        await purchases.configure(api: api, appUserId: "u1", cache: cache, speed: SpeedLayerConfig(prefetchEnabled: false))

        let result = await purchases.getPaywallCached("fresh")
        XCTAssertEqual(result.source, .network)
        XCTAssertEqual(result.response?.versionNumber, 3)
        // The live fetch populated the cache for next time.
        XCTAssertEqual(cache.anyPaywall("fresh")?.versionNumber, 3)
    }

    // MARK: offline — failing fetcher returns the cached document

    func testOfflineServesStaleCachedDocument() async throws {
        let clock = TestClock(Date(timeIntervalSince1970: 8_000_000))
        let cache = makeCache(clock: clock)
        try cache.writePaywall("main", response: try decodeResponse("main", version: 11, title: "Offline copy"))

        let api = makeAPI()
        // Simulate offline: every request fails at the transport layer.
        StubURLProtocol.handler = { _ in throw URLError(.notConnectedToInternet) }

        let purchases = Purchases(defaults: try uniqueDefaults())
        await purchases.configure(api: api, appUserId: "u1", cache: cache, speed: SpeedLayerConfig(prefetchEnabled: false, paywallTTL: 300))

        clock.advance(301)  // stale → would normally revalidate, but we're offline
        let result = await purchases.getPaywallCached("main")
        // Offline still renders the last cached doc instantly.
        XCTAssertEqual(result.source, .staleCache)
        XCTAssertEqual(result.response?.versionNumber, 11)
        XCTAssertEqual(result.response?.document.header.title, "Offline copy")
    }

    // MARK: offline + empty cache — unavailable, error surfaced not hidden as fresh

    func testOfflineWithEmptyCacheReturnsUnavailable() async throws {
        let clock = TestClock(Date())
        let cache = makeCache(clock: clock)
        let api = makeAPI()
        StubURLProtocol.handler = { _ in throw URLError(.notConnectedToInternet) }

        let purchases = Purchases(defaults: try uniqueDefaults())
        await purchases.configure(api: api, appUserId: "u1", cache: cache, speed: SpeedLayerConfig(prefetchEnabled: false))

        let result = await purchases.getPaywallCached("nope")
        XCTAssertEqual(result.source, .unavailable)
        XCTAssertNil(result.response)
    }

    // MARK: invalidation through the actor forces a refetch

    func testInvalidatePaywallCacheForcesRefetch() async throws {
        let clock = TestClock(Date(timeIntervalSince1970: 9_500_000))
        let cache = makeCache(clock: clock)
        try cache.writePaywall("main", response: try decodeResponse("main", version: 1, title: "Old"))

        let api = makeAPI()
        StubURLProtocol.handler = { _ in (200, Data(self.paywallEnvelope(identifier: "main", version: 77, title: "Refetched").utf8)) }

        let purchases = Purchases(defaults: try uniqueDefaults())
        await purchases.configure(api: api, appUserId: "u1", cache: cache, speed: SpeedLayerConfig(prefetchEnabled: false, paywallTTL: 300))

        // Before invalidation: fresh cache, version 1.
        let beforeSource = await purchases.getPaywallCached("main").source
        XCTAssertEqual(beforeSource, .freshCache)

        await purchases.invalidatePaywallCache("main")
        XCTAssertNil(purchases.cachedPaywall("main"))

        // After invalidation it's a miss → live fetch returns the new version.
        let result = await purchases.getPaywallCached("main")
        XCTAssertEqual(result.source, .network)
        XCTAssertEqual(result.response?.versionNumber, 77)
    }

    // MARK: asset URL extraction (pure, no network)

    func testAssetURLExtractionFromV1Document() throws {
        let doc = try JSONDecoder().decode(PaywallResponse.self, from: Data(
            """
            {
              "identifier": "a", "versionId": "v", "versionNumber": 1, "publishedAt": "2026-01-01T00:00:00Z",
              "document": {
                "version": 1, "layout": "hero-image",
                "theme": {
                  "primaryColor": "#fff", "background": "#000", "textColor": "#fff",
                  "backgroundType": "image", "backgroundImage": { "url": "https://cdn.example.com/bg.png" }
                },
                "header": { "title": "Hi", "logoUrl": "https://cdn.example.com/logo.png", "heroImageUrl": "https://cdn.example.com/hero.jpg" },
                "features": [], "products": [], "cta": { "text": "Go" }, "footer": {},
                "socialProof": { "testimonials": [{ "quote": "Great", "avatarUrl": "https://cdn.example.com/a.png" }] }
              }
            }
            """.utf8)).document

        let urls = PaywallAssetPrewarmer.assetURLs(in: doc).map { $0.absoluteString }.sorted()
        XCTAssertEqual(urls, [
            "https://cdn.example.com/a.png",
            "https://cdn.example.com/bg.png",
            "https://cdn.example.com/hero.jpg",
            "https://cdn.example.com/logo.png"
        ])
    }

    func testAssetExtractionDropsNonHTTPAndDeduplicates() throws {
        let doc = try JSONDecoder().decode(PaywallResponse.self, from: Data(
            """
            {
              "identifier": "a", "versionId": "v", "versionNumber": 1, "publishedAt": "2026-01-01T00:00:00Z",
              "document": {
                "version": 1, "layout": "minimal",
                "theme": { "primaryColor": "#fff", "background": "#000", "textColor": "#fff" },
                "header": { "title": "Hi", "logoUrl": "https://cdn.example.com/x.png", "heroImageUrl": "https://cdn.example.com/x.png" },
                "features": [], "products": [], "cta": { "text": "Go" }, "footer": {}
              }
            }
            """.utf8)).document
        // Same URL twice → deduped to one. (A data: or relative URL would be dropped.)
        XCTAssertEqual(PaywallAssetPrewarmer.assetURLs(in: doc).count, 1)
    }

    // MARK: setSpeedLayerConfig is additive

    func testSetSpeedLayerConfigUpdatesTTLBehaviour() async throws {
        let clock = TestClock(Date(timeIntervalSince1970: 12_000_000))
        let cache = makeCache(clock: clock)
        try cache.writePaywall("main", response: try decodeResponse("main", version: 1))

        let api = makeAPI()
        StubURLProtocol.handler = { _ in (200, Data(self.paywallEnvelope(identifier: "main", version: 50, title: "Net").utf8)) }

        let purchases = Purchases(defaults: try uniqueDefaults())
        await purchases.configure(api: api, appUserId: "u1", cache: cache, speed: SpeedLayerConfig(prefetchEnabled: false, paywallTTL: 300))

        // With TTL 300 the just-written entry is fresh.
        let freshSource = await purchases.getPaywallCached("main").source
        XCTAssertEqual(freshSource, .freshCache)

        // Shrink TTL to 0 → the same entry is now always stale → SWR returns stale.
        await purchases.setSpeedLayerConfig(SpeedLayerConfig(prefetchEnabled: false, paywallTTL: 0))
        let staleSource = await purchases.getPaywallCached("main").source
        XCTAssertEqual(staleSource, .staleCache)
    }

    // MARK: utilities

    private func uniqueDefaults() throws -> UserDefaults {
        try XCTUnwrap(UserDefaults(suiteName: "bb.speed.\(UUID().uuidString)"))
    }
}

// MARK: - Thread-safe request counter for the stubbed network

private final class RequestCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var counts: [String: Int] = [:]
    func bump(_ path: String) { lock.lock(); counts[path, default: 0] += 1; lock.unlock() }
    var total: Int { lock.lock(); defer { lock.unlock() }; return counts.values.reduce(0, +) }
}
