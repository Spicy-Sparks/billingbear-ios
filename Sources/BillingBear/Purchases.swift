import Foundation
import StoreKit

#if canImport(UIKit)
import UIKit
#endif

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Result of a successful purchase, mirroring the RN SDK's `PurchaseResult`.
public struct PurchaseResult: Sendable {
    public let customerInfo: CustomerInfo
    public let productId: String
    public let transactionId: String?
}

// MARK: - Speed-layer configuration
//
// The SPEED LAYER is what wins over webview paywalls: prefetch documents + offerings right after
// configure() and on every app-foreground, persist them, then present synchronously from cache (zero
// network on the hot path) with background stale-while-revalidate. This struct tunes that behaviour.
// All fields have sane defaults so the layer is on by default and additive — callers opt OUT.

public struct SpeedLayerConfig: Sendable {
    /// Master switch. When false, no prefetch runs and no foreground observer is registered; the
    /// present path falls back to the live network fetch (the prior behaviour).
    public var prefetchEnabled: Bool
    /// How long a cached paywall is considered "fresh" enough to render with zero revalidation.
    /// Stale entries still render instantly while a background revalidate runs. Default 5 minutes.
    public var paywallTTL: TimeInterval
    /// TTL for cached offerings used by `cachedOfferings(maxAge:)`. Default 5 minutes.
    public var offeringsTTL: TimeInterval
    /// Paywall identifiers to prefetch after configure + on foreground. The app declares which
    /// paywalls it can present so they are warm before the first `present`. Empty = prefetch only
    /// offerings (+ any paywalls attached to them).
    public var prefetchIdentifiers: [String]
    /// Best-effort image/poster prewarm during prefetch. Never blocks first paint. Default true.
    public var prewarmAssets: Bool

    public init(
        prefetchEnabled: Bool = true,
        paywallTTL: TimeInterval = 300,
        offeringsTTL: TimeInterval = 300,
        prefetchIdentifiers: [String] = [],
        prewarmAssets: Bool = true
    ) {
        self.prefetchEnabled = prefetchEnabled
        self.paywallTTL = paywallTTL
        self.offeringsTTL = offeringsTTL
        self.prefetchIdentifiers = prefetchIdentifiers
        self.prewarmAssets = prewarmAssets
    }
}

/// Outcome of a `getPaywallCached` read, so callers can tell instant-from-cache from a live fetch and
/// react accordingly (e.g. show a spinner only on a true cache miss).
public enum PaywallSource: Sendable, Equatable {
    /// Served synchronously from a fresh cache entry — zero network on the hot path.
    case freshCache
    /// Served from a stale cache entry; a background revalidate was kicked off.
    case staleCache
    /// No usable cache entry; the value came from a live network fetch.
    case network
    /// No cache and the network fetch failed; nothing to render.
    case unavailable
}

/// Result of `getPaywallCached`: the response (nil when unavailable) + where it came from.
public struct CachedPaywallResult: Sendable {
    public let response: PaywallResponse?
    public let source: PaywallSource

    public init(response: PaywallResponse?, source: PaywallSource) {
        self.response = response
        self.source = source
    }
}

