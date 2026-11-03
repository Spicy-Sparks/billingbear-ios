import Foundation
import XCTest
@testable import BillingBear

// MARK: - Shared event log (orders network calls against StoreKit finishes)

final class EventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [String] = []

    func append(_ event: String) {
        lock.lock(); events.append(event); lock.unlock()
    }

    var all: [String] {
        lock.lock(); defer { lock.unlock() }
        return events
    }
}

// MARK: - Network mock

struct RecordedRequest {
    let method: String
    let path: String
    let body: [String: Any]?
    var headers: [String: String] = [:]

    var providerData: [String: Any]? { body?["providerData"] as? [String: Any] }
}

extension RecordedRequest: @unchecked Sendable {}

enum MockReply {
    case json(Int, String)
    case networkError
}

/// `BillingBearHTTPClient` mock: answers through `responder`, records every request.
final class MockHTTPClient: BillingBearHTTPClient, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [RecordedRequest] = []
    private var responderStorage: (RecordedRequest, Int) -> MockReply
    private var delayStorage: (RecordedRequest, Int) -> UInt64 = { _, _ in 0 }
    let log: EventLog

    init(log: EventLog = EventLog(), responder: @escaping (RecordedRequest, Int) -> MockReply) {
        self.log = log
        self.responderStorage = responder
    }

    /// Replace how requests are answered. `Int` is the 1-based count of requests so far to that path.
    func respond(_ responder: @escaping (RecordedRequest, Int) -> MockReply) {
        lock.lock(); responderStorage = responder; lock.unlock()
    }

    /// Delay (nanoseconds) before answering a request.
    func delay(_ delay: @escaping (RecordedRequest, Int) -> UInt64) {
        lock.lock(); delayStorage = delay; lock.unlock()
    }

    var requests: [RecordedRequest] {
        lock.lock(); defer { lock.unlock() }
        return recorded
    }

    func requests(_ method: String, _ path: String) -> [RecordedRequest] {
        requests.filter { $0.method == method && $0.path == path }
    }

    private func record(_ request: RecordedRequest) -> (Int, (RecordedRequest, Int) -> MockReply, (RecordedRequest, Int) -> UInt64) {
        lock.lock(); defer { lock.unlock() }
        recorded.append(request)
        let count = recorded.filter { $0.method == request.method && $0.path == request.path }.count
        return (count, responderStorage, delayStorage)
    }

    func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
        let url = request.url!
        var path = url.path
        if let query = url.query { path += "?\(query)" }
        let body = request.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        let recordedRequest = RecordedRequest(
            method: request.httpMethod ?? "GET", path: path, body: body, headers: request.allHTTPHeaderFields ?? [:]
        )

        let (count, responder, delay) = record(recordedRequest)

        log.append("\(recordedRequest.method) \(url.path)")
        let wait = delay(recordedRequest, count)
        if wait > 0 { try? await Task.sleep(nanoseconds: wait) }

        switch responder(recordedRequest, count) {
        case .networkError:
            throw URLError(.notConnectedToInternet)
        case .json(let status, let json):
            let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
            return (Data(json.utf8), response)
        }
    }
}

// MARK: - StoreKit mock

