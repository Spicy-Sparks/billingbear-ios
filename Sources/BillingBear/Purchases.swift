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
    /// The store transaction the purchase produced (validated with BillingBear and finished).
    public let transaction: StoreTransaction?
    /// For a consumable or non-consumable: BillingBear's record of it — granted, already recorded,
    /// revoked by the store, transferred from another subscriber, or kept by its original owner. Nil
    /// for subscriptions, and when the transaction had already been validated before this call.
    public let nonSubscriptionRecord: NonSubscriptionPurchaseResult?

    public init(
        customerInfo: CustomerInfo,
        productId: String,
        transactionId: String?,
        transaction: StoreTransaction? = nil,
        nonSubscriptionRecord: NonSubscriptionPurchaseResult? = nil
    ) {
        self.customerInfo = customerInfo
        self.productId = productId
        self.transactionId = transactionId
        self.transaction = transaction
        self.nonSubscriptionRecord = nonSubscriptionRecord
    }
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
///
/// The purchase core (see `Purchases+Transactions.swift`) also listens to `Transaction.updates` from
/// `configure`, replays unfinished transactions at launch and on every foreground, and publishes every
/// customer-info change to `customerInfoStream` and `delegate`.
public actor Purchases {

    // MARK: Singleton

    /// Shared instance, configured via `configure(apiKey:appUserId:)`.
    public static let shared = Purchases()

    // MARK: State

    var api: BillingBearAPI?
    var _appUserId: String = ""
    private var isAnonymousUser: Bool = true
    let defaults: UserDefaults

    static let anonymousIdKey = "com.billingbear.anonymousAppUserId"
    static let customerInfoCacheKey = "com.billingbear.customerInfoCache"

    // MARK: Purchase core state (used by the Purchases+*.swift extensions)

    /// The store layer. `StoreKit2Client.shared` in apps; a mock in tests.
    var store: (any StoreKitClient)?
    var options = PurchasesOptions()
    /// Bumped by every configure: work started under an older configuration never writes state.
    var configurationEpoch = 0
    /// Bumped by every identity change (login, logout, reconfigure as someone else).
    var identityEpoch = 0
    /// Bumped by every authoritative customer-info write; a read that started before it is discarded.
    var customerInfoGeneration = 0
    /// What the current subscriber is shown: the last server answer, or a provisional offline value
    /// laid over it.
    var cachedCustomerInfo: CustomerInfo?
    /// The last answer the SERVER gave for the current subscriber (never a provisional value), and when.
    /// Freshness, the offline window and every fallback are measured from this, so a provisional grant
    /// can never stand in for a server answer.
    var serverCustomerInfo: CustomerInfo?
    var serverCustomerInfoFetchedAt: Date?
    /// The customer-info read in flight, shared by concurrent callers of the same generation.
    var customerInfoRead: (generation: Int, task: Task<CustomerInfo, Error>)?
    /// Transaction revisions being validated right now (keyed by configuration + revision), so a second
    /// delivery of the same revision joins the first.
    var transactionTasks: [String: Task<TransactionSyncOutcome, Error>] = [:]
    /// Transaction revisions completed this configuration, oldest first, bounded. A revision is the
    /// transaction id plus its revocation/upgrade state: a refund of a processed purchase is new work.
    var processedTransactionIds: [String] = []
    var processedTransactionIdSet: Set<String> = []
    /// BillingBear's one-time record of a completed revision (bounded with `processedTransactionIds`),
    /// and whether it was sent as an explicit purchase.
    var processedOneTimeRecords: [String: ProcessedOneTimeRecord] = [:]
    /// A one-time purchase was recorded but the entitlement read after it failed: the cached customer
    /// info predates it, so the next read asks BillingBear whatever the TTL says.
    var customerInfoOutdated = false
    /// The latest work queued per transaction id (configuration-scoped), so revisions run in order.
    var transactionChains: [String: Task<Void, Never>] = [:]
    /// Transactions whose refund has been seen this configuration.
    var revokedTransactionIds: Set<String> = []
    var retryAttempts: [String: Int] = [:]
    var retryTasks: [String: Task<Void, Never>] = [:]
    /// The single `Transaction.updates` listener, and the store it listens to.
    var transactionListener: Task<Void, Never>?
    var transactionListenerStore: ObjectIdentifier?
    var purchaseForegroundObserver: NSObjectProtocol?
    /// Test seams.
    var now: @Sendable () -> Date = { Date() }
    var retrySleep: @Sendable (UInt64) async -> Void = { try? await Task.sleep(nanoseconds: $0) }
    /// Fans customer-info changes out to `customerInfoStream` and `delegate`.
    nonisolated let broadcaster = CustomerInfoBroadcaster()

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
        // Release the foreground observers if registered. (NotificationCenter holds the token,
        // not self; removing here avoids a dangling block after the actor is gone.)
        #if canImport(UIKit)
        if let observer = foregroundObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let observer = purchaseForegroundObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        #endif
        transactionListener?.cancel()
        retryTasks.values.forEach { $0.cancel() }
        broadcaster.finishAll()
    }

    // MARK: Configure

    /// Configure the SDK. If `appUserId` is nil, an anonymous id is read from (or created in)
    /// `UserDefaults`, mirroring the RN SDK's anonymous-first behaviour. `bundleId` is sent with
    /// confirm/restore so a multi-brand backend scopes the subscription to the right app.
    ///
    /// The SPEED LAYER is configured here too (additive — existing callers get the defaults): after
    /// configure the SDK prefetches `speed.prefetchIdentifiers` + offerings in the background and
    /// re-prefetches on every app-foreground, persisting them so `present` paints from cache instantly.
    ///
    /// The PURCHASE CORE starts here as well: the `Transaction.updates` listener (one per process, kept
    /// across reconfigures), the replay of unfinished transactions, a customer-info refresh when the
    /// cache is stale, and the foreground hook that repeats the replay. `options` tunes it.
    public func configure(
        apiKey: String,
        appUserId: String? = nil,
        baseURL: String = "https://api.billingbear.io",
        bundleId: String? = nil,
        speed: SpeedLayerConfig = .init(),
        country: String? = nil
    ) {
        configure(apiKey: apiKey, appUserId: appUserId, baseURL: baseURL, bundleId: bundleId, speed: speed, country: country, options: PurchasesOptions())
    }

    /// `configure(apiKey:…)` with explicit purchase-core options.
    public func configure(
        apiKey: String,
        appUserId: String? = nil,
        baseURL: String = "https://api.billingbear.io",
        bundleId: String? = nil,
        speed: SpeedLayerConfig = .init(),
        country: String? = nil,
        options: PurchasesOptions
    ) {
        let api = BillingBearAPI(apiKey: apiKey, baseURL: baseURL, bundleId: bundleId ?? Bundle.main.bundleIdentifier)
        // Namespace the on-device cache by the API key so two projects/keys can't collide.
        self.cache = PaywallCache(store: FilePaywallCacheStore(), project: apiKey)
        self.speed = speed
        self.prefetchCountry = country
        applyPurchaseConfiguration(api: api, appUserId: appUserId, options: options, store: StoreKit2Client.shared)
        startSpeedLayer()
        startTransactionObservation(refreshCustomerInfo: true)
    }

    /// Test/advanced seam: configure with an explicit API client (e.g. one backed by a mocked
    /// URLSession) and, optionally, an explicit cache (e.g. a temp-dir + fixed-clock store). The
    /// foreground observer is NOT registered here so headless tests stay deterministic; call
    /// `prefetch()` directly instead. StoreKit transactions are observed only with
    /// `observeTransactions: true` (do that in an app that configures through this seam).
    public func configure(
        api: BillingBearAPI,
        appUserId: String? = nil,
        cache: PaywallCache? = nil,
        speed: SpeedLayerConfig = .init()
    ) {
        configure(api: api, appUserId: appUserId, cache: cache, speed: speed, options: PurchasesOptions(), observeTransactions: false)
    }

    /// The seam above with purchase-core options; `observeTransactions: true` starts the StoreKit
    /// listener, the unfinished replay and the foreground hook, as `configure(apiKey:…)` does.
    public func configure(
        api: BillingBearAPI,
        appUserId: String? = nil,
        cache: PaywallCache? = nil,
        speed: SpeedLayerConfig = .init(),
        options: PurchasesOptions,
        observeTransactions: Bool = false
    ) {
        self.cache = cache
        self.speed = speed
        applyPurchaseConfiguration(api: api, appUserId: appUserId, options: options, store: StoreKit2Client.shared)
        if observeTransactions { startTransactionObservation(refreshCustomerInfo: true) }
    }

    /// Test seam: an explicit store layer and clock.
    func configure(
        api: BillingBearAPI,
        store: any StoreKitClient,
        appUserId: String? = nil,
        options: PurchasesOptions = .init(),
        now: @escaping @Sendable () -> Date = { Date() },
        retrySleep: @escaping @Sendable (UInt64) async -> Void = { _ in },
        observeTransactions: Bool = true
    ) {
        self.now = now
        self.retrySleep = retrySleep
        self.speed = SpeedLayerConfig(prefetchEnabled: false)
        applyPurchaseConfiguration(api: api, appUserId: appUserId, options: options, store: store)
        if observeTransactions { startTransactionObservation(refreshCustomerInfo: false) }
    }

    /// Shared by every configure: install the client, the identity and the options, invalidate work
    /// started under the previous configuration, and restore this subscriber's persisted customer info.
    private func applyPurchaseConfiguration(
        api: BillingBearAPI,
        appUserId: String?,
        options: PurchasesOptions,
        store: any StoreKitClient
    ) {
        let previousSubscriber = "\(apiNamespace ?? "-")|\(_appUserId)"
        // Only when given: a provider set on the client directly survives a configure without one.
        if let provider = options.endUserTokenProvider { api.endUserTokenProvider = provider }
        self.api = api
        self.options = options
        self.store = store
        configurationEpoch += 1
        applyIdentity(appUserId)
        let subscriberChanged = previousSubscriber != "\(apiNamespace ?? "-")|\(_appUserId)"
        // A new configuration may be another project: nothing validated under the old one counts, and
        // its pending retries belong to it.
        processedTransactionIds.removeAll()
        processedTransactionIdSet.removeAll()
        processedOneTimeRecords.removeAll()
        revokedTransactionIds.removeAll()
        retryTasks.values.forEach { $0.cancel() }
        retryTasks.removeAll()
        retryAttempts.removeAll()
        resetCustomerInfoForNewSubscriber(subscriberChanged: subscriberChanged)
    }

    /// The API client's identity, so a persisted customer info is only reused for the same project.
    var apiNamespace: String? { api?.cacheNamespace }

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

    func requireApi() throws -> BillingBearAPI {
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
        switchIdentity(to: resolved, anonymous: false)
        return try await customerInfo(fetchPolicy: .fetchCurrent)
    }

    /// Log out the identified user and revert to a fresh anonymous id (persisted to UserDefaults).
    @discardableResult
    public func logout() async throws -> CustomerInfo {
        let api = try requireApi()
        let newAnon = try await api.logout(appUserId: _appUserId)
        defaults.set(newAnon, forKey: Self.anonymousIdKey)
        switchIdentity(to: newAnon, anonymous: true)
        return try await customerInfo(fetchPolicy: .fetchCurrent)
    }

    /// A different subscriber from here on: nothing cached or in flight for the previous one applies.
    private func switchIdentity(to appUserId: String, anonymous: Bool) {
        self._appUserId = appUserId
        self.isAnonymousUser = anonymous
        // Retries belong to the previous subscriber's session.
        retryTasks.values.forEach { $0.cancel() }
        retryTasks.removeAll()
        retryAttempts.removeAll()
        resetCustomerInfoForNewSubscriber(subscriberChanged: true)
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
    /// When `present` is true, render it with `BillingBearPaywall(decision:)`: that view sells the
    /// decision's `offeringIdentifier` (an offering experiment's variant, else the placement's default
    /// offering) through `onPurchaseRequest(_:)`, and folds its `viewed` into the one the evaluation
    /// recorded (`presentationId`) instead of counting the presentation twice.
    public func register(_ placement: String) async throws -> CampaignDecision {
        let api = try requireApi()
        return try await api.evaluatePlacement(placement: placement, appUserId: _appUserId)
    }

    /// The offering to show for a placement — RevenueCat's `getCurrentOffering(forPlacement:)`, for
    /// hosts that draw their own purchase UI. Evaluates the placement: when the decision names an
    /// offering (the offering-experiment variant the customer is enrolled in, or the placement's
    /// default offering) that offering is returned. Otherwise — older servers, or a placement without
    /// an offering — the current offering when the decision presents, else nil (no rule matched: show
    /// your default UX). Like `register(_:)`, a presenting evaluation counts as a placement view.
    public func currentOffering(forPlacement placement: String) async throws -> RemoteOffering? {
        let decision = try await register(placement)
        let named = decision.offeringIdentifier.flatMap { $0.isEmpty ? nil : $0 }
        guard named != nil || decision.present else { return nil }
        let offerings = try await getOfferings()
        if let named, let offering = offerings.offerings.first(where: { $0.identifier == named }) {
            return offering
        }
        guard decision.present, let current = offerings.currentOfferingId else { return nil }
        return offerings.offerings.first { $0.identifier == current }
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

    /// Record a paywall lifecycle event (`viewed` / `dismissed` / `purchased`, or an exit offer's
    /// `exit_offer_*` on its source paywall). Fire-and-forget. `presentationId` names the placement
    /// presentation a `viewed` belongs to (see `BillingBearAPI.recordExposure`).
    public func recordExposure(
        identifier: String,
        outcome: PaywallExposureOutcome,
        experimentId: String? = nil,
        variant: String? = nil,
        presentationId: String? = nil
    ) async {
        guard let api else { return }
        await api.recordExposure(
            identifier: identifier,
            outcome: outcome,
            appUserId: _appUserId,
            experimentId: experimentId,
            variant: variant,
            presentationId: presentationId
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

    /// Purchase a StoreKit 2 `StoreKit.Product`, then send the verified transaction to BillingBear
    /// (`/subscription/confirm` for subscriptions, `/v1/subscribers/{id}/non-subscription` for one-time
    /// products), finish it, and return the refreshed customer info.
    ///
    /// Throws `PurchasesError(.userCancelled)` if the user cancels, `.paymentPending` for Ask to Buy /
    /// deferred purchases (they complete later through `Transaction.updates`: watch `customerInfoStream`
    /// or the delegate), and `.storeError` for unverified transactions. When validation fails the
    /// transaction stays unfinished and is retried in the background.
    @available(iOS 15.0, macOS 12.0, *)
    public func purchase(product: StoreKit.Product) async throws -> PurchaseResult {
        try await performPurchase(productId: product.id, product: product, options: StorePurchaseOptions())
    }

    /// Purchase by App Store product id (the SDK loads the `StoreKit.Product`).
    @_disfavoredOverload // `purchases.purchase` keeps meaning purchase(product:)
    public func purchase(productId: String) async throws -> PurchaseResult {
        try await performPurchase(productId: productId, product: nil, options: StorePurchaseOptions())
    }

    /// Purchase a product redeeming a signed promotional offer (see `getPromotionalOffer`).
    @available(iOS 15.0, macOS 12.0, *)
    @_disfavoredOverload // `purchases.purchase` keeps meaning purchase(product:)
    public func purchase(product: StoreKit.Product, promotionalOffer: PromotionalOffer) async throws -> PurchaseResult {
        try await purchaseRedeeming(productId: product.id, product: product, promotionalOffer: promotionalOffer)
    }

    /// Purchase a product redeeming a win-back offer from `eligibleWinBackOffers(forProduct:)` (iOS 18+).
    @available(iOS 18.0, macOS 15.0, *)
    @_disfavoredOverload // `purchases.purchase` keeps meaning purchase(product:)
    public func purchase(product: StoreKit.Product, winBackOffer: WinBackOffer) async throws -> PurchaseResult {
        var options = StorePurchaseOptions()
        options.winBackOfferId = winBackOffer.id
        return try await performPurchase(productId: product.id, product: product, options: options)
    }

    func purchaseRedeeming(productId: String, product: Any?, promotionalOffer: PromotionalOffer) async throws -> PurchaseResult {
        guard promotionalOffer.productId.isEmpty || promotionalOffer.productId == productId else {
            throw PurchasesError(
                "The promotional offer was signed for \(promotionalOffer.productId), not \(productId)",
                code: .storeError
            )
        }
        var options = StorePurchaseOptions()
        options.promotionalOffer = promotionalOffer
        return try await performPurchase(productId: productId, product: product, options: options)
    }

    /// Restore purchases — the customer's "Restore Purchases": send every verified StoreKit
    /// entitlement to BillingBear and return the refreshed customer info (see `restoreFromStore`).
    /// A purchase another subscriber holds follows the project's RestoreTransferPolicy.
    @available(iOS 15.0, macOS 12.0, *)
    @discardableResult
    public func restore() async throws -> CustomerInfo {
        try await restoreFromStore(claimOrphanOnly: false)
    }

    /// Re-send the device's store purchases to BillingBear without any restore UI (keeping the server
    /// in sync, e.g. in observer mode). Unlike `restore()` it is a silent sync (`claimOrphanOnly`): it
    /// adopts purchases parked on an anonymous id but never takes one from another subscriber.
    @discardableResult
    public func syncPurchases() async throws -> CustomerInfo {
        try await restoreFromStore(claimOrphanOnly: true)
    }
}