/// Top-level entry point for the BillingBear iOS SDK.
///
/// Mirrors the React Native `Purchases` API: anonymous-first user management (the anonymous
/// appUserId is persisted in `UserDefaults`), entitlement lookups, login/logout, web checkout,
/// and StoreKit 2 purchases whose transactions are validated against the backend.
public actor Purchases {

    // MARK: Singleton

    /// Shared instance, configured via `configure(apiKey:appUserId:)`.
    public static let shared = Purchases()

    // MARK: State

    private var api: BillingBearAPI?
    private var _appUserId: String = ""
    private var isAnonymousUser: Bool = true
    private let defaults: UserDefaults

    static let anonymousIdKey = "com.billingbear.anonymousAppUserId"

    // MARK: Speed layer

    /// Persistent paywall/offerings cache. Created at configure time, namespaced per project. nil
    /// until configured. Injectable via `configure(api:cache:...)` for tests. Mirrored into
    /// `cacheBox` so the nonisolated synchronous getters (`cachedPaywall(_:)`) can read it.
    private var cache: PaywallCache? {
        didSet { cacheBox.value = cache }
    }
    /// Thread-safe, nonisolated mirror of `cache` for the synchronous instant-present getters.
    private nonisolated let cacheBox = LockedBox<PaywallCache?>(nil)
    /// Speed-layer behaviour (prefetch on/off, TTL, asset prewarm, identifiers to prefetch).
    private var speed: SpeedLayerConfig = .init()
    /// Forwarded country to prefetch/getPaywall when the caller doesn't override it.
    private var prefetchCountry: String?
    /// Foreground-observer token so we prefetch again each time the app returns to the foreground.
    private var foregroundObserver: NSObjectProtocol?
    /// Guards against overlapping prefetch passes (e.g. configure + immediate foreground).
    private var prefetchInFlight = false

    // MARK: Init

    /// Designated initialiser. The default `UserDefaults.standard` is used by the singleton;
    /// tests can inject a suite-scoped store.
    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    deinit {
        // Release the foreground observer if one was registered. (NotificationCenter holds the token,
        // not self; removing here avoids a dangling block after the actor is gone.)
        #if canImport(UIKit)
        if let observer = foregroundObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        #endif
    }

    // MARK: Configure

    /// Configure the SDK. If `appUserId` is nil, an anonymous id is read from (or created in)
    /// `UserDefaults`, mirroring the RN SDK's anonymous-first behaviour. `bundleId` is sent with
    /// confirm/restore so a multi-brand backend scopes the subscription to the right app.
    ///
    /// The SPEED LAYER is configured here too (additive — existing callers get the defaults): after
    /// configure the SDK prefetches `speed.prefetchIdentifiers` + offerings in the background and
    /// re-prefetches on every app-foreground, persisting them so `present` paints from cache instantly.
    public func configure(
        apiKey: String,
        appUserId: String? = nil,
        baseURL: String = "https://api.billingbear.io",
        bundleId: String? = nil,
        speed: SpeedLayerConfig = .init(),
        country: String? = nil
    ) {
        self.api = BillingBearAPI(apiKey: apiKey, baseURL: baseURL, bundleId: bundleId ?? Bundle.main.bundleIdentifier)
        // Namespace the on-device cache by the API key so two projects/keys can't collide.
        self.cache = PaywallCache(store: FilePaywallCacheStore(), project: apiKey)
        self.speed = speed
        self.prefetchCountry = country
        applyIdentity(appUserId)
        startSpeedLayer()
    }

    /// Test/advanced seam: configure with an explicit API client (e.g. one backed by a mocked
    /// URLSession) and, optionally, an explicit cache (e.g. a temp-dir + fixed-clock store). The
    /// foreground observer is NOT registered here so headless tests stay deterministic; call
    /// `prefetch()` directly instead.
    public func configure(
        api: BillingBearAPI,
        appUserId: String? = nil,
        cache: PaywallCache? = nil,
        speed: SpeedLayerConfig = .init()
    ) {
        self.api = api
        self.cache = cache
        self.speed = speed
        applyIdentity(appUserId)
    }

    private func applyIdentity(_ appUserId: String?) {
        if let appUserId, !appUserId.isEmpty {
            self._appUserId = appUserId
            self.isAnonymousUser = false
        } else {
            self._appUserId = Self.loadOrCreateAnonymousId(in: defaults)
            self.isAnonymousUser = true
        }
    }

    // MARK: Identity accessors

    public var appUserId: String { _appUserId }
    public var isAnonymous: Bool { isAnonymousUser }

    private func requireApi() throws -> BillingBearAPI {
        guard let api else {
            throw PurchasesError("Purchases not configured. Call configure(apiKey:) first.", code: .notConfigured)
        }
        return api
    }

    private static func loadOrCreateAnonymousId(in defaults: UserDefaults) -> String {
        if let existing = defaults.string(forKey: anonymousIdKey), !existing.isEmpty {
            return existing
        }
        let fresh = "$BillingBearAnonymousID:\(UUID().uuidString)"
        defaults.set(fresh, forKey: anonymousIdKey)
        return fresh
    }

    // MARK: Entitlements

    /// Fetch the current customer info from the backend.
    public func customerInfo() async throws -> CustomerInfo {
        let api = try requireApi()
        return try await api.fetchEntitlements(appUserId: _appUserId)
    }

    /// Whether the user currently has premium access.
    public func isPremium() async throws -> Bool {
        try await customerInfo().isPremium
    }

    /// Whether the named entitlement is currently active.
    public func checkEntitlement(_ identifier: String) async throws -> Bool {
        let info = try await customerInfo()
        return info.entitlements[identifier]?.isActive ?? false
    }

    // MARK: Login / Logout

    /// Merge the current anonymous user into an identified user. Returns the resolved customer info.
    @discardableResult
    public func login(_ identifiedAppUserId: String) async throws -> CustomerInfo {
        let api = try requireApi()
        let resolved = try await api.login(anonymousAppUserId: _appUserId, identifiedAppUserId: identifiedAppUserId)
        self._appUserId = resolved
        self.isAnonymousUser = false
        return try await api.fetchEntitlements(appUserId: resolved)
    }

    /// Log out the identified user and revert to a fresh anonymous id (persisted to UserDefaults).
    @discardableResult
    public func logout() async throws -> CustomerInfo {
        let api = try requireApi()
        let newAnon = try await api.logout(appUserId: _appUserId)
        self._appUserId = newAnon
        self.isAnonymousUser = true
        defaults.set(newAnon, forKey: Self.anonymousIdKey)
        return try await api.fetchEntitlements(appUserId: newAnon)
    }

    // MARK: Checkout

    /// Create a Stripe web checkout session for the current user.
    public func createCheckoutSession(
        priceId: String,
        successUrl: String,
        cancelUrl: String,
        metadata: [String: String]? = nil
    ) async throws -> CheckoutSession {
        let api = try requireApi()
        let req = CheckoutSessionRequest(
            priceId: priceId,
            successUrl: successUrl,
            cancelUrl: cancelUrl,
            metadata: metadata
        )
        return try await api.createCheckoutSession(appUserId: _appUserId, request: req)
    }

    // MARK: Subscriber attributes / identity

    /// Attach custom subscriber attributes (upsert). Mirrors RN `setAttributes`.
    public func setAttributes(_ attributes: [String: String]) async throws {
        let api = try requireApi()
        try await api.setAttributes(appUserId: _appUserId, attributes: attributes)
    }

    /// Set the subscriber's reserved `$email` attribute. Pass "" to clear. Mirrors RN `setEmail`.
    public func setEmail(_ email: String) async throws {
        try await setAttributes(["$email": email])
    }

    /// Set the subscriber's reserved `$displayName` attribute. Pass "" to clear.
    public func setDisplayName(_ displayName: String) async throws {
        try await setAttributes(["$displayName": displayName])
    }

    /// Set the subscriber's reserved `$phoneNumber` attribute (E.164). Pass "" to clear.
    public func setPhoneNumber(_ phoneNumber: String) async throws {
        try await setAttributes(["$phoneNumber": phoneNumber])
    }

    /// Register the end-user's push device so server-side win-back / dunning campaigns can reach
    /// them. `platform` defaults to "ios". Returns the created device.
    @discardableResult
    public func registerPushToken(_ token: String, platform: String = "ios") async throws -> Device {
        let api = try requireApi()
        return try await api.registerPushToken(appUserId: _appUserId, pushToken: token, platform: platform)
    }

    // MARK: Virtual Currencies

    /// Fetch the current subscriber's virtual-currency balances (e.g. in-app coins / gems).
    /// Returns one entry per currency the user holds.
    ///
    /// FOLLOW-UP: the bundled `BillingBearCustomerCenter` view does not yet render a Balances
    /// section (the RN `<CustomerCenter />` already does). Wire it up in a later round.
    public func getVirtualCurrencies() async throws -> [VirtualCurrencyBalance] {
        let api = try requireApi()
        return try await api.getVirtualCurrencies(appUserId: _appUserId)
    }

    /// Fetch the current subscriber's offerings — the RevenueCat `getOfferings()` equivalent.
    /// Returns all active offerings plus which is current (server-resolved via targeting, default
    /// fallback), each with its packages and an optional attached paywall.
    public func getOfferings(country: String? = nil, platform: String? = nil) async throws -> Offerings {
        let api = try requireApi()
        return try await api.getOfferings(appUserId: _appUserId, country: country, platform: platform)
    }

    /// Spend an amount of a virtual currency for the current subscriber. Returns the new balance
    /// for that currency. Throws (HTTP 400) when the balance is insufficient.
    @discardableResult
    public func spendVirtualCurrency(code: String, amount: Double, reason: String? = nil) async throws -> SpendVirtualCurrencyResult {
        let api = try requireApi()
        return try await api.spendVirtualCurrency(appUserId: _appUserId, code: code, amount: amount, reason: reason)
    }

    // MARK: Placements (Superwall-style triggers)

    /// Register a placement (named app event) and ask the backend whether to show a paywall.
    /// When `present` is true, fetch the paywall with `getPaywall(decision.paywallIdentifier)`.
    public func register(_ placement: String) async throws -> CampaignDecision {
        let api = try requireApi()
        return try await api.evaluatePlacement(placement: placement, appUserId: _appUserId)
    }

    // MARK: Paywalls

    /// Fetch the published paywall by identifier. Returns `nil` on 404 (no version published).
    /// Pass `country`/`platform` for audience targeting; the appUserId is taken from the SDK.
    public func getPaywall(
        _ identifier: String,
        country: String? = nil,
        platform: String = "ios"
    ) async throws -> PaywallResponse? {
        let api = try requireApi()
        return try await api.getPaywall(
            identifier: identifier,
            appUserId: _appUserId,
            country: country,
            platform: platform
        )
    }

    /// Record a paywall lifecycle event (`viewed` / `dismissed` / `purchased`). Fire-and-forget.
    public func recordExposure(
        identifier: String,
        outcome: PaywallExposureOutcome,
        experimentId: String? = nil,
        variant: String? = nil
    ) async {
        guard let api else { return }
        await api.recordExposure(
            identifier: identifier,
            outcome: outcome,
            appUserId: _appUserId,
            experimentId: experimentId,
            variant: variant
        )
    }

    // MARK: - Speed layer: prefetch + instant present + cache

    /// Register the app-foreground observer (so we re-prefetch on every return to foreground) and
    /// kick off the initial prefetch pass. No-op when prefetch is disabled. Idempotent.
    private func startSpeedLayer() {
        guard speed.prefetchEnabled else { return }
        registerForegroundObserver()
        Task { await self.prefetch() }
    }

    private func registerForegroundObserver() {
        #if canImport(UIKit)
        guard foregroundObserver == nil else { return }
        foregroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            guard let self else { return }
            Task { await self.prefetch() }
        }
        #endif
    }

    /// Stop observing app-foreground notifications. Called automatically on deinit; exposed so hosts
    /// that tear down the SDK can release the observer explicitly.
    public func stopSpeedLayer() {
        #if canImport(UIKit)
        if let observer = foregroundObserver {
            NotificationCenter.default.removeObserver(observer)
            foregroundObserver = nil
        }
        #endif
    }

    /// PREFETCH: fetch the project's offerings + the declared paywall documents in the background and
    /// write them to the persistent cache (with a fetchedAt timestamp). Safe to call repeatedly; it
    /// de-dupes overlapping passes. Best-effort asset prewarm runs after each document is cached.
    ///
    /// Network/parse errors are NOT swallowed: each failing fetch throws into `errors`, returned for
    /// the caller to log. A successful pass returns an empty array.
    @discardableResult
    public func prefetch() async -> [Error] {
        guard speed.prefetchEnabled else { return [] }
        guard let api, let cache else { return [] }
        if prefetchInFlight { return [] }
        prefetchInFlight = true
        defer { prefetchInFlight = false }

        var errors: [Error] = []
        let appUserId = _appUserId
        let country = prefetchCountry

        // 1) Offerings — carry live product metadata + any attached paywalls.
        do {
            let offerings = try await api.getOfferings(appUserId: appUserId, country: country, platform: "ios")
            try cache.writeOfferings(offerings)
            // An offering can attach its own paywall — warm those too.
            for offering in offerings.offerings {
                if let attached = offering.paywall {
                    do { try cache.writePaywall(attached.identifier, response: attached) }
                    catch { errors.append(error) }
                    prewarmIfEnabled(attached.document)
                }
            }
        } catch {
            errors.append(error)
        }

        // 2) Declared paywall identifiers.
        for identifier in speed.prefetchIdentifiers {
            do {
                if let response = try await api.getPaywall(
                    identifier: identifier,
                    appUserId: appUserId,
                    country: country,
                    platform: "ios"
                ) {
                    try cache.writePaywall(identifier, response: response)
                    prewarmIfEnabled(response.document)
                }
                // A 404 (nil) is a normal "not published yet" — not an error.
            } catch {
                errors.append(error)
            }
        }

        return errors
    }

    private func prewarmIfEnabled(_ doc: PaywallDocument) {
        guard speed.prewarmAssets else { return }
        PaywallAssetPrewarmer.prewarm(PaywallAssetPrewarmer.assetURLs(in: doc))
    }

    /// INSTANT PRESENT — synchronous cached read. Returns the cached paywall (fresh OR stale) with no
    /// network and no await, so a SwiftUI view can render it on the first frame. Returns nil only on a
    /// true cache miss. Pair with `getPaywallCached` to revalidate in the background.
    public nonisolated func cachedPaywall(_ identifier: String) -> PaywallResponse? {
        // `cache` is actor-isolated; read it through an unsafe-but-correct synchronous bridge below.
        cacheSnapshot()?.anyPaywall(identifier)
    }

    /// Synchronous cached offerings (fresh or stale). Nil on a miss.
    public nonisolated func cachedOfferings() -> Offerings? {
        cacheSnapshot()?.anyOfferings()
    }

    /// Synchronous cached offerings only when fresh within `maxAge` (defaults to the configured TTL).
    public nonisolated func cachedOfferings(maxAge: TimeInterval) -> Offerings? {
        cacheSnapshot()?.freshOfferings(ttl: maxAge)
    }

    /// STALE-WHILE-REVALIDATE present path. Reads the cache synchronously: a fresh entry is returned
    /// immediately (zero network); a stale entry is returned immediately AND a background revalidate
    /// is kicked off; a miss does a live fetch. When offline with a cached entry, the cached doc is
    /// returned. The `source` tells the caller which path served the value.
    public func getPaywallCached(
        _ identifier: String,
        country: String? = nil
    ) async -> CachedPaywallResult {
        guard let cache else {
            // No cache configured → behave like a plain fetch.
            let live = try? await getPaywall(identifier, country: country)
            return CachedPaywallResult(response: live, source: live == nil ? .unavailable : .network)
        }

        // Fresh cache → instant, no network.
        if let fresh = cache.freshPaywall(identifier, ttl: speed.paywallTTL) {
            return CachedPaywallResult(response: fresh, source: .freshCache)
        }

        // Stale cache → serve it now, revalidate in the background.
        if let stale = cache.anyPaywall(identifier) {
            Task { await self.revalidatePaywall(identifier, country: country) }
            return CachedPaywallResult(response: stale, source: .staleCache)
        }

        // Miss → live fetch (and cache it). Offline / failure surfaces as `.unavailable`.
        do {
            if let response = try await fetchAndCachePaywall(identifier, country: country) {
                return CachedPaywallResult(response: response, source: .network)
            }
            return CachedPaywallResult(response: nil, source: .unavailable)
        } catch {
            // No cache and the network failed — nothing to render. The error is intentionally not
            // swallowed into a misleading "fresh" result; the caller sees `.unavailable`.
            return CachedPaywallResult(response: nil, source: .unavailable)
        }
    }

    /// Background revalidate: fetch fresh, overwrite the cache. Errors are intentionally non-fatal
    /// here (the stale doc already rendered) but are returned so callers that await it can log.
    @discardableResult
    public func revalidatePaywall(_ identifier: String, country: String? = nil) async -> Error? {
        do {
            _ = try await fetchAndCachePaywall(identifier, country: country)
            return nil
        } catch {
            return error
        }
    }

    /// Fetch a paywall from the network and write it to the cache. Returns nil on a 404 (not
    /// published). Throws on network/parse errors (caller decides whether to surface).
    @discardableResult
    private func fetchAndCachePaywall(_ identifier: String, country: String?) async throws -> PaywallResponse? {
        let api = try requireApi()
        let response = try await api.getPaywall(
            identifier: identifier,
            appUserId: _appUserId,
            country: country ?? prefetchCountry,
            platform: "ios"
        )
        if let response, let cache {
            try cache.writePaywall(identifier, response: response)
            prewarmIfEnabled(response.document)
        }
        return response
    }

    /// Invalidate a single cached paywall (memory + disk). The next present forces a network read.
    public func invalidatePaywallCache(_ identifier: String) {
        cache?.invalidatePaywall(identifier)
    }

    /// Invalidate the cached offerings.
    public func invalidateOfferingsCache() {
        cache?.invalidateOfferings()
    }

    /// Invalidate everything the speed-layer cache holds for this project.
    public func invalidatePaywallCache() {
        cache?.invalidateAll()
    }

    /// Update the speed-layer TTL/enable/prewarm/identifiers after configure (additive control).
    public func setSpeedLayerConfig(_ config: SpeedLayerConfig) {
        let wasEnabled = speed.prefetchEnabled
        speed = config
        if config.prefetchEnabled && !wasEnabled {
            startSpeedLayer()
        } else if !config.prefetchEnabled && wasEnabled {
            stopSpeedLayer()
        }
    }

    /// Actor-isolated accessor used by the nonisolated synchronous getters. The actor-stored `cache`
    /// optional cannot be read from a nonisolated context, so its reference is mirrored into a
    /// per-instance lock-protected box whenever `cache` is set. The `PaywallCache` itself is
    /// thread-safe, so handing out the reference for a synchronous read is safe.
    private nonisolated func cacheSnapshot() -> PaywallCache? {
        cacheBox.value
    }

    // MARK: Customer Center

    /// Load the Customer Center payload for a user (defaults to the SDK's tracked appUserId).
    public func getCustomerCenter(appUserId override: String? = nil) async throws -> CustomerCenterData {
        let api = try requireApi()
        return try await api.getCustomerCenter(appUserId: override ?? _appUserId)
    }

    /// Cancel a subscription (immediately or at period end).
    public func ccCancel(subscriptionId: String, mode: CustomerCenterCancelMode, appUserId override: String? = nil) async throws {
        let api = try requireApi()
        try await api.ccCancel(appUserId: override ?? _appUserId, subscriptionId: subscriptionId, mode: mode)
    }

    /// Re-activate a subscription that was set to cancel at period end.
    public func ccReactivate(subscriptionId: String, appUserId override: String? = nil) async throws {
        let api = try requireApi()
        try await api.ccReactivate(appUserId: override ?? _appUserId, subscriptionId: subscriptionId)
    }

    /// Switch a subscription to a different product.
    public func ccChangePlan(subscriptionId: String, newProductId: String, appUserId override: String? = nil) async throws {
        let api = try requireApi()
        try await api.ccChangePlan(appUserId: override ?? _appUserId, subscriptionId: subscriptionId, newProductId: newProductId)
    }

    /// Request a refund for a subscription.
    public func ccRefund(subscriptionId: String, appUserId override: String? = nil) async throws {
        let api = try requireApi()
        try await api.ccRefund(appUserId: override ?? _appUserId, subscriptionId: subscriptionId)
    }

    /// Accept a retention (win-back) offer for a managed subscription.
    public func ccAcceptOffer(subscriptionId: String, offerId: String, appUserId override: String? = nil) async throws -> CustomerCenterAcceptOfferResult {
        let api = try requireApi()
        return try await api.ccAcceptOffer(appUserId: override ?? _appUserId, subscriptionId: subscriptionId, offerId: offerId)
    }

    /// Submit a best-effort cancellation-survey response.
    public func ccSurvey(reason: String, comment: String? = nil, subscriptionId: String? = nil, appUserId override: String? = nil) async throws {
        let api = try requireApi()
        try await api.ccSurvey(appUserId: override ?? _appUserId, reason: reason, comment: comment, subscriptionId: subscriptionId)
    }

    /// Open the system App Store subscriptions management screen.
    @MainActor
    public func manageSubscriptions() {
        #if canImport(UIKit)
        if let url = URL(string: "https://apps.apple.com/account/subscriptions") {
            UIApplication.shared.open(url)
        }
        #endif
    }

    // MARK: StoreKit 2 purchase

    /// Purchase a StoreKit 2 `StoreKit.Product`, then send the verified transaction to the
    /// backend's /subscription/confirm endpoint and return the refreshed customer info.
    ///
    /// Throws `PurchasesError(.userCancelled)` if the user cancels, `.paymentPending` for
    /// deferred purchases, and `.storeError` for unverified transactions.
    @available(iOS 15.0, macOS 12.0, *)
    public func purchase(product: StoreKit.Product) async throws -> PurchaseResult {
        let api = try requireApi()

        let result: StoreKit.Product.PurchaseResult
        do {
            result = try await product.purchase()
        } catch {
            throw PurchasesError(error.localizedDescription, code: .storeError)
        }

        switch result {
        case .success(let verification):
            let transaction = try Self.checkVerified(verification)
            let info = try await Self.validate(
                transaction: transaction,
                productId: product.id,
                appUserId: _appUserId,
                api: api
            )
            await transaction.finish()
            return PurchaseResult(
                customerInfo: info,
                productId: product.id,
                transactionId: String(transaction.id)
            )
        case .userCancelled:
            throw PurchasesError("User cancelled the purchase", code: .userCancelled)
        case .pending:
            throw PurchasesError("Purchase is pending approval", code: .paymentPending)
        @unknown default:
            throw PurchasesError("Unknown purchase result", code: .unknown)
        }
    }

    /// Restore purchases: iterate current StoreKit entitlements, validate each with the backend,
    /// and return the refreshed customer info.
    @available(iOS 15.0, macOS 12.0, *)
    @discardableResult
    public func restore() async throws -> CustomerInfo {
        let api = try requireApi()
        for await result in StoreKit.Transaction.currentEntitlements {
            guard case .verified(let transaction) = result else { continue }
            let validate = ValidateRequest(
                appUserId: _appUserId,
                providerType: ProviderType.apple,
                transactionId: String(transaction.id),
                originalTransactionId: String(transaction.originalID),
                productId: transaction.productID
            )
            _ = try await api.restorePurchases(appUserId: _appUserId, request: validate)
        }
        return try await api.fetchEntitlements(appUserId: _appUserId)
    }

    @available(iOS 15.0, macOS 12.0, *)
    private static func validate(
        transaction: StoreKit.Transaction,
        productId: String,
        appUserId: String,
        api: BillingBearAPI
    ) async throws -> CustomerInfo {
        let validate = ValidateRequest(
            appUserId: appUserId,
            providerType: ProviderType.apple,
            transactionId: String(transaction.id),
            originalTransactionId: String(transaction.originalID),
            productId: productId
        )
        return try await api.validatePurchase(appUserId: appUserId, request: validate)
    }

    @available(iOS 15.0, macOS 12.0, *)
    private static func checkVerified<T>(_ result: VerificationResult<T>) throws -> T {
        switch result {
        case .unverified:
            throw PurchasesError("Transaction failed StoreKit verification", code: .storeError)
        case .verified(let safe):
            return safe
        }
    }
}
