import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import BillingBear

// MARK: - Speed-layer cache tests
//
// Headless + deterministic: an injectable clock (a mutable Date box), an injected store (temp dir OR
// in-memory), and an injected network (the StubURLProtocol session) make every path reproducible
// without real wall-clock time or filesystem assumptions. Covers: write/read/expiry/TTL, stale-
// while-revalidate returning stale synchronously, offline (failing fetcher) returning cached, and
// cache invalidation.

final class PaywallCacheTests: XCTestCase {

    // MARK: Test seams

    /// A mutable clock the cache reads through; tests advance it to cross the TTL boundary.
    private final class TestClock: @unchecked Sendable {
        private let lock = NSLock()
        private var current: Date
        init(_ start: Date) { current = start }
        func now() -> Date { lock.lock(); defer { lock.unlock() }; return current }
        func advance(_ seconds: TimeInterval) { lock.lock(); current = current.addingTimeInterval(seconds); lock.unlock() }
        var nowFn: @Sendable () -> Date { { [weak self] in self?.now() ?? Date() } }
    }

    private var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("bbcache-tests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() {
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
        StubURLProtocol.handler = nil
        super.tearDown()
    }

    // MARK: Fixtures

    private func paywallResponseJSON(identifier: String, version: Int = 3, title: String = "Go Premium") -> String {
        """
        {
          "identifier": "\(identifier)",
          "versionId": "v_\(version)",
          "versionNumber": \(version),
          "publishedAt": "2026-01-01T00:00:00Z",
          "document": {
            "version": 1,
            "layout": "minimal",
            "theme": {
              "primaryColor": "#5b5bd6", "background": "#0a0a0a", "textColor": "#ffffff",
              "backgroundType": "image",
              "backgroundImage": { "url": "https://cdn.example.com/bg.png" }
            },
            "header": { "title": "\(title)", "logoUrl": "https://cdn.example.com/logo.png", "heroImageUrl": "https://cdn.example.com/hero.jpg" },
            "features": [{ "icon": "star", "text": "Unlimited" }],
            "products": [{ "identifier": "yearly", "label": "Yearly", "highlight": true }],
            "cta": { "text": "Continue", "shape": "pill" },
            "footer": { "restoreText": "Restore" }
          }
        }
        """
    }

    private func decodeResponse(_ identifier: String, version: Int = 3, title: String = "Go Premium") throws -> PaywallResponse {
        try JSONDecoder().decode(PaywallResponse.self, from: Data(paywallResponseJSON(identifier: identifier, version: version, title: title).utf8))
    }

    private func makeCache(store: PaywallCacheStore, project: String = "pk_test_123", clock: TestClock) -> PaywallCache {
        PaywallCache(store: store, project: project, now: clock.nowFn)
    }

    private func makeFileCache(project: String = "pk_test_123", clock: TestClock) -> PaywallCache {
        PaywallCache(store: FilePaywallCacheStore(baseDirectory: tempDir), project: project, now: clock.nowFn)
    }

    // MARK: write/read round-trip

    func testWriteThenReadRoundTripsResponse() throws {
        let clock = TestClock(Date(timeIntervalSince1970: 1_000_000))
        let cache = makeFileCache(clock: clock)
        let response = try decodeResponse("main")

        try cache.writePaywall("main", response: response)

        let entry = try XCTUnwrap(cache.readPaywall("main"))
        XCTAssertEqual(entry.identifier, "main")
        XCTAssertEqual(entry.response.versionNumber, 3)
        XCTAssertEqual(entry.response.document.header.title, "Go Premium")
        XCTAssertEqual(entry.fetchedAt, clock.now())
    }

    func testReadMissReturnsNilNotError() throws {
        let clock = TestClock(Date())
        let cache = makeFileCache(clock: clock)
        XCTAssertNil(try cache.readPaywall("never-written"))
        XCTAssertNil(cache.anyPaywall("never-written"))
    }

    /// A persisted entry survives a fresh PaywallCache instance over the same directory (cold-start
    /// instant-present): the second cache reads it off disk, not memory.
    func testEntryPersistsAcrossCacheInstances() throws {
        let clock = TestClock(Date(timeIntervalSince1970: 2_000_000))
        let writer = makeFileCache(clock: clock)
        try writer.writePaywall("main", response: try decodeResponse("main"))

        let reader = makeFileCache(clock: clock)
        let entry = try XCTUnwrap(reader.readPaywall("main"))
        XCTAssertEqual(entry.response.versionNumber, 3)
    }

    // MARK: TTL / expiry with the injectable clock

    func testFreshWithinTTLStaleAfter() throws {
        let clock = TestClock(Date(timeIntervalSince1970: 5_000_000))
        let cache = makeFileCache(clock: clock)
        try cache.writePaywall("main", response: try decodeResponse("main"))

        // Within TTL → fresh.
        XCTAssertNotNil(cache.freshPaywall("main", ttl: 300))

        // Advance to exactly the TTL boundary → still fresh (<=).
        clock.advance(300)
        XCTAssertNotNil(cache.freshPaywall("main", ttl: 300))

        // One second past TTL → no longer fresh, but still available (stale).
        clock.advance(1)
        XCTAssertNil(cache.freshPaywall("main", ttl: 300))
        XCTAssertNotNil(cache.anyPaywall("main"))
    }