final class MockStoreKit: StoreKitClient, @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: AsyncStream<StoreTransactionResult>.Continuation?
    private var _updatesCallCount = 0
    private var _unfinished: [StoreTransactionResult] = []
    private var _entitlements: [StoreTransaction] = []
    private var _latest: [String: StoreTransaction] = [:]
    private var _latestFails = false
    private var _finished: [String] = []
    private var _purchases: [(String, StorePurchaseOptions)] = []
    private var _purchaseHandler: (String, StorePurchaseOptions) throws -> StorePurchaseOutcome = { _, _ in .userCancelled }
    private var _intro: [String: IntroEligibilityStatus?] = [:]
    private var _winBack: [String: [WinBackOffer]] = [:]
    private var _refunds: [String] = []
    private var _refundStatus: RefundRequestStatus = .success
    private var _codeSheets = 0
    private var _purchaseGate: LockedFlag?
    let log: EventLog

    init(log: EventLog = EventLog()) { self.log = log }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock(); defer { lock.unlock() }
        return body()
    }

    var updatesCallCount: Int { locked { _updatesCallCount } }
    var finishedIds: [String] { locked { _finished } }
    var purchases: [(String, StorePurchaseOptions)] { locked { _purchases } }
    var refunds: [String] { locked { _refunds } }
    var codeSheets: Int { locked { _codeSheets } }

    func setUnfinished(_ results: [StoreTransactionResult]) { locked { _unfinished = results } }
    func setEntitlements(_ transactions: [StoreTransaction]) { locked { _entitlements = transactions } }
    func setLatest(_ latest: [String: StoreTransaction]) { locked { _latest = latest } }
    /// Make reading the subscription's current state fail (StoreKit status read error).
    func setLatestFails(_ fails: Bool) { locked { _latestFails = fails } }
    func setPurchaseHandler(_ handler: @escaping (String, StorePurchaseOptions) throws -> StorePurchaseOutcome) {
        locked { _purchaseHandler = handler }
    }
    func setIntro(_ intro: [String: IntroEligibilityStatus?]) { locked { _intro = intro } }
    func setWinBack(_ offers: [String: [WinBackOffer]]) { locked { _winBack = offers } }
    func setRefundStatus(_ status: RefundRequestStatus) { locked { _refundStatus = status } }
    /// Keep the purchase sheet "open" until the flag is set.
    func setPurchaseGate(_ gate: LockedFlag?) { locked { _purchaseGate = gate } }

    /// Deliver a `Transaction.updates` element.
    func emit(_ result: StoreTransactionResult) {
        let continuation = locked { self.continuation }
        continuation?.yield(result)
    }

    func transactionUpdates() -> AsyncStream<StoreTransactionResult> {
        AsyncStream { continuation in
            locked {
                _updatesCallCount += 1
                self.continuation = continuation
            }
        }
    }

    func unfinishedTransactions() async -> [StoreTransactionResult] { locked { _unfinished } }

    func currentEntitlements() async -> [StoreTransaction] { locked { _entitlements } }

    /// Keyed by original transaction id (the subscription), or by product id for single-product setups.
    func latestTransaction(ofSubscription transaction: StoreTransaction) async throws -> StoreTransaction? {
        let (latest, fails) = locked { (_latest[transaction.originalTransactionId] ?? _latest[transaction.productId], _latestFails) }
        if fails { throw PurchasesError("status unavailable", code: .networkError) }
        return latest
    }

    func purchase(productId: String, product: Any?, options: StorePurchaseOptions) async throws -> StorePurchaseOutcome {
        let (handler, gate) = locked { () -> ((String, StorePurchaseOptions) throws -> StorePurchaseOutcome, LockedFlag?) in
            _purchases.append((productId, options))
            return (_purchaseHandler, _purchaseGate)
        }
        if let gate { await waitFor(gate) }
        return try handler(productId, options)
    }

    func finish(_ transaction: StoreTransaction) async {
        locked {
            _finished.append(transaction.transactionId)
            _unfinished.removeAll {
                if case .verified(let t) = $0 { return t.transactionId == transaction.transactionId }
                return false
            }
        }
        log.append("finish \(transaction.transactionId)")
    }

    func introEligibility(productIds: [String]) async -> [String: IntroEligibilityStatus?] {
        locked {
            var result: [String: IntroEligibilityStatus?] = [:]
            for id in productIds { result[id] = _intro[id] ?? .some(nil) }
            return result
        }
    }

    func eligibleWinBackOffers(productId: String) async throws -> [WinBackOffer] { locked { _winBack[productId] ?? [] } }

    func presentCodeRedemptionSheet() async throws { locked { _codeSheets += 1 } }

    func beginRefundRequest(productId: String) async throws -> RefundRequestStatus {
        locked { _refunds.append("product:\(productId)"); return _refundStatus }
    }

    func beginRefundRequest(transactionId: String) async throws -> RefundRequestStatus {
        locked { _refunds.append("transaction:\(transactionId)"); return _refundStatus }
    }
}

// MARK: - Clock

final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date

    init(_ start: Date = Date(timeIntervalSince1970: 1_800_000_000)) { current = start }

    var now: Date {
        lock.lock(); defer { lock.unlock() }
        return current
    }

    func advance(_ seconds: TimeInterval) {
        lock.lock(); current = current.addingTimeInterval(seconds); lock.unlock()
    }
}

// MARK: - Delegate

@MainActor
final class RecordingDelegate: PurchasesDelegate {
    var updates: [CustomerInfo] = []
    var synced: [String] = []
    var failures: [(String, PurchasesError)] = []

    func purchases(_ purchases: Purchases, receivedUpdated customerInfo: CustomerInfo) {
        updates.append(customerInfo)
    }

    func purchases(_ purchases: Purchases, didSyncTransaction transaction: StoreTransaction, customerInfo: CustomerInfo) {
        synced.append(transaction.transactionId)
    }

    func purchases(_ purchases: Purchases, didFailToSyncTransaction transaction: StoreTransaction, error: PurchasesError) {
        failures.append((transaction.transactionId, error))
    }
}

// MARK: - Fixtures

