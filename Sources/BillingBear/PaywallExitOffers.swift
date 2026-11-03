import Foundation

// MARK: - Exit offers: pure logic
//
// An exit offer is another paywall shown IN PLACE when the user closes a paywall without buying
// (RevenueCat "exit offers"). The view (BillingBearPaywall) owns presentation; everything that
// decides WHETHER to show it, WHAT telemetry it records and WHICH offering a purchase should use
// lives here, as plain values and functions, so it is unit-testable without SwiftUI.

/// One exposure the paywall records (`POST /v1/paywalls/by-identifier/{identifier}/exposures`).
public struct PaywallExposureEvent: Equatable, Sendable {
    /// The paywall the exposure belongs to.
    public let identifier: String
    /// `viewed` / `dismissed` / `purchased`, or for the SOURCE paywall of an exit offer
    /// `exit_offer_viewed` / `exit_offer_purchased` / `exit_offer_dismissed`.
    public let outcome: String
    public let experimentId: String?
    public let variant: String?
    /// The placement presentation a `viewed` belongs to (`CampaignDecision.presentationId`): the
    /// server folds the view into the row the placement evaluation recorded. Nil otherwise.
    public let presentationId: String?

    public init(
        identifier: String, outcome: String, experimentId: String? = nil, variant: String? = nil,
        presentationId: String? = nil
    ) {
        self.identifier = identifier
        self.outcome = outcome
        self.experimentId = experimentId
        self.variant = variant
        self.presentationId = presentationId
    }
}

/// A paywall shown because a placement decision presented it (`BillingBearPaywall(decision:)`):
/// which paywall the decision presented and the id of the `viewed` its evaluation recorded.
public struct PaywallPlacementPresentation: Equatable, Sendable {
    /// The paywall the decision presented; the presentation applies to that paywall only.
    public let paywallIdentifier: String
    /// `CampaignDecision.presentationId` (nil on servers that predate it).
    public let presentationId: String?

    public init(paywallIdentifier: String, presentationId: String?) {
        self.paywallIdentifier = paywallIdentifier
        self.presentationId = presentationId.flatMap { $0.isEmpty ? nil : $0 }
    }

    /// The presentation of `decision`, or nil when it presents nothing.
    public init?(decision: CampaignDecision) {
        guard decision.present, let identifier = decision.paywallIdentifier, !identifier.isEmpty else { return nil }
        self.init(paywallIdentifier: identifier, presentationId: decision.presentationId)
    }
}

/// Which `viewed` exposure the renderer records for the paywall it shows (React Native SDK's
/// `rendererRecordsView` + `recordViewed`).
public enum PaywallViewRecording {
    /// The `viewed` of the SOURCE paywall `identifier` (the exit paywall's is recorded by the exit
    /// flow). A paywall presented from a placement decision already had its view recorded by the
    /// server's evaluation, so the renderer records it only when the paywall is under an A/B test —
    /// its variant is carried only by the renderer's exposure — and then names the presentation, so
    /// the server folds it into the evaluation's row: one view per presentation. Paywalls shown
    /// directly (or for another paywall than the decision presented) record their view as always.
    public static func sourceViewEvent(
        identifier: String,
        experiment: PaywallExperimentAssignment?,
        presentation: PaywallPlacementPresentation?
    ) -> PaywallExposureEvent? {
        let outcome = PaywallExposureOutcome.viewed.rawValue
        guard let presentation, presentation.paywallIdentifier == identifier else {
            return PaywallExposureEvent(identifier: identifier, outcome: outcome, experimentId: experiment?.id, variant: experiment?.variant)
        }
        guard let experiment else { return nil }
        return PaywallExposureEvent(
            identifier: identifier, outcome: outcome, experimentId: experiment.id, variant: experiment.variant,
            presentationId: presentation.presentationId)
    }
}