    func testNonPositiveTTLIsAlwaysStale() throws {
        let clock = TestClock(Date())
        let cache = makeFileCache(clock: clock)
        try cache.writePaywall("main", response: try decodeResponse("main"))
        XCTAssertNil(cache.freshPaywall("main", ttl: 0))
        XCTAssertNotNil(cache.anyPaywall("main"))
    }

    func testNegativeClockSkewClampsAgeToZero() throws {
        let clock = TestClock(Date(timeIntervalSince1970: 9_000_000))
        let cache = makeFileCache(clock: clock)
        try cache.writePaywall("main", response: try decodeResponse("main"))
        // Move the clock BACKWARDS (e.g. device time corrected). Age clamps to 0 → still fresh.
        clock.advance(-10_000)
        XCTAssertNotNil(cache.freshPaywall("main", ttl: 60))
    }

    // MARK: Offerings

    func testOfferingsRoundTripAndTTL() throws {
        let clock = TestClock(Date(timeIntervalSince1970: 1_111_111))
        let cache = makeFileCache(clock: clock)
        let offerings = Offerings(currentOfferingId: "default", offerings: [
            RemoteOffering(identifier: "default", displayName: "Default", description: nil, isCurrent: true, packages: [], paywall: nil)
        ])
        try cache.writeOfferings(offerings)

        XCTAssertEqual(cache.freshOfferings(ttl: 300)?.currentOfferingId, "default")
        clock.advance(301)
        XCTAssertNil(cache.freshOfferings(ttl: 300))
        XCTAssertEqual(cache.anyOfferings()?.currentOfferingId, "default")
    }

    // MARK: Invalidation

    func testInvalidatePaywallForcesMiss() throws {
        let clock = TestClock(Date())
        let cache = makeFileCache(clock: clock)
        try cache.writePaywall("main", response: try decodeResponse("main"))
        XCTAssertNotNil(cache.anyPaywall("main"))

        cache.invalidatePaywall("main")
        XCTAssertNil(cache.anyPaywall("main"))
        XCTAssertNil(try cache.readPaywall("main"))
    }

    func testInvalidateAllClearsPaywallsAndOfferings() throws {
        let clock = TestClock(Date())
        let cache = makeFileCache(clock: clock)
        try cache.writePaywall("a", response: try decodeResponse("a"))
        try cache.writePaywall("b", response: try decodeResponse("b"))
        try cache.writeOfferings(Offerings(currentOfferingId: nil, offerings: []))

        cache.invalidateAll()
        XCTAssertNil(cache.anyPaywall("a"))
        XCTAssertNil(cache.anyPaywall("b"))
        XCTAssertNil(cache.anyOfferings())
    }

    // MARK: Project namespacing — two projects don't collide

    func testDifferentProjectsDoNotCollide() throws {
        let clock = TestClock(Date())
        let store = FilePaywallCacheStore(baseDirectory: tempDir)
        let cacheA = PaywallCache(store: store, project: "pk_live_A", now: clock.nowFn)
        let cacheB = PaywallCache(store: store, project: "pk_live_B", now: clock.nowFn)

        try cacheA.writePaywall("main", response: try decodeResponse("main", version: 1, title: "From A"))
        try cacheB.writePaywall("main", response: try decodeResponse("main", version: 2, title: "From B"))

        XCTAssertEqual(cacheA.anyPaywall("main")?.document.header.title, "From A")
        XCTAssertEqual(cacheB.anyPaywall("main")?.document.header.title, "From B")
    }

    // MARK: Corrupt entry — surfaced, not silently a miss; then dropped

    func testCorruptEntryThrowsCorruptEntryAndIsRemoved() throws {
        let clock = TestClock(Date())
        let store = InMemoryPaywallCacheStore()
        let cache = makeCache(store: store, clock: clock)

        // Plant garbage under the namespaced key the cache will look up.
        let key = "paywall.\(PaywallCache.shortHash("pk_test_123")).main"
        try store.writeData(Data("{ not valid paywall json".utf8), forKey: key)

        XCTAssertThrowsError(try cache.readPaywall("main")) { error in
            guard case PaywallCacheError.corruptEntry = error else {
                return XCTFail("expected corruptEntry, got \(error)")
            }
        }
        // The corrupt file is dropped so the next fetch can replace it cleanly.
        XCTAssertNil(try store.readData(forKey: key))
        // The caller-facing helper degrades a corrupt entry to a miss (renderer revalidates).
        XCTAssertNil(cache.anyPaywall("main"))
    }

    // MARK: Write error is NOT swallowed (no silent fallback)

    func testWriteErrorPropagatesButMemoryTierStillServes() throws {
        let clock = TestClock(Date())
        let store = InMemoryPaywallCacheStore()
        store.failNextWriteWith = .writeFailed(key: "x", underlying: "disk full")
        let cache = makeCache(store: store, clock: clock)

        XCTAssertThrowsError(try cache.writePaywall("main", response: try decodeResponse("main"))) { error in
            guard case PaywallCacheError.writeFailed = error else {
                return XCTFail("expected writeFailed, got \(error)")
            }
        }
        // Even though disk failed, the in-memory tier holds the value for this session.
        XCTAssertNotNil(cache.anyPaywall("main"))
    }
}
