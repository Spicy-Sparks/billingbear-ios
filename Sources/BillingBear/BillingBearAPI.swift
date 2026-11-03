import Foundation
import CryptoKit

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// MARK: - Errors

/// Error codes mirroring the RN SDK's `PurchaseErrorCode`.
public enum PurchaseErrorCode: String, Sendable {
    case userCancelled = "USER_CANCELLED"
    case productNotFound = "PRODUCT_NOT_FOUND"
    case alreadyOwned = "ALREADY_OWNED"
    case paymentPending = "PAYMENT_PENDING"
    case networkError = "NETWORK_ERROR"
    case storeError = "STORE_ERROR"
    case validationError = "VALIDATION_ERROR"
    case notConfigured = "NOT_CONFIGURED"
    case unknown = "UNKNOWN"
}

/// Error thrown by the BillingBear SDK, mirroring the RN SDK's `PurchasesError`.
public struct PurchasesError: Error, Equatable, Sendable {
    public let message: String
    public let code: PurchaseErrorCode
    public let statusCode: Int
    /// The backend's machine-readable error code when it sent one (e.g. "apple_iap_key_missing").
    public let serverCode: String?
    public var userCancelled: Bool { code == .userCancelled }

    public init(_ message: String, code: PurchaseErrorCode = .unknown, statusCode: Int = 0) {
        self.init(message, code: code, statusCode: statusCode, serverCode: nil)
    }

    init(_ message: String, code: PurchaseErrorCode, statusCode: Int, serverCode: String?) {
        self.message = message
        self.code = code
        self.statusCode = statusCode
        self.serverCode = serverCode
    }
}

extension PurchasesError: LocalizedError {
    public var errorDescription: String? { message }
}

// MARK: - Raw wire shapes
//
// The backend returns numeric enums for status/store at GET /subscription/entitlements/{appUserId}.
// We decode that here and map to the friendly types, mirroring `fetchEntitlements` in the RN SDK.

struct RawSubscription: Decodable {
    let status: Int
    let store: Int
    // Nullable on the server (SubscriptionDetails.ProductId): a null must not fail the whole read.
    let productId: String?
    let expiresAt: String?
    let startsAt: String?
    let cancelledAt: String?
    let willRenew: Bool
    let isGracePeriod: Bool
    let billingIssueDetectedAt: String?
    let gracePeriodExpiresAt: String?
    let unsubscribeDetectedAt: String?
    let periodType: String?
}

struct RawNonSubscriptionTransaction: Decodable {
    let productId: String
    let transactionId: String
    let store: Int
    let isConsumable: Bool
    let purchasedAt: String?
    let refundedAt: String?
}

struct RawEntitlementsResponse: Decodable {
    let userId: String?
    let isPremium: Bool
    let entitlements: [String]
    let subscription: RawSubscription?
    let nonSubscriptionTransactions: [RawNonSubscriptionTransaction]?
    let entitlementsExpireAt: String?
    /// The backend sends `entitlementsExpireAt` (servers since the grants fix). A present null means
    /// "nothing expires" (a lifetime grant), which must not be replaced by the subscription's date;
    /// only an older server that omits the key falls back to it.
    let hasEntitlementsExpireAt: Bool

    private enum CodingKeys: String, CodingKey {
        case userId, isPremium, entitlements, subscription, nonSubscriptionTransactions, entitlementsExpireAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        userId = try c.decodeIfPresent(String.self, forKey: .userId)
        isPremium = try c.decode(Bool.self, forKey: .isPremium)
        entitlements = try c.decode([String].self, forKey: .entitlements)
        subscription = try c.decodeIfPresent(RawSubscription.self, forKey: .subscription)
        nonSubscriptionTransactions = try c.decodeIfPresent([RawNonSubscriptionTransaction].self, forKey: .nonSubscriptionTransactions)
        hasEntitlementsExpireAt = c.contains(.entitlementsExpireAt)
        entitlementsExpireAt = try c.decodeIfPresent(String.self, forKey: .entitlementsExpireAt)
    }

    /// When the entitlements run out: the server's answer when it gave one (null included), else the
    /// subscription's expiry.
    var latestExpirationDate: String? {
        hasEntitlementsExpireAt ? entitlementsExpireAt : subscription?.expiresAt
    }
}

struct LoginResponse: Decodable {
    let appUserId: String
    let wasMerged: Bool
}

struct LogoutResponse: Decodable {
    let newAnonymousAppUserId: String
}

/// Request body for POST /subscription/confirm and /subscription/restore.
public struct ValidateRequest: Encodable {
    public var appUserId: String
    public var providerType: Int
    public var transactionId: String?
    public var originalTransactionId: String?
    public var productId: String?
    public var receipt: String?
    public var providerData: [String: String]
    /// Restore only (`/subscription/restore`): `true` marks a silent sync, which adopts a subscription
    /// parked on an anonymous id but never takes one from another subscriber. Nil (omitted) is an
    /// explicit restore, which follows the project's RestoreTransferPolicy.
    public var claimOrphanOnly: Bool?

    public init(
        appUserId: String,
        providerType: Int,
        transactionId: String? = nil,
        originalTransactionId: String? = nil,
        productId: String? = nil,
        receipt: String? = nil,
        providerData: [String: String] = [:],
        claimOrphanOnly: Bool? = nil
    ) {
        self.appUserId = appUserId
        self.providerType = providerType
        self.transactionId = transactionId
        self.originalTransactionId = originalTransactionId
        self.productId = productId
        self.receipt = receipt
        self.providerData = providerData
        self.claimOrphanOnly = claimOrphanOnly
    }
}

