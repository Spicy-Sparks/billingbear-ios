import Foundation

#if canImport(UIKit)
import UIKit
#endif

// MARK: - Transaction pipeline
//
// Every StoreKit transaction — from `purchase(…)`, `Transaction.updates`, the unfinished replay, a
// retry — goes through `process(_:source:)`:
//   1. a transaction already being validated is joined, not validated twice;
//   2. subscriptions are confirmed at /subscription/confirm, one-time products recorded at
//      /v1/subscribers/{id}/non-subscription (the backend asks Apple, never trusting the device);
//   3. only after the backend accepted it is the transaction finished (unless observer mode);
//   4. the refreshed customer info is committed and published to the stream / delegate.
// A failed validation leaves the transaction unfinished: StoreKit hands it back at the next launch,
// the SDK replays it on every foreground, and transient failures are retried with backoff
// (5 s, 30 s, 2 min, 10 min — the Flutter SDK's schedule). Same invariant as the RN and Flutter SDKs:
// never finish before the backend has the purchase.

/// A sync failure, and whether the retry schedule should try the transaction again.
struct TransactionSyncFailure: Error {
    let error: PurchasesError
    let retry: Bool
}

/// What validating one transaction produced: the refreshed customer info and, for a one-time
/// product, BillingBear's record of it and whether it was sent as an explicit purchase.
struct TransactionSyncOutcome: Sendable {
    let customerInfo: CustomerInfo
    var nonSubscriptionRecord: NonSubscriptionPurchaseResult? = nil
    var recordedExplicitly = false

    /// A silent sync found the purchase held by another subscriber: the customer's own purchase of it
    /// may still move it (the project's transfer policy), so it is recorded again, explicitly.
    var needsExplicitRecord: Bool {
        guard let record = nonSubscriptionRecord, !recordedExplicitly else { return false }
        return record.keptByOriginalOwner && !record.isConsumable && !record.revoked
    }
}

/// A completed revision's one-time record (see `Purchases.processedOneTimeRecords`).
struct ProcessedOneTimeRecord: Sendable {
    let record: NonSubscriptionPurchaseResult
    let explicit: Bool
}

enum TransactionSource: Sendable, Equatable {
    case purchase
    case updates
    case unfinished
    case retry

    /// True for transactions that completed outside `purchase(…)` (the delegate hears about them).
    var isBackground: Bool { self != .purchase }

    /// The non-subscription record's `claimOrphanOnly`: only the purchase the customer just made may
    /// move a purchase another subscriber holds (the project's transfer policy decides); everything
    /// nobody asked for — Transaction.updates, the unfinished replay, a background retry — is a
    /// silent sync, which only adopts purchases parked on an anonymous id.
    var claimsOrphanOnly: Bool { self != .purchase }
}

extension Purchases {

    static let retryDelays: [TimeInterval] = [5, 30, 120, 600]
    static let maxProcessedTransactionIds = 500

    func requireStore() throws -> any StoreKitClient {
        guard let store else {
            throw PurchasesError("Purchases not configured. Call configure(apiKey:) first.", code: .notConfigured)
        }
        return store
    }

    // MARK: Observation

    /// Start the single `Transaction.updates` listener (kept across reconfigures with the same store),
    /// replay unfinished transactions, hook the foreground, and optionally refresh a stale cache.
    func startTransactionObservation(refreshCustomerInfo: Bool) {
        guard let store else { return }
        let storeId = ObjectIdentifier(store)
        if transactionListener == nil || transactionListenerStore != storeId {
            transactionListener?.cancel()
            transactionListenerStore = storeId
            let updates = store.transactionUpdates()
            transactionListener = Task { [weak self] in
                for await result in updates {
                    guard let self else { return }
                    // Each transaction is handled on its own, so one slow validation never holds up the
                    // ones behind it (renewals and an Ask-to-Buy approval can arrive together).
                    Task { await self.handleStoreResult(result, source: .updates) }
                }
            }
        }
        registerPurchaseForegroundObserver()
        Task { await self.replayUnfinishedTransactions() }
        if refreshCustomerInfo {
            Task { _ = try? await self.customerInfo(fetchPolicy: .notStaleCachedOrFetched) }
        }
    }