enum Fixture {
    static func entitlements(premium: Bool, productId: String = "com.app.monthly", store: Int = 2, extra: [String] = []) -> String {
        guard premium else {
            return #"{"userId":null,"isPremium":false,"entitlements":[],"subscription":null}"#
        }
        let ids = (["premium"] + extra).map { "\"\($0)\"" }.joined(separator: ",")
        return """
        {"userId":"00000000-0000-0000-0000-000000000001","isPremium":true,"entitlements":[\(ids)],
         "subscription":{"status":1,"store":\(store),"productId":"\(productId)","expiresAt":"2027-01-01T00:00:00Z",
         "startsAt":"2026-01-01T00:00:00Z","cancelledAt":null,"willRenew":true,"isGracePeriod":false},
         "entitlementsExpireAt":"2027-01-01T00:00:00Z"}
        """
    }

    static func transaction(
        _ id: String,
        product: String = "com.app.monthly",
        type: StoreProductType = .autoRenewable,
        revoked: Bool = false,
        upgraded: Bool = false,
        expires: Date? = Date(timeIntervalSince1970: 1_900_000_000)
    ) -> StoreTransaction {
        StoreTransaction(
            transactionId: id,
            originalTransactionId: "orig-\(id)",
            productId: product,
            productType: type,
            purchaseDate: Date(timeIntervalSince1970: 1_799_000_000),
            expirationDate: type == .autoRenewable ? expires : nil,
            revocationDate: revoked ? Date(timeIntervalSince1970: 1_799_500_000) : nil,
            isUpgraded: upgraded,
            jwsRepresentation: "jws-\(id)"
        )
    }

    static let nonSubscriptionRecorded = #"{"productId":"com.app.coins","transactionId":"t","isConsumable":true,"entitlementGranted":false,"alreadyRecorded":false}"#
}

/// Everything a purchase-core test needs, wired together.
struct Harness {
    let purchases: Purchases
    let http: MockHTTPClient
    let store: MockStoreKit
    let clock: TestClock
    let defaults: UserDefaults
    let log: EventLog

    /// A harness whose backend answers premium after a confirm/record/restore and free before it.
    static func make(
        appUserId: String? = "u1",
        options: PurchasesOptions = .init(),
        defaults: UserDefaults? = nil,
        apiKey: String = "pk_test_123",
        clock: TestClock = TestClock(),
        observe: Bool = true,
        responder: ((RecordedRequest, Int) -> MockReply)? = nil
    ) async -> Harness {
        let log = EventLog()
        let http = MockHTTPClient(log: log, responder: responder ?? Harness.defaultResponder())
        let store = MockStoreKit(log: log)
        let suite = defaults ?? UserDefaults(suiteName: "bb.core.\(UUID().uuidString)")!
        let api = BillingBearAPI(apiKey: apiKey, bundleId: "com.test.app", httpClient: http, sleep: { _ in })
        let purchases = Purchases(defaults: suite)
        await purchases.configure(
            api: api,
            store: store,
            appUserId: appUserId,
            options: options,
            now: { clock.now },
            observeTransactions: observe
        )
        return Harness(purchases: purchases, http: http, store: store, clock: clock, defaults: suite, log: log)
    }

    /// Free until something was confirmed, recorded or restored; then premium.
    static func defaultResponder() -> (RecordedRequest, Int) -> MockReply {
        let granted = LockedFlag()
        return { request, _ in
            if request.method == "POST" && (request.path == "/subscription/confirm" || request.path == "/subscription/restore") {
                granted.set()
                return .json(200, "{}")
            }
            if request.method == "POST" && request.path.hasSuffix("/non-subscription") {
                granted.set()
                return .json(200, Fixture.nonSubscriptionRecorded)
            }
            if request.path.hasPrefix("/subscription/entitlements/") {
                return .json(200, Fixture.entitlements(premium: granted.isSet))
            }
            return .json(404, "{}")
        }
    }
}

final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func set() { lock.lock(); value = true; lock.unlock() }
    func reset() { lock.lock(); value = false; lock.unlock() }
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
}

/// Suspend until `flag` is set (polling; test-only).
func waitFor(_ flag: LockedFlag) async {
    while !flag.isSet { try? await Task.sleep(nanoseconds: 5_000_000) }
}

/// Poll `condition` until it holds or `timeout` passes.
func eventually(
    timeout: TimeInterval = 3,
    file: StaticString = #filePath,
    line: UInt = #line,
    _ condition: @escaping () async -> Bool
) async {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if await condition() { return }
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
    XCTFail("Condition not met within \(timeout)s", file: file, line: line)
}

/// Let background tasks run for a moment (for asserting that something did NOT happen).
func settle(_ milliseconds: UInt64 = 150) async {
    try? await Task.sleep(nanoseconds: milliseconds * 1_000_000)
}