// MARK: - API client

/// Provider type identifiers matching the backend's numeric enum (1=stripe, 2=apple, 3=google, 4=paddle).
enum ProviderType {
    static let apple = 2
}

/// Maps the backend's numeric `status` enum to `SubscriptionStatus`.
private let statusMap: [Int: SubscriptionStatus] = [
    1: .active,
    2: .expired,
    3: .cancelled,
    4: .pending
]

/// Maps the backend's numeric `store` enum to its string name.
private let storeMap: [Int: String] = [
    1: "stripe", 2: "apple", 3: "google", 4: "paddle",
    5: "gift", 6: "referral", 7: "admin", 8: "promo",
    9: "amazon", 10: "huawei"
]

/// Supplies the end-user token (minted by your backend through BillingBear) for calls that act on one
/// subscriber: Customer Center actions, virtual-currency spends, promotional-offer signatures. Return
/// nil when you have none; throw to fail the call (it would be refused anyway once the project requires
/// end-user tokens). Mirrors the React Native SDK's `endUserTokenProvider`.
public typealias EndUserTokenProvider = @Sendable (_ appUserId: String) async throws -> String?

/// The HTTP transport `BillingBearAPI` sends through. `URLSession` is the default; tests and hosts
/// with their own networking stack can supply another.
public protocol BillingBearHTTPClient: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, URLResponse)
}

extension URLSession: BillingBearHTTPClient {
    public func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
        try await data(for: request)
    }
}

/// Response of POST /v1/subscribers/{appUserId}/non-subscription. The last four fields are absent
/// on older servers and decode as nil / false.
public struct NonSubscriptionPurchaseResult: Codable, Equatable, Sendable {
    public let productId: String
    public let transactionId: String
    public let isConsumable: Bool
    /// True when the purchase unlocked an entitlement (a non-consumable mapped to one).
    public let entitlementGranted: Bool
    /// True when the backend already had this transaction (idempotent replay).
    public let alreadyRecorded: Bool
    /// The store took the purchase back (a refund, a void, or a Family Sharing withdrawal): it never
    /// grants again. The StoreKit transaction is still finished — the server has its final state.
    public let revoked: Bool
    /// When the store refunded it (ISO-8601, as the server sends it); nil otherwise, also for a
    /// Family Sharing withdrawal, which refunds nobody.
    public let refundedAt: String?
    /// A restore moved the purchase here from another subscriber (the project's transfer policy).
    public let transferred: Bool
    /// The purchase stays with the subscriber who holds it: the project blocks transfers, the call
    /// only claimed unowned purchases (`claimOrphanOnly`), or it is a consumable (never restored).
    public let keptByOriginalOwner: Bool

    public init(
        productId: String,
        transactionId: String,
        isConsumable: Bool,
        entitlementGranted: Bool,
        alreadyRecorded: Bool,
        revoked: Bool = false,
        refundedAt: String? = nil,
        transferred: Bool = false,
        keptByOriginalOwner: Bool = false
    ) {
        self.productId = productId
        self.transactionId = transactionId
        self.isConsumable = isConsumable
        self.entitlementGranted = entitlementGranted
        self.alreadyRecorded = alreadyRecorded
        self.revoked = revoked
        self.refundedAt = refundedAt
        self.transferred = transferred
        self.keptByOriginalOwner = keptByOriginalOwner
    }

    private enum CodingKeys: String, CodingKey {
        case productId, transactionId, isConsumable, entitlementGranted, alreadyRecorded
        case revoked, refundedAt, transferred, keptByOriginalOwner
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        productId = try c.decode(String.self, forKey: .productId)
        transactionId = try c.decode(String.self, forKey: .transactionId)
        isConsumable = try c.decodeIfPresent(Bool.self, forKey: .isConsumable) ?? false
        entitlementGranted = try c.decodeIfPresent(Bool.self, forKey: .entitlementGranted) ?? false
        alreadyRecorded = try c.decodeIfPresent(Bool.self, forKey: .alreadyRecorded) ?? false
        // Additive fields: read leniently, so an unexpected shape never fails a purchase the server
        // accepted (the transaction is finished on any 200).
        revoked = (try? c.decodeIfPresent(Bool.self, forKey: .revoked)) ?? false
        refundedAt = (try? c.decodeIfPresent(String.self, forKey: .refundedAt)) ?? nil
        transferred = (try? c.decodeIfPresent(Bool.self, forKey: .transferred)) ?? false
        keptByOriginalOwner = (try? c.decodeIfPresent(Bool.self, forKey: .keptByOriginalOwner)) ?? false
    }
}

/// Async REST client for the BillingBear backend. Uses `URLSession`, Bearer `pk_` auth,
/// and a configurable base URL (default https://api.billingbear.io).
public final class BillingBearAPI: @unchecked Sendable {
    private let apiKey: String
    private let baseURL: String
    /// The app bundle sent with confirm/restore/one-time records so a multi-brand project scopes the
    /// purchase to the right app.
    let bundleId: String?
    private let transport: any BillingBearHTTPClient
    private let tokenProvider = LockedBox<EndUserTokenProvider?>(nil)