/// What the paywall asks the host to buy. Handed to `BillingBearPaywall.onPurchaseRequest(_:)`;
/// hosts that only set `onPurchase` keep receiving the bare product.
public struct PaywallPurchaseRequest: Equatable, Sendable {
    /// The product the user committed to.
    public let product: PaywallProduct
    /// Look the product up in this offering first (the exit offer's offering, or the placement
    /// decision's offering passed with `purchaseOffering(_:)`); nil means the usual lookup.
    /// `PaywallPurchaseLookup.find` implements the full order.
    public let offeringIdentifier: String?
    /// Identifier of the paywall on screen (the exit paywall when `fromExitOffer`).
    public let paywallIdentifier: String?
    /// True when the purchase comes from an exit offer.
    public let fromExitOffer: Bool

    public init(product: PaywallProduct, offeringIdentifier: String?, paywallIdentifier: String?, fromExitOffer: Bool) {
        self.product = product
        self.offeringIdentifier = offeringIdentifier
        self.paywallIdentifier = paywallIdentifier
        self.fromExitOffer = fromExitOffer
    }
}

/// What happened to a purchase the paywall handed to the host (`onPurchaseRequest(_:)`). Only a
/// `completed` purchase is recorded as a conversion, disarms the exit offer of the source paywall,
/// or ends an exit-offer flow; a cancelled or failed one leaves the paywall as it was.
public enum PaywallPurchaseOutcome: Equatable, Sendable {
    case completed
    case cancelled
    case failed

    /// The outcome to report for a purchase `Purchases.purchase(…)` completed. A one-time purchase
    /// BillingBear recorded but that this customer did not get is `.failed`, so the paywall credits no
    /// conversion (and an exit offer stays closable): the store took it back
    /// (`NonSubscriptionPurchaseResult.revoked`), or it is a non-consumable that stays with another
    /// subscriber (`keptByOriginalOwner`) — whatever other access the customer already has. Anything
    /// else is `.completed`.
    public init(purchase result: PurchaseResult) {
        guard let record = result.nonSubscriptionRecord else { self = .completed; return }
        let keptElsewhere = !record.isConsumable && !record.entitlementGranted && record.keptByOriginalOwner
        self = record.revoked || keptElsewhere ? .failed : .completed
    }
}

/// The exit-offer flow of ONE presentation of a paywall, as a value: what a close does, what a
/// purchase or restore changes, and which exposures each step records. The SwiftUI view keeps one in
/// `@State` and performs what it returns, so the rules are unit-testable without a view.
///
/// - The exit offer is offered at most once, and never after the source paywall was bought from
///   (a confirmed purchase, or a hand-off to a legacy `onPurchase` host that cannot confirm) or
///   restored successfully.
/// - Once an exit offer was shown, the close that ends the flow is the only one that records
///   telemetry and dismisses: later closes are ignored (a sheet that has not unmounted yet, a double
///   tap). Before any exit offer, closes behave as they always did.
/// - A purchase from the exit offer is recorded only when the host confirms it.
public struct PaywallExitOfferFlow: Equatable, Sendable {
    public enum CloseAction: Equatable, Sendable {
        /// Nothing to do: the flow already ended.
        case ignore
        /// Record these exposures and dismiss (call the host's `onDismiss`).
        case dismiss([PaywallExposureEvent])
        /// Record these exposures and show `activeExitOffer` in place of the source.
        case showExitOffer([PaywallExposureEvent])
    }

