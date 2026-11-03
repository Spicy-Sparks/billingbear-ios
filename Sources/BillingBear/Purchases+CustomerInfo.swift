import Foundation

// MARK: - Customer info: cache, fetch policies, offline entitlements, publishing
//
// Same model as the React Native SDK (`Purchases.ts` getCustomerInfo / _fetchCustomerInfoDeduped /
// _commitCustomerInfo):
//  - one in-memory value for the current subscriber, persisted (server answers only) for the offline
//    window;
//  - concurrent network reads share one request;
//  - a read that started before an authoritative write (purchase, restore, identity change) is
//    discarded, so it can never downgrade a buyer seconds after paying;
//  - a transport failure falls back to the cache (within the window) plus a provisional grant from
//    StoreKit, a server rejection only to the cache — never to a fabricated grant.

extension Purchases {

    /// A live sequence of customer-info changes, starting with the last known value (RevenueCat's
    /// `customerInfoStream`). Equal consecutive values are not repeated.
    ///
    /// ```swift
    /// for await info in Purchases.shared.customerInfoStream { updatePaywall(info.isPremium) }
    /// ```
    public nonisolated var customerInfoStream: AsyncStream<CustomerInfo> {
        broadcaster.makeStream()
    }

    /// Receives customer-info changes and background transaction outcomes on the main actor. Held
    /// weakly; a new delegate is sent the last known customer info right away.
    public nonisolated var delegate: (any PurchasesDelegate)? {
        get { broadcaster.delegate as? any PurchasesDelegate }
        set {
            broadcaster.delegate = newValue
            deliverCustomerInfoToDelegate()
        }
    }

    /// The customer info for the current subscriber. `cachedOrFetched` (the default) answers from the
    /// cache while it is fresh (`PurchasesOptions.customerInfoCacheTTL`) and asks BillingBear otherwise.
    ///
    /// When BillingBear cannot be reached the SDK does not downgrade a paying user: it answers with the
    /// last server value (if younger than `offlineEntitlementsWindow`) merged with a provisional grant
    /// from StoreKit's verified purchases (`isOfflineComputed == true`). It throws only when it has
    /// nothing to answer with.
    // Disfavored so an unannotated reference `purchases.customerInfo` keeps meaning `customerInfo()`.
    @_disfavoredOverload
    public func customerInfo(fetchPolicy: CacheFetchPolicy) async throws -> CustomerInfo {
        _ = try requireApi()
        let own = ownCachedCustomerInfo(_appUserId)
        switch fetchPolicy {
        case .fromCacheOnly:
            return own ?? .empty(appUserId: _appUserId)
        case .cachedOrFetched, .notStaleCachedOrFetched:
            if let own, isCustomerInfoFresh() { return own }
            return try await fetchCustomerInfoDeduped()
        case .fetchCurrent:
            return try await fetchCustomerInfoDeduped()
        }
    }

    /// The customer info with the default policy, `cachedOrFetched`.
    public func customerInfo() async throws -> CustomerInfo {
        try await customerInfo(fetchPolicy: .cachedOrFetched)
    }

    /// Drop the freshness of the cached customer info so the next read asks BillingBear (the cache
    /// stays as the offline fallback), and fetch now.
    @discardableResult
    public func invalidateCustomerInfoCache() async throws -> CustomerInfo {
        try await customerInfo(fetchPolicy: .fetchCurrent)
    }

    // MARK: Internals

    func ownCachedCustomerInfo(_ appUserId: String) -> CustomerInfo? {
        guard let cached = cachedCustomerInfo, cached.appUserId == appUserId else { return nil }
        return cached
    }

    /// Fresh = a server answer younger than the TTL is what the subscriber sees. A provisional value is
    /// never fresh: the next read tries BillingBear again.
    func isCustomerInfoFresh() -> Bool {
        guard !customerInfoOutdated,
              let fetchedAt = serverCustomerInfoFetchedAt, cachedCustomerInfo?.isOfflineComputed != true else { return false }
        let age = now().timeIntervalSince(fetchedAt)
        return age >= 0 && age < options.customerInfoCacheTTL
    }

    /// The last server answer, only while it is younger than the offline window. Never a provisional
    /// value: a server error falls back to what the server said, not to what the device guessed.
    func serverAnswerWithinOfflineWindow(_ appUserId: String) -> CustomerInfo? {
        guard let answer = serverCustomerInfo, answer.appUserId == appUserId,
              let fetchedAt = serverCustomerInfoFetchedAt, isWithinOfflineWindow(fetchedAt) else { return nil }
        return answer
    }