    /// Header the backend reads the end-user token from; `Authorization` keeps carrying the API key.
    public static let endUserTokenHeader = "X-BillingBear-User-Token"

    /// The provider of end-user tokens for per-subscriber calls (nil: send none). Set it here or through
    /// `PurchasesOptions.endUserTokenProvider`.
    public var endUserTokenProvider: EndUserTokenProvider? {
        get { tokenProvider.value }
        set { tokenProvider.value = newValue }
    }

    /// The end-user token header for a call acting on `appUserId`, or none. A provider that throws fails
    /// the call (React Native SDK semantics).
    private func endUserHeaders(_ appUserId: String) async throws -> [String: String] {
        guard let provider = tokenProvider.value else { return [:] }
        let token: String?
        do {
            token = try await provider(appUserId)
        } catch let error as PurchasesError {
            throw error
        } catch {
            throw PurchasesError("The end-user token provider failed: \(error.localizedDescription)", code: .unknown)
        }
        guard let token, !token.isEmpty else { return [:] }
        return [Self.endUserTokenHeader: token]
    }
    /// Test seam: overridable so unit tests don't sleep real wall-clock time.
    private let sleep: @Sendable (UInt64) async -> Void

    public convenience init(
        apiKey: String,
        baseURL: String = "https://api.billingbear.io",
        bundleId: String? = nil,
        session: URLSession = .shared,
        sleep: @escaping @Sendable (UInt64) async -> Void = { try? await Task.sleep(nanoseconds: $0) }
    ) {
        self.init(apiKey: apiKey, baseURL: baseURL, bundleId: bundleId, transport: session, sleep: sleep)
    }

    /// A client that sends through `httpClient` (your networking stack, or a mock in tests).
    @_disfavoredOverload
    public convenience init(
        apiKey: String,
        baseURL: String = "https://api.billingbear.io",
        bundleId: String? = nil,
        httpClient: any BillingBearHTTPClient,
        sleep: @escaping @Sendable (UInt64) async -> Void = { try? await Task.sleep(nanoseconds: $0) }
    ) {
        self.init(apiKey: apiKey, baseURL: baseURL, bundleId: bundleId, transport: httpClient, sleep: sleep)
    }

    private init(
        apiKey: String,
        baseURL: String,
        bundleId: String?,
        transport: any BillingBearHTTPClient,
        sleep: @escaping @Sendable (UInt64) async -> Void
    ) {
        self.apiKey = apiKey
        // Strip a single trailing slash so path concatenation is clean (mirrors RN configureApi).
        if baseURL.hasSuffix("/") {
            self.baseURL = String(baseURL.dropLast())
        } else {
            self.baseURL = baseURL
        }
        self.bundleId = bundleId
        self.transport = transport
        self.sleep = sleep
    }