    /// The exit offer was presented in this presentation.
    public private(set) var exitOfferPresented = false
    /// The exit offer is on screen now, in place of the source.
    public private(set) var showingExitOffer = false
    /// The source was bought from or restored: its exit offer no longer applies.
    public private(set) var sourceEngaged = false
    /// A purchase from the exit offer was confirmed.
    public private(set) var exitPurchased = false
    /// The exit-offer flow ended with a dismissal: further closes are ignored.
    public private(set) var ended = false
    /// The source as it was when the exit offer took its place (a background refresh cannot change
    /// which exit offer is on screen) and that exit offer.
    public private(set) var pinnedSource: PaywallResponse?
    public private(set) var activeExitOffer: PaywallExitOffer?
    /// A purchase handed to `onPurchaseRequest(_:)` is awaiting its outcome: the purchase latch.
    public private(set) var purchasePending = false
    /// The host confirmed a purchase (`.completed`) in this presentation, from either stage: no
    /// further purchase may start, even if the host keeps the view on screen (a consumable would be
    /// charged twice).
    public private(set) var purchaseCompleted = false
    /// A close (button, tree dismiss, a blocked or completed swipe) arrived while the purchase was
    /// pending; it is settled with the outcome (`settleHeldClose`).
    public private(set) var closeHeld = false
    /// The held close was a swipe that already removed the sheet: never dismiss the host again for it.
    public private(set) var heldCloseRemovedSheet = false

    /// What a held close turned into once the purchase outcome was known.
    public enum SettledClose: Equatable, Sendable {
        /// Nothing to do: no close was held, or the purchase completed (the sale wins).
        case none
        /// Run this close now; `dismissHost` is false when the sheet is already gone.
        case close(CloseAction, dismissHost: Bool)
    }

    public init() {}

    /// Takes the purchase latch for a purchase whose outcome the host reports. False — start
    /// nothing — while another one is pending, once a purchase was confirmed, or once the flow ended.
    public mutating func beginPurchase() -> Bool {
        guard !purchasePending, !purchaseCompleted, !ended else { return false }
        purchasePending = true
        return true
    }

    /// Whether a user close would show the exit offer now. `eligible` is
    /// `PaywallExitOfferLogic.shouldPresent` plus the view's own conditions (exit offers on, a host
    /// close handler).
    public func isArmed(eligible: Bool) -> Bool {
        eligible && !ended && !sourceEngaged && !exitOfferPresented && !showingExitOffer
    }

    /// A user close. `source` is the paywall response on screen (nil before one loaded or for a bare
    /// document; `fallbackIdentifier` then names the dismissed paywall, if any).
    public mutating func close(
        source: PaywallResponse?, fallbackIdentifier: String?, eligible: Bool, sheetAlreadyGone: Bool = false
    ) -> CloseAction {
        if ended { return .ignore }
        if purchasePending {
            // Never end a presentation whose purchase may still succeed: held until the outcome.
            closeHeld = true
            heldCloseRemovedSheet = heldCloseRemovedSheet || sheetAlreadyGone
            return .ignore
        }
        if showingExitOffer, let pinned = pinnedSource, let exit = activeExitOffer {
            ended = true
            showingExitOffer = false
            // A confirmed exit purchase already told its story; closing afterwards only leaves.
            return .dismiss(exitPurchased ? [] : PaywallExitOfferLogic.exitCloseEvents(source: pinned, exitOffer: exit))
        }
        guard let source else {
            return .dismiss(fallbackIdentifier.map {
                [PaywallExposureEvent(identifier: $0, outcome: PaywallExposureOutcome.dismissed.rawValue)]
            } ?? [])
        }
        let presents = isArmed(eligible: eligible) && source.exitOffer != nil
        let events = PaywallExitOfferLogic.sourceCloseEvents(source: source, presentsExitOffer: presents)
        guard presents, let exit = source.exitOffer else { return .dismiss(events) }
        exitOfferPresented = true
        showingExitOffer = true
        pinnedSource = source
        activeExitOffer = exit
        return .showExitOffer(events)
    }

    /// A purchase handed to a host that cannot report its outcome (the legacy `onPurchase`). From the
    /// source it is recorded as `purchased` at the tap, as the SDK always did, and disarms the exit
    /// offer (the customer engaged). From the exit offer nothing purchase-related is recorded: without
    /// a confirmation a cancelled store sheet would count as a recovered sale.
    public mutating func purchaseHandedOff(
        fromExitOffer: Bool, source: PaywallResponse?, fallbackIdentifier: String?
    ) -> [PaywallExposureEvent] {
        if fromExitOffer && showingExitOffer { return [] }
        sourceEngaged = true
        return sourcePurchaseEvents(source: source, fallbackIdentifier: fallbackIdentifier)
    }