    func isWithinOfflineWindow(_ fetchedAt: Date) -> Bool {
        let age = now().timeIntervalSince(fetchedAt)
        // A timestamp from the future (clock moved back) is trusted only within a small skew.
        return age >= -300 && age < options.offlineEntitlementsWindow
    }

    /// The customer-info network read, shared by every caller of the current generation. A caller that
    /// needs the state after the latest write (generation bumped) gets a new request.
    func fetchCustomerInfoDeduped() async throws -> CustomerInfo {
        let generation = customerInfoGeneration
        if let read = customerInfoRead, read.generation == generation {
            return try await read.task.value
        }
        let task = Task { try await self.performCustomerInfoRead(generation: generation) }
        customerInfoRead = (generation, task)
        defer {
            if customerInfoRead?.task == task { customerInfoRead = nil }
        }
        return try await task.value
    }

    private func performCustomerInfoRead(generation: Int) async throws -> CustomerInfo {
        let api = try requireApi()
        let appUserId = _appUserId
        func isStale() -> Bool { generation != customerInfoGeneration || appUserId != _appUserId }
        do {
            let fresh = try await api.fetchEntitlements(appUserId: appUserId)
            if isStale() { return try await customerInfoAfterStaleRead() }
            storeVerifiedCustomerInfo(fresh)
            return fresh
        } catch {
            // Offline grant ONLY for a transport failure. A server rejection (4xx/5xx) must never be
            // papered over with a fabricated grant; it still falls back to the last server answer.
            let isNetwork = (error as? PurchasesError)?.code == .networkError
            let offline = isNetwork ? await computeOfflineCustomerInfo(appUserId: appUserId) : nil
            if isStale() { return try await customerInfoAfterStaleRead() }
            if let merged = OfflineEntitlements.merge(
                cache: serverAnswerWithinOfflineWindow(appUserId),
                offline: offline
            ) {
                // Shown, never persisted, never taken for a server answer.
                cachedCustomerInfo = merged
                publishCustomerInfo(merged)
                return merged
            }
            throw error
        }
    }

    /// A read overtaken by a write answers with what the write left, or with a read of the newest
    /// generation when the write left nothing (an identity change clears the cache).
    private func customerInfoAfterStaleRead() async throws -> CustomerInfo {
        if let own = ownCachedCustomerInfo(_appUserId) { return own }
        return try await fetchCustomerInfoDeduped()
    }

    /// A provisional grant from StoreKit's verified current entitlements (nil when nothing qualifies,
    /// the offline grant is disabled, or the store layer is unavailable).
    func computeOfflineCustomerInfo(appUserId: String) async -> CustomerInfo? {
        guard let store, let entitlement = options.offlineEntitlement else { return nil }
        let transactions = await store.currentEntitlements()
        return OfflineEntitlements.compute(
            appUserId: appUserId,
            transactions: transactions,
            entitlement: entitlement,
            now: now()
        )
    }

    /// Apply the server answer an operation that changed the server (confirm, one-time record,
    /// restore, refund reconciliation) obtained. `generation` is `customerInfoGeneration` from before
    /// the operation sent its request. The answer becomes the newest state — newer than every read in
    /// flight — unless another write landed meanwhile: then it may predate that write, so it is not
    /// applied and the server is asked again. Ignored entirely when the subscriber or configuration
    /// changed since the operation started — it must not land on someone else. Returns the value the
    /// subscriber now has.
    func commitServerAnswer(_ info: CustomerInfo, epoch: OperationEpoch, generation: Int) async -> CustomerInfo {
        guard info.appUserId == _appUserId, isCurrent(epoch) else { return info }
        let noWriteSince = generation == customerInfoGeneration
        // Newer than every read in flight either way: those started before this write.
        customerInfoGeneration += 1
        if noWriteSince {
            storeVerifiedCustomerInfo(info)
            return info
        }
        if let fresh = try? await fetchCustomerInfoDeduped(), fresh.appUserId == info.appUserId { return fresh }
        return ownCachedCustomerInfo(info.appUserId) ?? info
    }

