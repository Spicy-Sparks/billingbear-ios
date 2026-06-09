import Foundation

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
    public var userCancelled: Bool { code == .userCancelled }

    public init(_ message: String, code: PurchaseErrorCode = .unknown, statusCode: Int = 0) {
        self.message = message
        self.code = code
        self.statusCode = statusCode
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
    let productId: String
    let expiresAt: String?
    let startsAt: String?
    let cancelledAt: String?
    let willRenew: Bool
    let isGracePeriod: Bool
}

struct RawEntitlementsResponse: Decodable {
    let userId: String?
    let isPremium: Bool
    let entitlements: [String]
    let subscription: RawSubscription?
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

    public init(
        appUserId: String,
        providerType: Int,
        transactionId: String? = nil,
        originalTransactionId: String? = nil,
        productId: String? = nil,
        receipt: String? = nil,
        providerData: [String: String] = [:]
    ) {
        self.appUserId = appUserId
        self.providerType = providerType
        self.transactionId = transactionId
        self.originalTransactionId = originalTransactionId
        self.productId = productId
        self.receipt = receipt
        self.providerData = providerData
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
    5: "gift", 6: "referral", 7: "admin", 8: "promo"
]

/// Async REST client for the BillingBear backend. Uses `URLSession`, Bearer `pk_` auth,
/// and a configurable base URL (default https://api.billingbear.io).
public final class BillingBearAPI: @unchecked Sendable {
    private let apiKey: String
    private let baseURL: String
    private let bundleId: String?
    private let session: URLSession
    /// Test seam: overridable so unit tests don't sleep real wall-clock time.
    private let sleep: @Sendable (UInt64) async -> Void

    public init(
        apiKey: String,
        baseURL: String = "https://api.billingbear.io",
        bundleId: String? = nil,
        session: URLSession = .shared,
        sleep: @escaping @Sendable (UInt64) async -> Void = { try? await Task.sleep(nanoseconds: $0) }
    ) {
        self.apiKey = apiKey
        // Strip a single trailing slash so path concatenation is clean (mirrors RN configureApi).
        if baseURL.hasSuffix("/") {
            self.baseURL = String(baseURL.dropLast())
        } else {
            self.baseURL = baseURL
        }
        self.bundleId = bundleId
        self.session = session
        self.sleep = sleep
    }

    // MARK: Core request

    private func request<T: Decodable>(
        _ path: String,
        method: String = "GET",
        body: Data? = nil
    ) async throws -> T {
        guard let url = URL(string: "\(baseURL)\(path)") else {
            throw PurchasesError("Invalid URL: \(baseURL)\(path)", code: .unknown)
        }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = body

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: req)
        } catch {
            throw PurchasesError(error.localizedDescription, code: .networkError)
        }

        guard let http = response as? HTTPURLResponse else {
            throw PurchasesError("No HTTP response", code: .networkError)
        }

        guard (200..<300).contains(http.statusCode) else {
            let message = Self.extractErrorMessage(from: data) ?? "HTTP \(http.statusCode)"
            throw PurchasesError(message, code: .validationError, statusCode: http.statusCode)
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

    /// Mirrors the RN SDK error extraction: body.error.error || body.error.message.
    private static func extractErrorMessage(from data: Data) -> String? {
        guard
            let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let err = obj["error"] as? [String: Any]
        else { return nil }
        return (err["error"] as? String) ?? (err["message"] as? String)
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
                productId: sub.productId,
                expiresAt: sub.expiresAt,
                startsAt: sub.startsAt,
                cancelledAt: sub.cancelledAt,
                willRenew: sub.willRenew,
                isGracePeriod: sub.isGracePeriod
            )
        }

        return CustomerInfo(
            appUserId: appUserId,
            isPremium: raw.isPremium,
            entitlements: entitlements,
            activeSubscription: activeSubscription
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
    /// Records a `viewed` / `dismissed` / `purchased` lifecycle event. Never throws to the
    /// caller (the user-facing paywall must not break on a telemetry blip).
    public func recordExposure(
        identifier: String,
        outcome: PaywallExposureOutcome,
        appUserId: String,
        experimentId: String? = nil,
        variant: String? = nil
    ) async {
        let encoded = identifier.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? identifier
        struct Body: Encodable {
            let appUserId: String
            let outcome: String
            let experimentId: String?
            let variant: String?
        }
        let payload = Body(appUserId: appUserId, outcome: outcome.rawValue, experimentId: experimentId, variant: variant)
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
        return try await request("/v1/customer-center/\(encoded)")
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
        return try await request("/v1/customer-center/\(u)/subscriptions/\(s)/accept-offer", method: "POST", body: body)
    }

    /// POST /v1/customer-center/{appUserId}/survey — best-effort cancellation survey.
    public func ccSurvey(appUserId: String, reason: String, comment: String? = nil, subscriptionId: String? = nil) async throws {
        let u = appUserId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? appUserId
        struct Body: Encodable { let reason: String; let comment: String?; let subscriptionId: String? }
        let body = try JSONEncoder().encode(Body(reason: reason, comment: comment, subscriptionId: subscriptionId))
        let _: EmptyResponse = try await request("/v1/customer-center/\(u)/survey", method: "POST", body: body)
    }

    private func ccPost(appUserId: String, subscriptionId: String, action: String, body: Data) async throws {
        let u = appUserId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? appUserId
        let s = subscriptionId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? subscriptionId
        let _: EmptyResponse = try await request("/v1/customer-center/\(u)/subscriptions/\(s)/\(action)", method: "POST", body: body)
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
        return try await request("/v1/subscribers/\(u)/virtual-currencies/\(c)/spend", method: "POST", body: body)
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
public enum PaywallExposureOutcome: String, Sendable {
    case viewed
    case dismissed
    case purchased
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