    /// The host reported the outcome of a purchase it was handed with `onPurchaseRequest(_:)`.
    public mutating func purchaseFinished(
        _ outcome: PaywallPurchaseOutcome, fromExitOffer: Bool, source: PaywallResponse?, fallbackIdentifier: String?
    ) -> [PaywallExposureEvent] {
        purchasePending = false
        guard outcome == .completed else { return [] }
        purchaseCompleted = true
        if fromExitOffer {
            guard showingExitOffer, !exitPurchased, let pinned = pinnedSource, let exit = activeExitOffer else { return [] }
            exitPurchased = true
            return PaywallExitOfferLogic.exitPurchaseEvents(source: pinned, exitOffer: exit)
        }
        sourceEngaged = true
        return sourcePurchaseEvents(source: source, fallbackIdentifier: fallbackIdentifier)
    }

    /// Settles a close that was held while the purchase was pending (call after `purchaseFinished`).
    /// A completed purchase wins: the held close is dropped (the host has the purchase and ends the
    /// presentation; nothing is recorded as dismissed) — or, when a swipe already removed the sheet,
    /// the flow simply ends. A cancelled or failed purchase runs the close now, as if just made; after
    /// a swipe it only records (the sheet is gone, so it cannot show an exit offer or dismiss again).
    public mutating func settleHeldClose(
        after outcome: PaywallPurchaseOutcome, source: PaywallResponse?, fallbackIdentifier: String?, eligible: Bool
    ) -> SettledClose {
        guard closeHeld else { return .none }
        let sheetGone = heldCloseRemovedSheet
        closeHeld = false
        heldCloseRemovedSheet = false
        if outcome == .completed {
            if sheetGone {
                ended = true
                showingExitOffer = false
            }
            return .none
        }
        let action = close(source: source, fallbackIdentifier: fallbackIdentifier, eligible: sheetGone ? false : eligible)
        return .close(action, dismissHost: !sheetGone)
    }

    /// A restore succeeded. On the source it disarms the exit offer: the customer already owns it.
    public mutating func restoreSucceeded() {
        if !showingExitOffer { sourceEngaged = true }
    }

    private func sourcePurchaseEvents(source: PaywallResponse?, fallbackIdentifier: String?) -> [PaywallExposureEvent] {
        guard let identifier = source?.identifier ?? fallbackIdentifier else { return [] }
        return [PaywallExposureEvent(
            identifier: identifier, outcome: PaywallExposureOutcome.purchased.rawValue,
            experimentId: source?.experiment?.id, variant: source?.experiment?.variant)]
    }
}

public enum PaywallExitOfferLogic {
    /// Exposure outcomes recorded on the SOURCE paywall of an exit offer (all <= 20 characters,
    /// the server's column limit).
    public static let viewedOutcome = PaywallExposureOutcome.exitOfferViewed.rawValue
    public static let purchasedOutcome = PaywallExposureOutcome.exitOfferPurchased.rawValue
    public static let dismissedOutcome = PaywallExposureOutcome.exitOfferDismissed.rawValue

    /// Whether a user close of the source paywall should show the exit offer instead of dismissing:
    /// an exit offer with a renderable paywall, not shown yet in this presentation, not refused by
    /// the server's cap (`eligible == false`), and within the device's own record of the cap.
    public static func shouldPresent(
        _ exitOffer: PaywallExitOffer?,
        alreadyPresented: Bool,
        presentationTimes: [Date],
        now: Date
    ) -> Bool {
        guard let exitOffer, !alreadyPresented, let paywall = exitOffer.paywall else { return false }
        guard paywall.document != nil || paywall.tree != nil else { return false }
        if exitOffer.eligible == false { return false }
        return withinLocalCap(exitOffer, presentationTimes: presentationTimes, now: now)
    }