    /// Show a provisional value an operation produced (an offline restore) as the newest state: reads in
    /// flight are older and must not replace it. Never persisted, never taken for a server answer.
    func commitProvisional(_ info: CustomerInfo, epoch: OperationEpoch) {
        guard info.appUserId == _appUserId, isCurrent(epoch) else { return }
        customerInfoGeneration += 1
        cachedCustomerInfo = info
        publishCustomerInfo(info)
    }

    /// A write reached BillingBear but its answer could not be read: reads already in flight predate
    /// it, and the cache is no longer fresh, so the next read asks the server.
    func markCustomerInfoOutdated(epoch: OperationEpoch) {
        guard isCurrent(epoch) else { return }
        customerInfoGeneration += 1
        customerInfoOutdated = true
    }

    private func storeVerifiedCustomerInfo(_ info: CustomerInfo) {
        customerInfoOutdated = false
        let fetchedAt = now()
        cachedCustomerInfo = info
        serverCustomerInfo = info
        serverCustomerInfoFetchedAt = fetchedAt
        persistCustomerInfo(info, fetchedAt: fetchedAt)
        publishCustomerInfo(info)
    }

    func publishCustomerInfo(_ info: CustomerInfo) {
        guard info.appUserId == _appUserId else { return }
        if broadcaster.publish(info) { deliverCustomerInfoToDelegate() }
    }

    nonisolated func deliverCustomerInfoToDelegate() {
        let broadcaster = self.broadcaster
        Task { @MainActor in
            // Always the newest undelivered value: a late delivery never moves the delegate backwards.
            guard let (object, info) = broadcaster.takeUndeliveredForDelegate(),
                  let delegate = object as? any PurchasesDelegate else { return }
            delegate.purchases(self, receivedUpdated: info)
        }
    }

    /// Called whenever the subscriber or the configuration changes: forget the previous subscriber's
    /// value, invalidate reads in flight, and restore this subscriber's persisted value if it is still
    /// within the offline window. When the subscriber (or project) really changed and nothing of theirs
    /// is known yet, observers are told so with an empty value: they must not keep showing the previous
    /// subscriber's access while the first read is pending (or failing).
    func resetCustomerInfoForNewSubscriber(subscriberChanged: Bool) {
        identityEpoch += 1
        broadcaster.setSession(currentEpoch)
        customerInfoGeneration += 1
        cachedCustomerInfo = nil
        serverCustomerInfo = nil
        serverCustomerInfoFetchedAt = nil
        let observersHoldAValue = broadcaster.latestValue != nil
        broadcaster.reset()
        loadPersistedCustomerInfo()
        if subscriberChanged, observersHoldAValue, cachedCustomerInfo == nil {
            // Memory-only and not a server answer: the next read replaces it.
            publishCustomerInfo(.empty(appUserId: _appUserId))
        }
    }

    // MARK: Persistence

    private struct PersistedCustomerInfo: Codable {
        let namespace: String
        let appUserId: String
        let fetchedAt: Date
        let info: CustomerInfo
    }

    private func persistCustomerInfo(_ info: CustomerInfo, fetchedAt: Date) {
        guard let namespace = apiNamespace, info.appUserId == _appUserId else { return }
        let entry = PersistedCustomerInfo(namespace: namespace, appUserId: info.appUserId, fetchedAt: fetchedAt, info: info)
        guard let data = try? JSONEncoder().encode(entry) else { return }
        defaults.set(data, forKey: Self.customerInfoCacheKey)
    }

    private func loadPersistedCustomerInfo() {
        guard let namespace = apiNamespace,
              let data = defaults.data(forKey: Self.customerInfoCacheKey),
              let entry = try? JSONDecoder().decode(PersistedCustomerInfo.self, from: data),
              entry.namespace == namespace,
              entry.appUserId == _appUserId,
              entry.info.appUserId == _appUserId,
              isWithinOfflineWindow(entry.fetchedAt)
        else { return }
        cachedCustomerInfo = entry.info
        serverCustomerInfo = entry.info
        serverCustomerInfoFetchedAt = entry.fetchedAt
        publishCustomerInfo(entry.info)
    }
}

/// The configuration and session an operation started under.
struct OperationEpoch: Equatable {
    let configuration: Int
    let identity: Int
}

extension Purchases {
    var currentEpoch: OperationEpoch { OperationEpoch(configuration: configurationEpoch, identity: identityEpoch) }
    func isCurrent(_ epoch: OperationEpoch) -> Bool { epoch == currentEpoch }
}
