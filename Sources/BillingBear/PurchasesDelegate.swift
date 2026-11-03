import Foundation

/// Receives customer-info changes and the outcome of transactions the SDK processed on its own
/// (renewals, Ask-to-Buy approvals, offer codes, refunds, purchases made on another device).
/// Mirrors RevenueCat's `PurchasesDelegate`. Every method is called on the main actor and has a
/// default empty implementation, so implement only what you need.
///
/// ```swift
/// Purchases.shared.delegate = self   // held weakly
/// ```
@MainActor
public protocol PurchasesDelegate: AnyObject {
    /// The customer info changed. Called with the last known value as soon as the delegate is set,
    /// then on every change, never with an older value after a newer one.
    func purchases(_ purchases: Purchases, receivedUpdated customerInfo: CustomerInfo)

    /// A transaction that completed outside `purchase(…)` was validated with BillingBear and finished:
    /// an Ask-to-Buy approval, a renewal, a redeemed offer code, a purchase from another device, or one
    /// left unfinished by an earlier launch.
    func purchases(_ purchases: Purchases, didSyncTransaction transaction: StoreTransaction, customerInfo: CustomerInfo)

    /// A transaction could not be validated with BillingBear. It stays unfinished, so StoreKit hands it
    /// back and the SDK retries (with backoff, on every foreground and at the next launch).
    func purchases(_ purchases: Purchases, didFailToSyncTransaction transaction: StoreTransaction, error: PurchasesError)
}

public extension PurchasesDelegate {
    func purchases(_ purchases: Purchases, receivedUpdated customerInfo: CustomerInfo) {}
    func purchases(_ purchases: Purchases, didSyncTransaction transaction: StoreTransaction, customerInfo: CustomerInfo) {}
    func purchases(_ purchases: Purchases, didFailToSyncTransaction transaction: StoreTransaction, error: PurchasesError) {}
}

/// Fans customer-info changes out to every `customerInfoStream` and to the delegate. Lock-protected so
/// the nonisolated `customerInfoStream` / `delegate` accessors work without awaiting the actor.
final class CustomerInfoBroadcaster: @unchecked Sendable {
    private let lock = NSLock()
    private var latest: CustomerInfo?
    private var version = 0
    private var deliveredToDelegate = 0
    private var continuations: [UUID: AsyncStream<CustomerInfo>.Continuation] = [:]
    private weak var delegateObject: AnyObject?
    private var session: OperationEpoch?

    /// The configuration + subscriber session callbacks may still be delivered for. Mirrored here so a
    /// main-actor delivery can check it synchronously, right before calling the delegate.
    func setSession(_ epoch: OperationEpoch) {
        lock.lock(); session = epoch; lock.unlock()
    }

    func isSession(_ epoch: OperationEpoch) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return session == epoch
    }

    var latestValue: CustomerInfo? {
        lock.lock(); defer { lock.unlock() }
        return latest
    }

    /// Record a new value and yield it to every stream. Returns false (and yields nothing) when it
    /// equals the last published value.
    @discardableResult
    func publish(_ info: CustomerInfo) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard latest != info else { return false }
        latest = info
        version += 1
        // Yielded under the lock so two publishes can never reach a stream out of order.
        for continuation in continuations.values { continuation.yield(info) }
        return true
    }

    /// Forget the last value without emitting (the subscriber changed: the old value belongs to
    /// someone else and must not be replayed to new streams).
    func reset() {
        lock.lock(); defer { lock.unlock() }
        latest = nil
    }

    func makeStream() -> AsyncStream<CustomerInfo> {
        AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let id = UUID()
            lock.lock()
            continuations[id] = continuation
            if let latest { continuation.yield(latest) }
            lock.unlock()
            continuation.onTermination = { [weak self] _ in self?.removeContinuation(id) }
        }
    }

    private func removeContinuation(_ id: UUID) {
        lock.lock(); defer { lock.unlock() }
        continuations[id] = nil
    }

    var delegate: AnyObject? {
        get {
            lock.lock(); defer { lock.unlock() }
            return delegateObject
        }
        set {
            lock.lock(); defer { lock.unlock() }
            delegateObject = newValue
            // A newly set delegate gets the last known value (RevenueCat behaviour).
            deliveredToDelegate = 0
        }
    }

    /// The value the delegate has not seen yet, if any, marked as delivered. Each call hands out only
    /// the newest value, so deliveries that run late never move the delegate backwards.
    func takeUndeliveredForDelegate() -> (AnyObject, CustomerInfo)? {
        lock.lock(); defer { lock.unlock() }
        guard let delegateObject, let latest, version > deliveredToDelegate else { return nil }
        deliveredToDelegate = version
        return (delegateObject, latest)
    }

    func finishAll() {
        lock.lock()
        let all = Array(continuations.values)
        continuations.removeAll()
        lock.unlock()
        all.forEach { $0.finish() }
    }
}