    /// A stable, non-reversible id for this key + host, used to scope on-device caches to one project.
    var cacheNamespace: String {
        let digest = SHA256.hash(data: Data("\(baseURL)|\(apiKey)".utf8))
        return digest.prefix(12).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: Core request

    private func request<T: Decodable>(
        _ path: String,
        method: String = "GET",
        body: Data? = nil,
        headers: [String: String] = [:]
    ) async throws -> T {
        guard let url = URL(string: "\(baseURL)\(path)") else {
            throw PurchasesError("Invalid URL: \(baseURL)\(path)", code: .unknown)
        }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        for (name, value) in headers { req.setValue(value, forHTTPHeaderField: name) }
        req.httpBody = body

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await transport.send(req)
        } catch {
            throw PurchasesError(error.localizedDescription, code: .networkError)
        }

        guard let http = response as? HTTPURLResponse else {
            throw PurchasesError("No HTTP response", code: .networkError)
        }

        guard (200..<300).contains(http.statusCode) else {
            let message = Self.extractErrorMessage(from: data) ?? "HTTP \(http.statusCode)"
            throw PurchasesError(
                message,
                code: .validationError,
                statusCode: http.statusCode,
                serverCode: Self.extractErrorCode(from: data)
            )
        }

        if T.self == EmptyResponse.self {
            // Body is irrelevant for fire-and-forget POSTs.
            return EmptyResponse() as! T
        }

        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw PurchasesError("Decoding failed: \(error)", code: .validationError, statusCode: http.statusCode)
        }
    }

    /// Mirrors the RN SDK error extraction: body.error.error || body.error.message. A bare JSON string
    /// (minimal-API `BadRequest<string>` bodies, e.g. the one-time purchase endpoint) is used as is.
    private static func extractErrorMessage(from data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else { return nil }
        if let message = json as? String, !message.isEmpty { return message }
        guard let obj = json as? [String: Any] else { return nil }
        // { code, message, error: { error: code, description } }: the human message is top-level.
        if let message = obj["message"] as? String, !message.isEmpty { return message }
        if let err = obj["error"] as? [String: Any] {
            return (err["error"] as? String) ?? (err["message"] as? String) ?? (err["description"] as? String)
        }
        return obj["error"] as? String
    }

    /// The machine-readable code of an error body: `{ "code": "…" }` or `{ "error": { "code": "…" } }`.
    private static func extractErrorCode(from data: Data) -> String? {
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        if let code = obj["code"] as? String, !code.isEmpty { return code }
        return (obj["error"] as? [String: Any])?["code"] as? String
    }

    // MARK: Retry (audit B15)
    //
    // A purchase validation that dies on the first network blip strands a PAID user
    // without their entitlement: the store already took the money, our backend never
    // heard about it. Transient failures (network errors, 429, 5xx) are therefore
    // retried with exponential backoff + full jitter. Confirm/restore/entitlement are
    // idempotent server-side, so retrying is safe. Client errors (4xx) are never
    // retried — the request itself is wrong and a retry can't fix it. Mirrors the RN
    // SDK's `requestWithRetry` and the Android client's `requestWithRetry`.

    private static func isTransient(_ error: PurchasesError) -> Bool {
        if error.code == .networkError { return true }
        return error.statusCode == 429 || error.statusCode >= 500
    }

    private func requestWithRetry<T: Decodable>(
        _ path: String,
        method: String = "GET",
        body: Data? = nil,
        attempts: Int = 4,
        baseDelayMs: Double = 500,
        maxDelayMs: Double = 8000
    ) async throws -> T {
        var lastError: PurchasesError?
        for attempt in 0..<attempts {
            do {
                return try await request(path, method: method, body: body)
            } catch let error as PurchasesError {
                lastError = error
                if !Self.isTransient(error) || attempt == attempts - 1 { throw error }
                // Exponential backoff with full jitter: delay ∈ [0.5x, 1.5x] of 2^attempt * base.
                let exponential = baseDelayMs * pow(2, Double(attempt))
                let jittered = exponential * (0.5 + Double.random(in: 0..<1))
                let delayMs = min(jittered, maxDelayMs)
                await sleep(UInt64(delayMs * 1_000_000))
            }
        }
        throw lastError ?? PurchasesError("Request failed", code: .unknown)
    }

    // MARK: Entitlements

    /// GET /subscription/entitlements/{appUserId} -> CustomerInfo (mapped from the raw wire shape).
    /// Retried on transient failures so a flaky GET never surfaces "no entitlement" to a paying user.
    public func fetchEntitlements(appUserId: String) async throws -> CustomerInfo {
        let encoded = appUserId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? appUserId
        let raw: RawEntitlementsResponse = try await requestWithRetry("/subscription/entitlements/\(encoded)")

        var entitlements: [String: EntitlementInfo] = [:]
        for id in raw.entitlements {
            entitlements[id] = EntitlementInfo(
                identifier: id,
                isActive: true,
                expiresAt: raw.subscription?.expiresAt
            )
        }

        var activeSubscription: SubscriptionInfo?
        if let sub = raw.subscription {
            activeSubscription = SubscriptionInfo(
                status: statusMap[sub.status] ?? .active,
                store: storeMap[sub.store] ?? "unknown",
                productId: sub.productId ?? "",
                expiresAt: sub.expiresAt,
                startsAt: sub.startsAt,
                cancelledAt: sub.cancelledAt,
                willRenew: sub.willRenew,
                isGracePeriod: sub.isGracePeriod,
                billingIssueDetectedAt: sub.billingIssueDetectedAt,
                gracePeriodExpiresAt: sub.gracePeriodExpiresAt,
                unsubscribeDetectedAt: sub.unsubscribeDetectedAt,
                periodType: sub.periodType
            )
        }

        let nonSubscription = (raw.nonSubscriptionTransactions ?? []).map {
            NonSubscriptionTransaction(
                productId: $0.productId,
                transactionId: $0.transactionId,
                store: storeMap[$0.store] ?? "unknown",
                isConsumable: $0.isConsumable,
                purchasedAt: $0.purchasedAt,
                refundedAt: $0.refundedAt
            )
        }

        return CustomerInfo(
            appUserId: appUserId,
            isPremium: raw.isPremium,
            entitlements: entitlements,
            activeSubscription: activeSubscription,
            nonSubscriptionTransactions: nonSubscription,
            latestExpirationDate: raw.latestExpirationDate,
            isOfflineComputed: false
        )
    }

    // MARK: Validate (StoreKit transaction -> backend)

    /// POST /subscription/confirm with the Apple transaction, then re-fetch entitlements.
    /// Retried (audit B15): the store has already charged the user by the time this runs, and
    /// confirm is idempotent server-side, so transient failures are retried instead of stranding
    /// a paid user without their entitlement.
    public func validatePurchase(appUserId: String, request validate: ValidateRequest) async throws -> CustomerInfo {
        let body = try encodeValidate(validate)
        let _: EmptyResponse = try await requestWithRetry("/subscription/confirm", method: "POST", body: body)
        return try await fetchEntitlements(appUserId: appUserId)
    }

    /// POST /subscription/restore, then re-fetch entitlements. Retried like confirm.
    public func restorePurchases(appUserId: String, request validate: ValidateRequest) async throws -> CustomerInfo {
        let body = try encodeValidate(validate)
        let _: EmptyResponse = try await requestWithRetry("/subscription/restore", method: "POST", body: body)
        return try await fetchEntitlements(appUserId: appUserId)
    }

    /// POST /v1/subscribers/{appUserId}/non-subscription — validate + record a consumable or
    /// non-consumable App Store purchase. The backend asks Apple for the transaction (never trusting
    /// the client), records it idempotently, and grants a non-consumable's entitlements. Retried like
    /// confirm: the store has already charged the customer.
    ///
    /// `claimOrphanOnly`: `false` for a purchase or the customer's "Restore Purchases" (the project's
    /// RestoreTransferPolicy may move a purchase another subscriber holds); `true` for a silent sync
    /// (Transaction.updates, the unfinished replay, `syncPurchases()`), which only adopts a purchase
    /// parked on an anonymous id. Nil omits it; the server then treats the call as a silent sync.
    /// A purchase the store already took back answers 200 with `revoked: true`.
    public func recordNonSubscriptionPurchase(
        appUserId: String,
        transactionId: String,
        productId: String,
        providerData: [String: String] = [:],
        claimOrphanOnly: Bool? = nil
    ) async throws -> NonSubscriptionPurchaseResult {
        let encoded = appUserId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? appUserId
        var data = providerData
        // The endpoint reads the bundle from providerData (not the top level like confirm).
        if let bundleId, data["bundleId"] == nil { data["bundleId"] = bundleId }
        struct Body: Encodable {
            let providerType: Int
            let transactionId: String
            let productId: String
            let providerData: [String: String]
            let claimOrphanOnly: Bool?
        }
        let body = try JSONEncoder().encode(Body(
            providerType: ProviderType.apple,
            transactionId: transactionId,
            productId: productId,
            providerData: data,
            claimOrphanOnly: claimOrphanOnly
        ))
        return try await requestWithRetry("/v1/subscribers/\(encoded)/non-subscription", method: "POST", body: body)
    }

    /// POST /v1/subscribers/{appUserId}/apple/promotional-offer-signature — BillingBear signs an App
    /// Store promotional offer with the project's In-App Purchase key, for the purchase's
    /// `appAccountToken` (lowercased UUID, Apple's `applicationUsername`). Publishable-key auth through
    /// the end-user gate: the end-user token is sent when `endUserTokenProvider` gives one (required
    /// when the project has RequireEndUserToken on). The app's bundle id picks the app — and its key —
    /// when the product ships in several bundles. Errors map to `PurchasesError` with `serverCode`:
    /// - 400 `invalid_request` / `app_account_token_mismatch` / `product_not_in_project` → `.validationError`
    ///   (`product_not_in_project` → `.productNotFound`);
    /// - 404 `offer_not_configured` → `.productNotFound`; 404 `subscriber_not_found` → `.validationError`
    ///   (BillingBear has no customer for this appUserId yet);
    /// - 409 `apple_iap_key_missing` / `apple_iap_key_invalid` → `.notConfigured`;
    /// - 429 (10 a minute per subscriber; empty body, or `rate_limited` from the endpoint itself)
    ///   → `.networkError`;
    /// - 401/403 (end-user token missing or for someone else) → `.notConfigured`;
    /// - an answer for another applicationUsername, product or offer → `.validationError`.
    public func signPromotionalOffer(
        appUserId: String,
        productId: String,
        offerId: String,
        appAccountToken: UUID
    ) async throws -> PromotionalOffer {
        let encoded = appUserId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? appUserId
        let token = appAccountToken.uuidString.lowercased()
        struct Body: Encodable { let productId: String; let offerId: String; let appAccountToken: String; let bundleId: String? }
        struct Signed: Decodable {
            let keyIdentifier: String
            let nonce: String
            let timestamp: Int
            /// Base64 of the DER-encoded ECDSA signature, as StoreKit takes it.
            let signature: String
            let applicationUsername: String?
            let productId: String?
            let offerId: String?
        }
        let body = try JSONEncoder().encode(Body(productId: productId, offerId: offerId, appAccountToken: token, bundleId: bundleId))
        let signed: Signed
        do {
            signed = try await request(
                "/v1/subscribers/\(encoded)/apple/promotional-offer-signature",
                method: "POST", body: body, headers: try await endUserHeaders(appUserId)
            )
        } catch let error as PurchasesError {
            throw Self.mapPromotionalOfferError(error, productId: productId, offerId: offerId)
        }
        if let username = signed.applicationUsername, username.lowercased() != token {
            throw PurchasesError(
                "BillingBear signed the promotional offer for another account token; StoreKit would reject it",
                code: .validationError
            )
        }
        if let signedProduct = signed.productId, signedProduct != productId {
            throw PurchasesError("BillingBear signed the promotional offer for another product (\(signedProduct))", code: .validationError)
        }
        if let signedOffer = signed.offerId, signedOffer != offerId {
            throw PurchasesError("BillingBear signed another promotional offer (\(signedOffer))", code: .validationError)
        }
        guard let nonce = UUID(uuidString: signed.nonce) else {
            throw PurchasesError("The signed promotional offer has an invalid nonce", code: .validationError)
        }
        guard Data(base64Encoded: signed.signature) != nil else {
            throw PurchasesError("The signed promotional offer has an invalid signature", code: .validationError)
        }
        return PromotionalOffer(
            offerId: offerId,
            productId: productId,
            keyIdentifier: signed.keyIdentifier,
            nonce: nonce,
            signature: signed.signature,
            timestamp: signed.timestamp
        )
    }

    /// Codes of the promotional-offer signature endpoint (`PurchasesError.serverCode`).
    public enum PromotionalOfferErrorCode {
        public static let invalidRequest = "invalid_request"
        public static let appAccountTokenMismatch = "app_account_token_mismatch"
        public static let productNotInProject = "product_not_in_project"
        public static let offerNotConfigured = "offer_not_configured"
        public static let subscriberNotFound = "subscriber_not_found"
        public static let appleIapKeyMissing = "apple_iap_key_missing"
        public static let appleIapKeyInvalid = "apple_iap_key_invalid"
        /// 429 from the endpoint's own per-subscriber limit (the gateway's 429 has no body).
        public static let rateLimited = "rate_limited"
    }

    static func mapPromotionalOfferError(_ error: PurchasesError, productId: String, offerId: String) -> PurchasesError {
        typealias C = PromotionalOfferErrorCode
        let status = error.statusCode
        let serverCode = error.serverCode
        func mapped(_ message: String, _ code: PurchaseErrorCode) -> PurchasesError {
            PurchasesError(message, code: code, statusCode: status, serverCode: serverCode)
        }
        switch (status, serverCode) {
        case (400, C.appAccountTokenMismatch):
            return mapped("BillingBear refused the promotional offer: the account token is not this subscriber's", .validationError)
        case (400, C.productNotInProject):
            return mapped("\(productId) is not an App Store product of this BillingBear project (or of this app's bundle)", .productNotFound)
        case (400, _):
            return mapped("BillingBear rejected the promotional offer request: \(error.message)", .validationError)
        case (404, C.subscriberNotFound):
            return mapped(
                "BillingBear does not know this subscriber yet (no customer record), so it cannot sign a promotional offer for them",
                .validationError
            )
        case (404, _):
            return mapped(
                "Promotional offer \(offerId) is not configured in BillingBear (add it as a Customer Center retention offer's store offer id)",
                .productNotFound
            )
        case (409, C.appleIapKeyMissing):
            return mapped(
                "The BillingBear project has no App Store In-App Purchase key for this app, so it cannot sign promotional offers. Upload the key in the dashboard.",
                .notConfigured
            )
        case (409, C.appleIapKeyInvalid):
            return mapped(
                "The App Store In-App Purchase key configured in BillingBear for this app cannot be read. Upload it again in the dashboard.",
                .notConfigured
            )
        case (429, _):
            // The gateway's empty-body 429 and the endpoint's `rate_limited` mean the same: back off.
            return mapped("Too many promotional offer requests for this subscriber; try again in a minute", .networkError)
        case (401, _), (403, _):
            return mapped(
                "BillingBear refused the promotional offer request: it needs this subscriber's end-user token (PurchasesOptions.endUserTokenProvider)",
                .notConfigured
            )
        default:
            return error
        }
    }

    /// Encode a ValidateRequest, folding in the configured bundleId (mirrors RN/Android which
    /// spread `{ ...req, bundleId }` so a multi-brand backend scopes the subscription correctly).
    private func encodeValidate(_ validate: ValidateRequest) throws -> Data {
        let base = try JSONEncoder().encode(validate)
        guard let bundleId else { return base }
        guard var dict = try JSONSerialization.jsonObject(with: base) as? [String: Any] else { return base }
        dict["bundleId"] = bundleId
        return try JSONSerialization.data(withJSONObject: dict)
    }

    // MARK: Customer lifecycle

    /// POST /v1/customers/login -> the identified appUserId.
    public func login(anonymousAppUserId: String, identifiedAppUserId: String) async throws -> String {
        struct Body: Encodable { let anonymousAppUserId: String; let identifiedAppUserId: String }
        let body = try JSONEncoder().encode(Body(anonymousAppUserId: anonymousAppUserId, identifiedAppUserId: identifiedAppUserId))
        let res: LoginResponse = try await request("/v1/customers/login", method: "POST", body: body)
        return res.appUserId
    }

    /// POST /v1/customers/logout -> a fresh anonymous appUserId.
    public func logout(appUserId: String) async throws -> String {
        struct Body: Encodable { let appUserId: String }
        let body = try JSONEncoder().encode(Body(appUserId: appUserId))
        let res: LogoutResponse = try await request("/v1/customers/logout", method: "POST", body: body)
        return res.newAnonymousAppUserId
    }

    // MARK: Checkout

    /// POST /v1/checkout/session -> CheckoutSession. The appUserId is merged into the body.
    public func createCheckoutSession(appUserId: String, request checkout: CheckoutSessionRequest) async throws -> CheckoutSession {
        // Mirror the RN SDK which spreads { appUserId, ...req } into the body.
        var dict: [String: Any] = [
            "appUserId": appUserId,
            "priceId": checkout.priceId,
            "successUrl": checkout.successUrl,
            "cancelUrl": checkout.cancelUrl
        ]
        if let metadata = checkout.metadata {
            dict["metadata"] = metadata
        }
        let body = try JSONSerialization.data(withJSONObject: dict)
        return try await request("/v1/checkout/session", method: "POST", body: body)
    }

    // MARK: Paywalls

    /// GET /v1/paywalls/by-identifier/{identifier} -> a fully typed `PaywallResponse`.
    ///
    /// Returns `nil` on 404 (no version published yet), mirroring the RN SDK's `fetchPaywall`.
    /// Pass `appUserId` to opt into A/B variant assignment; `country`/`platform` feed audience
    /// targeting. The decoder ignores unknown fields so the dashboard can add document keys
    /// without breaking already-shipped apps.
    public func getPaywall(
        identifier: String,
        appUserId: String? = nil,
        country: String? = nil,
        platform: String? = nil
    ) async throws -> PaywallResponse? {
        let encoded = identifier.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? identifier
        var items: [URLQueryItem] = []
        if let appUserId { items.append(URLQueryItem(name: "appUserId", value: appUserId)) }
        if let country { items.append(URLQueryItem(name: "country", value: country)) }
        if let platform { items.append(URLQueryItem(name: "platform", value: platform)) }
        var path = "/v1/paywalls/by-identifier/\(encoded)"
        if !items.isEmpty {
            var comps = URLComponents()
            comps.queryItems = items
            path += "?\(comps.percentEncodedQuery ?? "")"
        }
        do {
            let res: PaywallResponse = try await request(path)
            return res
        } catch let e as PurchasesError {
            if e.statusCode == 404 { return nil }
            throw e
        }
    }

    /// POST /v1/paywalls/by-identifier/{identifier}/exposures — fire-and-forget telemetry.
    /// Records a `viewed` / `dismissed` / `purchased` lifecycle event (or an exit offer's
    /// `exit_offer_*` on its source paywall). Never throws to the caller (the user-facing paywall
    /// must not break on a telemetry blip).
    ///
    /// `presentationId`: the placement decision's `presentationId`, on that presentation's `viewed`
    /// only. The server then folds this view into the row its evaluation recorded (taking the
    /// experiment cell) instead of adding a second view.
    public func recordExposure(
        identifier: String,
        outcome: PaywallExposureOutcome,
        appUserId: String,
        experimentId: String? = nil,
        variant: String? = nil,
        presentationId: String? = nil
    ) async {
        let encoded = identifier.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? identifier
        struct Body: Encodable {
            let appUserId: String
            let outcome: String
            let experimentId: String?
            let variant: String?
            let presentationId: String?
        }
        let payload = Body(
            appUserId: appUserId, outcome: outcome.rawValue, experimentId: experimentId, variant: variant,
            presentationId: presentationId.flatMap { $0.isEmpty ? nil : $0 })
        guard let body = try? JSONEncoder().encode(payload) else { return }
        let _: EmptyResponse? = try? await request("/v1/paywalls/by-identifier/\(encoded)/exposures", method: "POST", body: body)
    }

    // MARK: Subscriber attributes / devices

    /// POST /v1/subscribers/{appUserId}/attributes — upsert custom subscriber attributes.
    public func setAttributes(appUserId: String, attributes: [String: String]) async throws {
        let encoded = appUserId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? appUserId
        struct Body: Encodable { let attributes: [String: String] }
        let body = try JSONEncoder().encode(Body(attributes: attributes))
        let _: EmptyResponse = try await request("/v1/subscribers/\(encoded)/attributes", method: "POST", body: body)
    }

    /// POST /v1/subscribers/{appUserId}/devices — register a push device. Returns the created device.
    @discardableResult
    public func registerPushToken(appUserId: String, pushToken: String, platform: String) async throws -> Device {
        let encoded = appUserId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? appUserId
        struct Body: Encodable { let pushToken: String; let platform: String }
        let body = try JSONEncoder().encode(Body(pushToken: pushToken, platform: platform))
        return try await request("/v1/subscribers/\(encoded)/devices", method: "POST", body: body)
    }

    // MARK: Placements (Superwall-style triggers)

    /// POST /v1/placements/{placement}/evaluate -> CampaignDecision.
    public func evaluatePlacement(placement: String, appUserId: String) async throws -> CampaignDecision {
        let encoded = placement.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? placement
        struct Body: Encodable { let appUserId: String }
        let body = try JSONEncoder().encode(Body(appUserId: appUserId))
        return try await request("/v1/placements/\(encoded)/evaluate", method: "POST", body: body)
    }

    // MARK: Customer Center

    /// GET /v1/customer-center/{appUserId} -> the subscriptions + themeable config the
    /// `BillingBearCustomerCenter` view renders.
    public func getCustomerCenter(appUserId: String) async throws -> CustomerCenterData {
        let encoded = appUserId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? appUserId
        return try await request("/v1/customer-center/\(encoded)", headers: try await endUserHeaders(appUserId))
    }

    /// POST .../subscriptions/{subId}/cancel — cancel now or at period end.
    public func ccCancel(appUserId: String, subscriptionId: String, mode: CustomerCenterCancelMode) async throws {
        struct Body: Encodable { let mode: String }
        let body = try JSONEncoder().encode(Body(mode: mode.rawValue))
        try await ccPost(appUserId: appUserId, subscriptionId: subscriptionId, action: "cancel", body: body)
    }

    /// POST .../subscriptions/{subId}/reactivate — re-enable a period-end cancellation.
    public func ccReactivate(appUserId: String, subscriptionId: String) async throws {
        try await ccPost(appUserId: appUserId, subscriptionId: subscriptionId, action: "reactivate", body: emptyJSONObject())
    }

    /// POST .../subscriptions/{subId}/change-plan — switch to a different product.
    public func ccChangePlan(appUserId: String, subscriptionId: String, newProductId: String) async throws {
        struct Body: Encodable { let newProductId: String }
        let body = try JSONEncoder().encode(Body(newProductId: newProductId))
        try await ccPost(appUserId: appUserId, subscriptionId: subscriptionId, action: "change-plan", body: body)
    }

    /// POST .../subscriptions/{subId}/refund — request a refund.
    public func ccRefund(appUserId: String, subscriptionId: String) async throws {
        try await ccPost(appUserId: appUserId, subscriptionId: subscriptionId, action: "refund", body: emptyJSONObject())
    }

    /// POST .../subscriptions/{subId}/accept-offer — claim a win-back offer.
    public func ccAcceptOffer(appUserId: String, subscriptionId: String, offerId: String) async throws -> CustomerCenterAcceptOfferResult {
        let u = appUserId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? appUserId
        let s = subscriptionId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? subscriptionId
        struct Body: Encodable { let offerId: String }
        let body = try JSONEncoder().encode(Body(offerId: offerId))
        return try await request(
            "/v1/customer-center/\(u)/subscriptions/\(s)/accept-offer",
            method: "POST", body: body, headers: try await endUserHeaders(appUserId)
        )
    }

    /// POST /v1/customer-center/{appUserId}/survey — best-effort cancellation survey.
    public func ccSurvey(appUserId: String, reason: String, comment: String? = nil, subscriptionId: String? = nil) async throws {
        let u = appUserId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? appUserId
        struct Body: Encodable { let reason: String; let comment: String?; let subscriptionId: String? }
        let body = try JSONEncoder().encode(Body(reason: reason, comment: comment, subscriptionId: subscriptionId))
        let _: EmptyResponse = try await request(
            "/v1/customer-center/\(u)/survey", method: "POST", body: body, headers: try await endUserHeaders(appUserId)
        )
    }

    private func ccPost(appUserId: String, subscriptionId: String, action: String, body: Data) async throws {
        let u = appUserId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? appUserId
        let s = subscriptionId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? subscriptionId
        let _: EmptyResponse = try await request(
            "/v1/customer-center/\(u)/subscriptions/\(s)/\(action)",
            method: "POST", body: body, headers: try await endUserHeaders(appUserId)
        )
    }

    // MARK: Virtual Currencies
    //
    // FOLLOW-UP: the native CustomerCenter view (`BillingBearCustomerCenter`) does not yet
    // surface a Balances section. The RN <CustomerCenter /> already renders balances; mirror
    // that here in a later round. The transport + facade below are in place now.

    /// GET /v1/subscribers/{appUserId}/virtual-currencies -> the subscriber's balances.
    public func getVirtualCurrencies(appUserId: String) async throws -> [VirtualCurrencyBalance] {
        let encoded = appUserId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? appUserId
        let res: VirtualCurrenciesResponse = try await request("/v1/subscribers/\(encoded)/virtual-currencies")
        return res.balances
    }

    /// GET /v1/subscribers/{appUserId}/offerings -> the project's configured offerings, with the
    /// current one resolved server-side via targeting. `country`/`platform` refine the attached
    /// paywall's A/B variant assignment.
    public func getOfferings(appUserId: String, country: String? = nil, platform: String? = nil) async throws -> Offerings {
        let encoded = appUserId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? appUserId
        var items: [URLQueryItem] = []
        if let country { items.append(URLQueryItem(name: "country", value: country)) }
        if let platform { items.append(URLQueryItem(name: "platform", value: platform)) }
        var path = "/v1/subscribers/\(encoded)/offerings"
        if !items.isEmpty {
            var comps = URLComponents()
            comps.queryItems = items
            path += "?\(comps.percentEncodedQuery ?? "")"
        }
        return try await request(path)
    }

    /// POST /v1/subscribers/{appUserId}/virtual-currencies/{code}/spend -> the new balance.
    /// Throws a `PurchasesError` (HTTP 400) when the subscriber has insufficient balance.
    @discardableResult
    public func spendVirtualCurrency(appUserId: String, code: String, amount: Double, reason: String? = nil) async throws -> SpendVirtualCurrencyResult {
        let u = appUserId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? appUserId
        let c = code.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? code
        struct Body: Encodable { let amount: Double; let reason: String? }
        let body = try JSONEncoder().encode(Body(amount: amount, reason: reason))
        return try await request(
            "/v1/subscribers/\(u)/virtual-currencies/\(c)/spend",
            method: "POST", body: body, headers: try await endUserHeaders(appUserId)
        )
    }

    private func emptyJSONObject() -> Data { Data("{}".utf8) }
}