    private func registerPurchaseForegroundObserver() {
        #if canImport(UIKit)
        guard purchaseForegroundObserver == nil else { return }
        purchaseForegroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            guard let self else { return }
            Task { await self.handleForeground() }
        }
        #endif
    }

    /// Back in the foreground: replay what is still unfinished and refresh a stale customer info
    /// (renewals and refunds the server learned about while the app was away).
    func handleForeground() async {
        guard api != nil else { return }
        await replayUnfinishedTransactions()
        _ = try? await customerInfo(fetchPolicy: .notStaleCachedOrFetched)
    }

    /// Validate every transaction StoreKit still holds unfinished (the app was killed between payment
    /// and validation, a validation failed, an Ask-to-Buy approval arrived while closed). Starts a new
    /// backoff cycle for each.
    func replayUnfinishedTransactions() async {
        guard let store, api != nil else { return }
        retryAttempts.removeAll()
        for result in await store.unfinishedTransactions() {
            await handleStoreResult(result, source: .unfinished)
        }
    }

    func handleStoreResult(_ result: StoreTransactionResult, source: TransactionSource) async {
        switch result {
        case .verified(let transaction):
            _ = try? await process(transaction, source: source)
        case .unverified(let transaction, let reason):
            // Never granted, never finished: StoreKit could not prove it came from the App Store.
            notifySyncFailure(
                transaction,
                error: PurchasesError("StoreKit could not verify transaction \(transaction.transactionId): \(reason)", code: .storeError),
                epoch: currentEpoch
            )
        }
    }

    // MARK: Processing

    /// The transaction id plus the state that changes what has to be done with it: a refund or an
    /// upgrade of an already-validated purchase arrives with the same id and is new work.
    static func revisionKey(_ transaction: StoreTransaction) -> String {
        let revoked = transaction.revocationDate.map { String(Int64($0.timeIntervalSince1970 * 1000)) } ?? "-"
        return "\(transaction.transactionId)|r\(revoked)|u\(transaction.isUpgraded ? 1 : 0)"
    }

    /// Validate, finish and publish one transaction revision (see the file header). Concurrent
    /// deliveries of the same revision in the same configuration and subscriber session share one
    /// validation. Everything that changes one subscription on the server — every revision and every
    /// renewal of one original transaction, and restore — runs one after the other, never at once.
    @discardableResult
    func process(_ transaction: StoreTransaction, source: TransactionSource) async throws -> CustomerInfo {
        try await process(transaction, source: source, context: try currentContext())
    }

    /// `processOutcome` answering only the customer info.
    @discardableResult
    func process(_ transaction: StoreTransaction, source: TransactionSource, context: OperationContext) async throws -> CustomerInfo {
        try await processOutcome(transaction, source: source, context: context).customerInfo
    }

    /// The configuration, client and subscriber an operation runs for, fixed when it starts.
    struct OperationContext: Sendable {
        let epoch: OperationEpoch
        let api: BillingBearAPI
        let appUserId: String
    }

    func currentContext() throws -> OperationContext {
        OperationContext(epoch: currentEpoch, api: try requireApi(), appUserId: _appUserId)
    }

    /// `process` for an operation that started earlier (a purchase whose sheet was open): it is
    /// validated for the subscriber it was started for.
    func processOutcome(_ transaction: StoreTransaction, source: TransactionSource, context: OperationContext) async throws -> TransactionSyncOutcome {
        let epoch = context.epoch
        // Scoped to the subscriber session: after a login the same transaction is validated for the new
        // subscriber (the server's transfer policy decides), never answered from the old one's work.
        let revision = "\(epoch.identity)|\(Self.revisionKey(transaction))"
        // Scoped to the configuration: work started for another project is never joined.
        let taskKey = "\(epoch.configuration)#\(revision)"
        // The customer's own purchase of a one-time product is explicit: work a silent sync did for the
        // same revision answers it only when that work did not leave the purchase with someone else.
        let explicitPurchase = source == .purchase && transaction.productType.isOneTime
            && transaction.revocationDate == nil && !transaction.isUpgraded
        if let running = transactionTasks[taskKey] {
            let joined: TransactionSyncOutcome
            do {
                joined = try await running.value
            } catch let failure as TransactionSyncFailure {
                throw failure.error
            }
            if !(explicitPurchase && joined.needsExplicitRecord) { return joined }
        } else if processedTransactionIdSet.contains(revision) {
            let processed = processedOneTimeRecords[revision]
            let earlier = TransactionSyncOutcome(
                customerInfo: .empty(appUserId: context.appUserId),
                nonSubscriptionRecord: processed?.record,
                recordedExplicitly: processed?.explicit ?? false)
            if !(explicitPurchase && earlier.needsExplicitRecord) {
                // Already completed this configuration (e.g. updates delivered it before purchase()
                // returned). Finishing is idempotent; answer with the current state.
                if !isSuperseded(transaction) { await finishIfAllowed(transaction) }
                let info = (isCurrent(epoch) ? ownCachedCustomerInfo(_appUserId) : nil)
                    ?? ownCachedCustomerInfo(context.appUserId) ?? .empty(appUserId: context.appUserId)
                return TransactionSyncOutcome(
                    customerInfo: info, nonSubscriptionRecord: processed?.record,
                    recordedExplicitly: processed?.explicit ?? false)
            }
        }
        if transaction.revocationDate != nil {
            // From here on an earlier, unrevoked revision of this transaction must neither grant nor
            // finish anything: the refund decides.
            revokedTransactionIds.insert(transaction.transactionId)
        }

        // The client and subscriber this operation runs for, fixed by the context: work queued behind
        // another never picks up a newer configuration's client or subscriber.
        let api = context.api
        let appUserId = context.appUserId
        let chainKey = Self.subscriptionChainKey(transaction, configuration: epoch.configuration)
        let (task, link) = enqueueSerialized(key: chainKey) {
            try await self.sync(transaction, source: source, revision: revision, epoch: epoch, api: api, appUserId: appUserId)
        }
        transactionTasks[taskKey] = task
        defer { releaseSerialized(key: chainKey, link: link) }
        // Only this operation's own task is cleared: an explicit re-record may have taken the key since.
        func clearTask() { if transactionTasks[taskKey] == task { transactionTasks[taskKey] = nil } }
        do {
            let outcome = try await task.value
            clearTask()
            return outcome
        } catch let failure as TransactionSyncFailure {
            // Cleared before the retry is scheduled, so the retry starts a new validation instead of
            // joining this failed one.
            clearTask()
            // Retried only for the session it belongs to: never re-sent for another subscriber.
            if failure.retry, isCurrent(epoch) { scheduleRetry(transaction, epoch: epoch) }
            throw failure.error
        } catch {
            clearTask()
            throw error
        }
    }

    /// An unrevoked revision of a transaction whose refund has been seen: the refund supersedes it.
    private func isSuperseded(_ transaction: StoreTransaction) -> Bool {
        transaction.revocationDate == nil && revokedTransactionIds.contains(transaction.transactionId)
    }

    /// One serial lane per subscription (original transaction id) and configuration.
    static func subscriptionChainKey(_ transaction: StoreTransaction, configuration: Int) -> String {
        "\(configuration)#\(transaction.originalTransactionId)"
    }

    /// Run `body` after every operation queued under `key` so far. Release the returned link when done.
    func enqueueSerialized<T: Sendable>(
        key: String,
        _ body: @escaping @Sendable () async throws -> T
    ) -> (task: Task<T, Error>, link: Task<Void, Never>) {
        let previous = transactionChains[key]
        let task = Task { () async throws -> T in
            await previous?.value
            return try await body()
        }
        let link = Task { _ = try? await task.value }
        transactionChains[key] = link
        return (task, link)
    }

    func releaseSerialized(key: String, link: Task<Void, Never>) {
        if transactionChains[key] == link { transactionChains[key] = nil }
    }

    private func sync(
        _ transaction: StoreTransaction,
        source: TransactionSource,
        revision: String,
        epoch: OperationEpoch,
        api: BillingBearAPI,
        appUserId: String
    ) async throws -> TransactionSyncOutcome {
        // Queued behind other work: if the SDK was reconfigured meanwhile, this belongs to the old
        // project and must not reach the server (the new configuration replays the transaction itself).
        guard epoch.configuration == configurationEpoch else {
            throw TransactionSyncFailure(
                error: PurchasesError("The SDK was reconfigured before this transaction was validated", code: .notConfigured),
                retry: false
            )
        }
        let generation = customerInfoGeneration

        do {
            let info: CustomerInfo
            var record: NonSubscriptionPurchaseResult?
            var explicit = false
            if isSuperseded(transaction) {
                // Its refund arrived while it waited: recording or confirming this older revision could
                // grant what was refunded. The revoked revision does the work.
                return TransactionSyncOutcome(customerInfo: ownCachedCustomerInfo(appUserId) ?? .empty(appUserId: appUserId))
            } else if transaction.isUpgraded {
                // An upgraded-away subscription. Apple also marks it revoked (as of the upgrade), and its
                // replacement — a separate transaction — carries the entitlement: confirming this one would
                // expire the subscription. It is finished once BillingBear answers.
                info = try await readServerAnswer(appUserId: appUserId, epoch: epoch, generation: generation, api: api)
            } else if transaction.revocationDate != nil && transaction.productType.isOneTime {
                (info, record) = try await reconcileRefundedOneTimePurchase(
                    transaction, appUserId: appUserId, epoch: epoch, generation: generation, api: api)
            } else if transaction.productType.isOneTime {
                let recorded = try await api.recordNonSubscriptionPurchase(
                    appUserId: appUserId,
                    transactionId: transaction.transactionId,
                    productId: transaction.productId,
                    providerData: providerData(for: transaction, appUserId: appUserId),
                    claimOrphanOnly: source.claimsOrphanOnly
                )
                record = recorded
                explicit = !source.claimsOrphanOnly
                // Any 200 settles the transaction, whatever its flags say: it is finished below even when
                // the read that follows fails. The entitlements are read back — after a grant, a transfer,
                // and also after a `revoked` answer (a grant this purchase gave may just have gone).
                info = await readAfterRecord(appUserId: appUserId, epoch: epoch, generation: generation, api: api)
            } else {
                switch try await confirmTarget(for: transaction, lookUpLatest: source != .purchase) {
                case .superseded:
                    info = try await readServerAnswer(appUserId: appUserId, epoch: epoch, generation: generation, api: api)
                case .confirm(let target):
                    // Including a revoked subscription: confirming makes the backend re-read it from
                    // Apple, which is how a refund reaches a project without App Store Server
                    // Notifications. Any failure leaves it unfinished for a later replay.
                    let answer = try await api.validatePurchase(
                        appUserId: appUserId,
                        request: validateRequest(for: target, appUserId: appUserId)
                    )
                    info = await commitServerAnswer(answer, epoch: epoch, generation: generation)
                }
            }
            await complete(transaction, revision: revision, epoch: epoch, source: source, customerInfo: info)
            if let record, epoch.configuration == configurationEpoch {
                processedOneTimeRecords[revision] = ProcessedOneTimeRecord(record: record, explicit: explicit)
            }
            return TransactionSyncOutcome(customerInfo: info, nonSubscriptionRecord: record, recordedExplicitly: explicit)
        } catch let failure as TransactionSyncFailure {
            if isCurrent(epoch) { notifySyncFailure(transaction, error: failure.error, epoch: epoch) }
            throw failure
        } catch let error as PurchasesError {
            if isCurrent(epoch) { notifySyncFailure(transaction, error: error, epoch: epoch) }
            throw TransactionSyncFailure(error: error, retry: Self.isTransient(error))
        }
    }

    enum ConfirmTarget {
        case confirm(StoreTransaction)
        /// A renewal of a subscription that has since moved to another product: nothing to confirm.
        case superseded
    }

    /// Which transaction a subscription confirm should name. The backend overwrites the subscription
    /// with the period of the transaction it is given, so confirming an OLDER renewal (several renewals
    /// replayed at launch, in any order) would roll a paid subscription back to an expired period.
    /// The confirm therefore names the subscription's latest transaction — across products, as a
    /// crossgrade or downgrade changes the product — read inside the subscription's serial lane right
    /// before the request. A snapshot of this very transaction that has since been upgraded away (a
    /// retry holds the old snapshot) is superseded.
    func confirmTarget(for transaction: StoreTransaction, lookUpLatest: Bool) async throws -> ConfirmTarget {
        guard lookUpLatest, transaction.productType == .autoRenewable, let store else { return .confirm(transaction) }
        let current: StoreTransaction?
        do {
            current = try await store.latestTransaction(ofSubscription: transaction)
        } catch {
            // Without the subscription's current transaction a confirm could name an expired period:
            // leave it unfinished and try again later.
            let reason = (error as? PurchasesError)?.message ?? error.localizedDescription
            throw TransactionSyncFailure(
                error: PurchasesError("Could not read the subscription's current state from StoreKit: \(reason)", code: .storeError),
                retry: true
            )
        }
        guard let latest = current,
              latest.originalTransactionId == transaction.originalTransactionId
        else { return .confirm(transaction) }
        if latest.transactionId == transaction.transactionId {
            return latest.isUpgraded ? .superseded : .confirm(latest)
        }
        guard latest.purchaseDate > transaction.purchaseDate else { return .confirm(transaction) }
        return latest.isUpgraded ? .superseded : .confirm(latest)
    }

    /// Read the server and commit its answer; throws (so the transaction stays unfinished) when
    /// BillingBear cannot be reached.
    private func readServerAnswer(appUserId: String, epoch: OperationEpoch, generation: Int, api: BillingBearAPI) async throws -> CustomerInfo {
        let answer = try await api.fetchEntitlements(appUserId: appUserId)
        return await commitServerAnswer(answer, epoch: epoch, generation: generation)
    }

    /// The entitlements after a one-time record BillingBear accepted. The record settled the
    /// transaction, so a failed read does not fail the sync: it answers with the cached state, marked
    /// outdated so the next read asks BillingBear.
    private func readAfterRecord(appUserId: String, epoch: OperationEpoch, generation: Int, api: BillingBearAPI) async -> CustomerInfo {
        do {
            return try await readServerAnswer(appUserId: appUserId, epoch: epoch, generation: generation, api: api)
        } catch {
            markCustomerInfoOutdated(epoch: epoch)
            return ownCachedCustomerInfo(appUserId) ?? .empty(appUserId: appUserId)
        }
    }

    /// A refunded consumable / non-consumable (or a Family Sharing withdrawal). The SDK never records a
    /// purchase BillingBear does not have yet — a server that predates revocation-aware records would
    /// grant it — so it reads the server first:
    /// - BillingBear never recorded it for this subscriber, or its record carries the refund: done.
    /// - Recorded and not yet taken back: the SDK posts it again (`claimOrphanOnly`). A re-post never
    ///   grants a recorded purchase; the server asks Apple and takes it back, answering `revoked: true`
    ///   (finished, entitlements read again). A server that predates that answers without `revoked`:
    ///   then the transaction waits for the App Store refund notification as before — unfinished and
    ///   checked again with the retry schedule, on foreground and at launch — except for a Family
    ///   Sharing withdrawal, which never gets a refund date and is done once BillingBear answered.
    private func reconcileRefundedOneTimePurchase(
        _ transaction: StoreTransaction,
        appUserId: String,
        epoch: OperationEpoch,
        generation: Int,
        api: BillingBearAPI
    ) async throws -> (CustomerInfo, NonSubscriptionPurchaseResult?) {
        let answer = try await api.fetchEntitlements(appUserId: appUserId)
        let info = await commitServerAnswer(answer, epoch: epoch, generation: generation)
        guard let known = answer.nonSubscriptionTransactions.first(where: { $0.transactionId == transaction.transactionId }),
              known.refundedAt == nil else { return (info, nil) }

        let beforeRecord = customerInfoGeneration
        var record: NonSubscriptionPurchaseResult?
        do {
            record = try await api.recordNonSubscriptionPurchase(
                appUserId: appUserId,
                transactionId: transaction.transactionId,
                productId: transaction.productId,
                providerData: providerData(for: transaction, appUserId: appUserId),
                claimOrphanOnly: true
            )
        } catch let error as PurchasesError where !Self.isTransient(error) {
            // Refused, or an answer this SDK cannot read: decided as before, from the server's record.
            // A transient failure propagates and the retry schedule tries again.
            record = nil
        }
        if let record, record.revoked {
            let refreshed = await readAfterRecord(appUserId: appUserId, epoch: epoch, generation: beforeRecord, api: api)
            return (refreshed, record)
        }
        if !transaction.isFamilyShared {
            throw TransactionSyncFailure(
                error: PurchasesError(
                    "BillingBear has not processed the refund of \(transaction.productId) yet; checking again later",
                    code: .validationError
                ),
                retry: true
            )
        }
        return (info, record)
    }

    /// The side effects of a completed sync: only under the configuration it ran for, whose store and
    /// finish policy it used (a reconfigure in between re-validates the transaction under the new one).
    private func complete(
        _ transaction: StoreTransaction,
        revision: String,
        epoch: OperationEpoch,
        source: TransactionSource,
        customerInfo: CustomerInfo
    ) async {
        guard epoch.configuration == configurationEpoch else { return }
        markProcessed(revision)
        retryAttempts[Self.revisionKey(transaction)] = nil
        // A refund seen while this older revision was validated decides when the transaction is done.
        if !isSuperseded(transaction) { await finishIfAllowed(transaction) }
        // The delegate hears about it only while it concerns the current subscriber.
        if source.isBackground, isCurrent(epoch) { notifySynced(transaction, customerInfo: customerInfo, epoch: epoch) }
    }

    func validateRequest(for transaction: StoreTransaction, appUserId: String) -> ValidateRequest {
        ValidateRequest(
            appUserId: appUserId,
            providerType: ProviderType.apple,
            transactionId: transaction.transactionId,
            originalTransactionId: transaction.originalTransactionId,
            productId: transaction.productId,
            receipt: transaction.jwsRepresentation,
            providerData: providerData(for: transaction, appUserId: appUserId)
        )
    }

    /// Audit signal only (the server's restore-transfer policy decides ownership): the token the
    /// purchase carried, or the one derived for the subscriber validating it.
    private func providerData(for transaction: StoreTransaction, appUserId: String) -> [String: String] {
        let token = transaction.appAccountToken ?? AppAccountToken.token(for: appUserId)
        return ["appAccountToken": token.uuidString.lowercased()]
    }

    func finishIfAllowed(_ transaction: StoreTransaction) async {
        guard options.finishTransactions, let store else { return }
        await store.finish(transaction)
    }

    private func markProcessed(_ id: String) {
        guard processedTransactionIdSet.insert(id).inserted else { return }
        processedTransactionIds.append(id)
        if processedTransactionIds.count > Self.maxProcessedTransactionIds {
            let evicted = processedTransactionIds.removeFirst()
            processedTransactionIdSet.remove(evicted)
            processedOneTimeRecords[evicted] = nil
        }
    }

    // MARK: Retry

    private func scheduleRetry(_ transaction: StoreTransaction, epoch: OperationEpoch) {
        let revision = Self.revisionKey(transaction)
        guard retryTasks[revision] == nil else { return }
        let attempt = retryAttempts[revision, default: 0]
        // Out of attempts: the foreground replay and the next launch pick it up again.
        guard attempt < Self.retryDelays.count else { return }
        retryAttempts[revision] = attempt + 1
        let delay = UInt64(Self.retryDelays[attempt] * 1_000_000_000)
        let sleep = retrySleep
        retryTasks[revision] = Task { [weak self] in
            await sleep(delay)
            guard !Task.isCancelled, let self else { return }
            await self.runRetry(transaction, revision: revision, epoch: epoch)
        }
    }

    private func runRetry(_ transaction: StoreTransaction, revision: String, epoch: OperationEpoch) async {
        // A reconfigure or an identity change cancels retries; one already past its sleep must not run
        // for another project or another subscriber (sending it would hand the purchase to them).
        guard isCurrent(epoch) else { return }
        retryTasks[revision] = nil
        _ = try? await process(transaction, source: .retry)
    }

    static func isTransient(_ error: PurchasesError) -> Bool {
        error.code == .networkError || error.statusCode == 429 || error.statusCode >= 500
    }

    /// A 4xx other than 429: the backend rejected the request itself.
    static func isClientError(_ error: PurchasesError) -> Bool {
        (400..<500).contains(error.statusCode) && error.statusCode != 429
    }

    // MARK: Delegate notifications

    /// Delivered on the main actor only while `epoch` is still the session: a callback about the
    /// previous subscriber or project never reaches the delegate after a switch.
    private func notifySynced(_ transaction: StoreTransaction, customerInfo: CustomerInfo, epoch: OperationEpoch) {
        let broadcaster = self.broadcaster
        Task { @MainActor in
            guard broadcaster.isSession(epoch) else { return }
            (broadcaster.delegate as? any PurchasesDelegate)?
                .purchases(self, didSyncTransaction: transaction, customerInfo: customerInfo)
        }
    }

    private func notifySyncFailure(_ transaction: StoreTransaction, error: PurchasesError, epoch: OperationEpoch) {
        let broadcaster = self.broadcaster
        Task { @MainActor in
            guard broadcaster.isSession(epoch) else { return }
            (broadcaster.delegate as? any PurchasesDelegate)?
                .purchases(self, didFailToSyncTransaction: transaction, error: error)
        }
    }

    // MARK: Purchase

    func performPurchase(productId: String, product: Any?, options purchaseOptions: StorePurchaseOptions) async throws -> PurchaseResult {
        let store = try requireStore()
        // Fixed before the sheet opens: the purchase is validated for whom it was started.
        let context = try currentContext()
        var storeOptions = purchaseOptions
        // The purchase carries the subscriber's deterministic token (RN parity); a promotional offer's
        // signature was made for exactly this token.
        storeOptions.appAccountToken = AppAccountToken.token(for: context.appUserId)

        let outcome: StorePurchaseOutcome
        do {
            outcome = try await store.purchase(productId: productId, product: product, options: storeOptions)
        } catch let error as PurchasesError {
            throw error
        } catch {
            throw PurchasesError(error.localizedDescription, code: .storeError)
        }

        switch outcome {
        case .success(.verified(let transaction)):
            guard context.epoch.configuration == configurationEpoch else {
                // Reconfigured while the sheet was open: the old project's client must not be used and
                // the new one must not silently adopt it. It stays unfinished; the new configuration
                // validates it now through its replay.
                Task { await self.replayUnfinishedTransactions() }
                throw PurchasesError(
                    "The SDK was reconfigured while the purchase sheet was open; the purchase is validated by the new configuration",
                    code: .notConfigured
                )
            }
            let synced = try await processOutcome(transaction, source: .purchase, context: context)
            // A refund of this transaction was seen while (or before) it was validated: the refund
            // decides, so the purchase is not reported as a success the customer does not have.
            if transaction.revocationDate == nil, revokedTransactionIds.contains(transaction.transactionId) {
                throw PurchasesError(
                    "The App Store took purchase \(transaction.transactionId) back (refunded or revoked)",
                    code: .storeError
                )
            }
            return PurchaseResult(
                customerInfo: synced.customerInfo,
                productId: transaction.productId,
                transactionId: transaction.transactionId,
                transaction: transaction,
                nonSubscriptionRecord: synced.nonSubscriptionRecord
            )
        case .success(.unverified(let transaction, let reason)):
            throw PurchasesError(
                "Transaction \(transaction.transactionId) failed StoreKit verification: \(reason)",
                code: .storeError
            )
        case .userCancelled:
            throw PurchasesError("User cancelled the purchase", code: .userCancelled)
        case .pending:
            // Ask to Buy / SCA: the approved transaction arrives through Transaction.updates, gets
            // validated and finished there, and the change reaches customerInfoStream / the delegate.
            throw PurchasesError("Purchase is pending approval", code: .paymentPending)
        }
    }

    // MARK: Restore

    enum RestoreOutcome: Sendable {
        case recordedOneTime
        case restored(CustomerInfo)
        /// Renewal of a subscription that moved to another product: nothing to restore for it.
        case superseded
    }

    private func restoreOne(
        _ transaction: StoreTransaction,
        appUserId: String,
        api: BillingBearAPI,
        epoch: OperationEpoch,
        claimOrphanOnly: Bool
    ) async throws -> RestoreOutcome {
        guard epoch.configuration == configurationEpoch else {
            throw PurchasesError("The SDK was reconfigured during the restore", code: .notConfigured)
        }
        // Its refund arrived while the restore waited: recording the older snapshot would grant it.
        if revokedTransactionIds.contains(transaction.transactionId) { return .superseded }
        if transaction.productType.isOneTime {
            _ = try await api.recordNonSubscriptionPurchase(
                appUserId: appUserId,
                transactionId: transaction.transactionId,
                productId: transaction.productId,
                providerData: providerData(for: transaction, appUserId: appUserId),
                claimOrphanOnly: claimOrphanOnly
            )
            // Any 200 settles it, a `revoked` answer included: finished now (a no-op for a transaction
            // finished long ago), and the entitlements are read back once all are in.
            if epoch.configuration == configurationEpoch { await finishIfAllowed(transaction) }
            return .recordedOneTime
        }
        let target: ConfirmTarget
        do {
            target = try await confirmTarget(for: transaction, lookUpLatest: true)
        } catch let failure as TransactionSyncFailure {
            throw failure.error
        }
        switch target {
        case .superseded:
            return .superseded
        case .confirm(let target):
            var request = validateRequest(for: target, appUserId: appUserId)
            // Only sent for a silent sync: an omitted flag is the explicit restore it always was.
            if claimOrphanOnly { request.claimOrphanOnly = true }
            return .restored(try await api.restorePurchases(appUserId: appUserId, request: request))
        }
    }

    /// Send every verified, still-active StoreKit entitlement to BillingBear. Semantics of the RN
    /// SDK's `restore`: an authoritative 4xx skips that purchase; when every purchase failed for the
    /// network the answer is the offline grant; when every one failed otherwise the last error is
    /// thrown (never an empty "restored nothing" for a paying user).
    ///
    /// `claimOrphanOnly`: false for the customer's "Restore Purchases" (a purchase another subscriber
    /// holds follows the project's RestoreTransferPolicy), true for a silent `syncPurchases()` (only
    /// purchases parked on an anonymous id are adopted).
    func restoreFromStore(claimOrphanOnly: Bool) async throws -> CustomerInfo {
        let api = try requireApi()
        let store = try requireStore()
        let appUserId = _appUserId
        let epoch = currentEpoch
        let generation = customerInfoGeneration
        // StoreKit already limits current entitlements to what the customer holds (active, or in the
        // billing grace period): every one goes to the server, which decides. Consumables never do.
        let transactions = await store.currentEntitlements().filter {
            $0.revocationDate == nil && !$0.isUpgraded && $0.productType != .consumable
        }

        var lastInfo: CustomerInfo?
        var recordedOneTime = false
        var succeeded = 0
        var lastTransientError: PurchasesError?
        var sawServerError = false
        // Only purchases that could not reach BillingBear may count offline: one the server rejected
        // (4xx) must never come back as a provisional grant.
        var unreachable: [StoreTransaction] = []

        for transaction in transactions {
            do {
                // In the subscription's serial lane, like every other server mutation of it.
                let chainKey = Self.subscriptionChainKey(transaction, configuration: epoch.configuration)
                let (task, link) = enqueueSerialized(key: chainKey) {
                    try await self.restoreOne(
                        transaction, appUserId: appUserId, api: api, epoch: epoch, claimOrphanOnly: claimOrphanOnly)
                }
                defer { releaseSerialized(key: chainKey, link: link) }
                switch try await task.value {
                case .recordedOneTime:
                    recordedOneTime = true
                case .restored(let info):
                    lastInfo = info
                case .superseded:
                    continue
                }
                succeeded += 1
            } catch let error as PurchasesError {
                if Self.isClientError(error) { continue }
                lastTransientError = error
                if error.code == .networkError { unreachable.append(transaction) } else { sawServerError = true }
            }
        }

        if succeeded > 0 {
            let answer: CustomerInfo
            // A one-time record answers without entitlements: read them once all are in.
            if let lastInfo, !recordedOneTime {
                answer = lastInfo
            } else {
                do {
                    answer = try await api.fetchEntitlements(appUserId: appUserId)
                } catch {
                    // The records went through (and their transactions are finished): the cached state
                    // predates them, so the next read asks BillingBear whatever the TTL says.
                    markCustomerInfoOutdated(epoch: epoch)
                    throw error
                }
            }
            return await commitServerAnswer(answer, epoch: epoch, generation: generation)
        }

        if !unreachable.isEmpty && !sawServerError {
            let offline = OfflineEntitlements.compute(
                appUserId: appUserId,
                transactions: unreachable,
                entitlement: options.offlineEntitlement,
                now: now()
            )
            if let merged = OfflineEntitlements.merge(cache: serverAnswerWithinOfflineWindow(appUserId), offline: offline) {
                // Provisional: newer than reads in flight, memory only, never persisted.
                commitProvisional(merged, epoch: epoch)
                return merged
            }
        }

        if !transactions.isEmpty, let lastTransientError {
            throw lastTransientError
        }
        // Nothing on the device, or every purchase was an authoritative skip: the server may still
        // hold an entitlement from another path (web checkout, another platform, a grant). Read it
        // without the StoreKit offline grant, which would hand back the purchases just rejected.
        do {
            let answer = try await api.fetchEntitlements(appUserId: appUserId)
            return await commitServerAnswer(answer, epoch: epoch, generation: generation)
        } catch {
            if let cached = serverAnswerWithinOfflineWindow(appUserId) { return cached }
            throw error
        }
    }
}