    /// The frequency cap as this device has seen it: fewer than `maxPresentations` presentations in
    /// the last `perPeriodSeconds`. No cap unless both are set. A timestamp in the future (the clock
    /// moved back) still counts, so a clock change never re-opens a spent cap.
    public static func withinLocalCap(_ exitOffer: PaywallExitOffer, presentationTimes: [Date], now: Date) -> Bool {
        guard let max = exitOffer.maxPresentations,
              let period = exitOffer.perPeriodSeconds, period > 0 else { return true }
        if max <= 0 { return false }
        let since = now.addingTimeInterval(-TimeInterval(period))
        return presentationTimes.filter { $0 > since }.count < max
    }

    /// The user closed the source paywall. The source is dismissed in any case; when the exit offer
    /// takes its place, the source also records `exit_offer_viewed` (with its own experiment cell)
    /// and the exit paywall its `viewed` (no experiment: it is served as published).
    public static func sourceCloseEvents(source: PaywallResponse, presentsExitOffer: Bool) -> [PaywallExposureEvent] {
        var events = [event(source.identifier, "dismissed", source.experiment)]
        if presentsExitOffer, let exit = source.exitOffer {
            events.append(event(source.identifier, viewedOutcome, source.experiment))
            events.append(event(exitIdentifier(exit), "viewed", nil))
        }
        return events
    }

    /// The user bought from the exit offer.
    public static func exitPurchaseEvents(source: PaywallResponse, exitOffer: PaywallExitOffer) -> [PaywallExposureEvent] {
        [
            event(exitIdentifier(exitOffer), "purchased", nil),
            event(source.identifier, purchasedOutcome, source.experiment),
        ]
    }

    /// The user closed the exit offer: the flow ends.
    public static func exitCloseEvents(source: PaywallResponse, exitOffer: PaywallExitOffer) -> [PaywallExposureEvent] {
        [
            event(exitIdentifier(exitOffer), "dismissed", nil),
            event(source.identifier, dismissedOutcome, source.experiment),
        ]
    }

    /// The offering a purchase should be looked up in first: the exit offer's offering for an exit
    /// purchase (the placement's offering sells the source paywall's products, not the exit's),
    /// else the offering the host passed for the source paywall.
    public static func purchaseOffering(fromExitOffer exitOffer: PaywallExitOffer?, sourceOffering: String?) -> String? {
        if let exitOffer { return exitOffer.offeringIdentifier }
        return sourceOffering
    }

    private static func exitIdentifier(_ exitOffer: PaywallExitOffer) -> String {
        exitOffer.paywall?.identifier ?? exitOffer.paywallIdentifier
    }

    private static func event(_ identifier: String, _ outcome: String, _ experiment: PaywallExperimentAssignment?) -> PaywallExposureEvent {
        PaywallExposureEvent(identifier: identifier, outcome: outcome, experimentId: experiment?.id, variant: experiment?.variant)
    }
}

// MARK: - Device record of exit-offer presentations (the local half of the frequency cap)

/// When this device presented each paywall's exit offer. The server's `eligible` covers other
/// devices and earlier sessions as of the paywall fetch; this record covers presentations since a
/// (possibly cached) fetch, so a stale cached paywall cannot exceed the cap. UserDefaults-backed,
/// namespaced per source paywall identifier, pruned to the last year and 100 entries.
public final class PaywallExitOfferHistory: @unchecked Sendable {
    public static let shared = PaywallExitOfferHistory()

    static let keyPrefix = "io.billingbear.paywall.exitOffer.presentations."
    private static let maxEntries = 100
    private static let retention: TimeInterval = 366 * 24 * 3600

    private let defaults: UserDefaults
    private let lock = NSLock()

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Presentation times recorded for the exit offer of `sourceIdentifier`, oldest first.
    public func presentations(for sourceIdentifier: String) -> [Date] {
        lock.lock(); defer { lock.unlock() }
        return read(sourceIdentifier)
    }