/// Wire shape for GET .../virtual-currencies.
struct VirtualCurrenciesResponse: Decodable {
    let balances: [VirtualCurrencyBalance]
}

/// Response of POST .../virtual-currencies/{code}/spend — the new balance for that currency.
public struct SpendVirtualCurrencyResult: Codable, Equatable, Sendable {
    public let code: String
    public let balance: Double

    public init(code: String, balance: Double) {
        self.code = code
        self.balance = balance
    }
}

/// Outcome recorded by `recordExposure`, mirroring the RN SDK's exposure outcomes.
public enum PaywallExposureOutcome: String, Sendable, CaseIterable {
    case viewed
    case dismissed
    case purchased
    /// Recorded on the SOURCE paywall when its exit offer takes its place.
    case exitOfferViewed = "exit_offer_viewed"
    /// Recorded on the SOURCE paywall when the customer buys from its exit offer.
    case exitOfferPurchased = "exit_offer_purchased"
    /// Recorded on the SOURCE paywall when the customer closes its exit offer, ending the flow.
    case exitOfferDismissed = "exit_offer_dismissed"
}

/// A registered push device for a subscriber (POST /v1/subscribers/{id}/devices response).
public struct Device: Codable, Equatable, Sendable {
    public let id: String
    public let pushToken: String
    public let platform: String

    public init(id: String, pushToken: String, platform: String) {
        self.id = id
        self.pushToken = pushToken
        self.platform = platform
    }
}

/// Sentinel for endpoints whose response body is ignored.
struct EmptyResponse: Decodable {
    init() {}
    init(from decoder: Decoder) throws {}
}
