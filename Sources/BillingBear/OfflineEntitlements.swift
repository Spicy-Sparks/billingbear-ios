import Foundation

/// Offline entitlements, with the React Native SDK's semantics (`sdk/react-native/src/offlineEntitlements.ts`).
///
/// When the backend cannot be reached (a transport failure — never a server rejection), the SDK still
/// answers with what it can prove on the device:
///  - the last customer info the server returned for this subscriber, if it is younger than
///    `PurchasesOptions.offlineEntitlementsWindow` (24 h by default, like the RN disk cache);
///  - plus a provisional grant computed from StoreKit's verified current entitlements.
///
/// Invariants: never downgrades (the merge only ever adds to the cached grant), always flagged
/// `isOfflineComputed` when it added something, never persisted, and replaced by the next successful
/// fetch.
enum OfflineEntitlements {

    /// A provisional customer info from the device's verified, still-active auto-renewable
    /// subscriptions and non-consumables, or nil when none grants anything. Every such purchase grants
    /// `entitlement` (the RN resolver maps every product to the default "premium" entitlement).
    static func compute(
        appUserId: String,
        transactions: [StoreTransaction],
        entitlement: String?,
        now: Date
    ) -> CustomerInfo? {
        guard let entitlement, !entitlement.isEmpty else { return nil }
        var expiresAt: Date?
        var open = false
        var any = false
        // Only purchases whose lasting access StoreKit can prove on the device: auto-renewables carry
        // their expiry, non-consumables never expire. A non-renewing subscription has no on-device
        // expiry (the app computes it), so it would read as a lifetime grant — it waits for the server.
        let provable = transactions.filter { $0.productType == .autoRenewable || $0.productType == .nonConsumable }
        for transaction in provable where transaction.grantsAccess(at: now) {
            any = true
            // Keep the most generous expiry: an open-ended grant always wins, else the later date.
            if let expiry = transaction.accessExpirationDate {
                if !open { expiresAt = max(expiresAt ?? expiry, expiry) }
            } else {
                open = true
                expiresAt = nil
            }
        }
        guard any else { return nil }
        let expiry = open ? nil : expiresAt.map(ISO8601.string)
        return CustomerInfo(
            appUserId: appUserId,
            // The backend's rule: premium means holding the "premium" entitlement.
            isPremium: entitlement == premiumEntitlement,
            entitlements: [entitlement: EntitlementInfo(identifier: entitlement, isActive: true, expiresAt: expiry)],
            activeSubscription: nil,
            nonSubscriptionTransactions: [],
            latestExpirationDate: expiry,
            isOfflineComputed: true
        )
    }

    static let premiumEntitlement = "premium"

    /// Lay a provisional grant over the cached (server) one without ever downgrading: the cache wins
    /// every conflict and keeps its subscription details; the result is flagged offline only when the
    /// provisional grant added an entitlement the cache did not have.
    static func merge(cache: CustomerInfo?, offline: CustomerInfo?) -> CustomerInfo? {
        guard let offline else { return cache }
        guard let cache else { return offline }
        var entitlements = offline.entitlements
        var addedBeyondCache = false
        for (id, _) in offline.entitlements where cache.entitlements[id]?.isActive != true {
            addedBeyondCache = true
        }
        for (id, entitlement) in cache.entitlements {
            entitlements[id] = entitlement
        }
        let merged = cache.replacing(
            isPremium: cache.isPremium || offline.isPremium,
            entitlements: entitlements,
            isOfflineComputed: addedBeyondCache || cache.isOfflineComputed
        )
        guard addedBeyondCache else { return merged }
        return merged.replacing(latestExpirationDate: latestExpiration(cache: cache, offline: offline))
    }

    /// When the merged entitlements run out: open-ended (nil) as soon as either side holds something
    /// that never expires, else the later of the two dates.
    private static func latestExpiration(cache: CustomerInfo, offline: CustomerInfo) -> String? {
        let cacheHolds = cache.entitlements.values.contains(where: \.isActive)
        if cacheHolds && cache.latestExpirationDate == nil { return nil }
        guard let offlineExpiry = offline.latestExpirationDate else { return nil }
        guard cacheHolds, let cacheExpiry = cache.latestExpirationDate else { return offlineExpiry }
        guard let a = ISO8601.date(cacheExpiry), let b = ISO8601.date(offlineExpiry) else { return cacheExpiry }
        return a >= b ? cacheExpiry : offlineExpiry
    }
}

/// ISO 8601 timestamps as the backend writes them.
enum ISO8601 {
    static func string(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    /// Parses the backend's timestamps, with or without fractional seconds.
    static func date(_ string: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: string) { return date }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: string)
    }
}