    /// Record that the exit offer of `sourceIdentifier` was presented at `date`.
    public func recordPresentation(for sourceIdentifier: String, at date: Date = Date()) {
        lock.lock(); defer { lock.unlock() }
        var times = read(sourceIdentifier).filter { $0 > date.addingTimeInterval(-Self.retention) }
        times.append(date)
        if times.count > Self.maxEntries { times.removeFirst(times.count - Self.maxEntries) }
        defaults.set(times.map { $0.timeIntervalSince1970 }, forKey: Self.keyPrefix + sourceIdentifier)
    }

    /// Forget every recorded presentation of `sourceIdentifier` (tests, account switches).
    public func reset(_ sourceIdentifier: String) {
        lock.lock(); defer { lock.unlock() }
        defaults.removeObject(forKey: Self.keyPrefix + sourceIdentifier)
    }

    private func read(_ sourceIdentifier: String) -> [Date] {
        let raw = defaults.array(forKey: Self.keyPrefix + sourceIdentifier) ?? []
        return raw.compactMap { ($0 as? NSNumber)?.doubleValue }
            .map(Date.init(timeIntervalSince1970:))
            .sorted()
    }
}

// MARK: - Purchase lookup

/// Resolves the store product a paywall product refers to across the configured offerings, in the
/// order the exit-offer and placement contracts define: the preferred offering first, then the
/// current offering, then any other offering. Paywall product identifiers are store product ids.
public enum PaywallPurchaseLookup {
    public struct Match: Equatable, Sendable {
        public let offeringIdentifier: String
        public let packageIdentifier: String
        public let productId: String
    }

    public static func find(
        productId: String,
        in offerings: Offerings,
        preferring preferredOffering: String?,
        provider: String = "apple"
    ) -> Match? {
        var order: [RemoteOffering] = []
        func add(_ offering: RemoteOffering?) {
            guard let offering, !order.contains(where: { $0.identifier == offering.identifier }) else { return }
            order.append(offering)
        }
        if let preferredOffering { add(offerings.offerings.first { $0.identifier == preferredOffering }) }
        if let current = offerings.currentOfferingId { add(offerings.offerings.first { $0.identifier == current }) }
        offerings.offerings.forEach { add($0) }

        for offering in order {
            for package in offering.packages.sorted(by: { $0.displayOrder < $1.displayOrder }) {
                if let product = package.products.first(where: {
                    $0.productId == productId && $0.provider.caseInsensitiveCompare(provider) == .orderedSame
                }) {
                    return Match(offeringIdentifier: offering.identifier, packageIdentifier: package.identifier, productId: product.productId)
                }
            }
        }
        return nil
    }
}

// MARK: - Telemetry sink

/// Sends paywall exposures through the configured SDK, in order, fire-and-forget. An outcome
/// `PaywallExposureOutcome` cannot express is skipped rather than sent as something else.
enum PaywallExposureRecorder {
    @discardableResult
    static func record(_ events: [PaywallExposureEvent], through purchases: Purchases = .shared) -> Task<Void, Never>? {
        guard !events.isEmpty else { return nil }
        return Task {
            for event in events {
                guard let outcome = PaywallExposureOutcome(rawValue: event.outcome) else { continue }
                await purchases.recordExposure(
                    identifier: event.identifier,
                    outcome: outcome,
                    experimentId: event.experimentId,
                    variant: event.variant,
                    presentationId: event.presentationId
                )
            }
        }
    }
}

// MARK: - Tree helpers

extension PaywallTree {
    /// Whether any node (any page) closes the paywall, so a host-drawn close button would be a
    /// second, stray one. An exit-offer tree without one gets a close button: an exit offer must
    /// always be closable.
    var hasDismissAction: Bool {
        if root.containsDismissAction { return true }
        return (pages ?? []).contains { $0.root.containsDismissAction }
    }
}

extension PaywallNode {
    var containsDismissAction: Bool {
        if onTap == .dismiss { return true }
        return children.contains { $0.containsDismissAction }
    }
}
