import XCTest
@testable import BillingBear

// MARK: - Exit offers (decoding, eligibility + local cap, telemetry sequence, purchase lookup)
//
// Everything here exercises the pure layer (PaywallModels decoding + PaywallExitOffers.swift); the
// SwiftUI view only sequences these calls.

final class PaywallExitOfferTests: XCTestCase {

    // MARK: Fixtures

    private static let v1Document = """
    {
      "version": 1,
      "layout": "minimal",
      "theme": { "primaryColor": "#5b5bd6", "background": "#0a0a0a", "textColor": "#ffffff" },
      "header": { "title": "Go Premium" },
      "features": [],
      "products": [{ "identifier": "com.app.yearly", "label": "Yearly", "highlight": true }],
      "cta": { "text": "Continue" },
      "footer": {}
    }
    """

    private static let v2Document = """
    {
      "version": 2,
      "theme": { "primaryColor": "#5b5bd6", "background": "#0a0a0a", "textColor": "#ffffff" },
      "products": [{ "identifier": "com.app.monthly", "label": "Monthly" }],
      "root": { "id": "root", "type": "stack", "children": [
        { "id": "cta", "type": "button", "text": "Buy", "onTap": { "type": "purchase" } }
      ] }
    }
    """

    private func responseJSON(exitOffer: String?, experiment: Bool = true) -> String {
        """
        {
          "identifier": "main",
          "versionId": "v3",
          "versionNumber": 3,
          "publishedAt": "2026-11-01T00:00:00Z",
          "document": \(Self.v1Document),
          "experiment": \(experiment ? #"{ "id": "exp-1", "name": "Price test", "variant": "B" }"# : "null")
          \(exitOffer.map { ", \"exitOffer\": \($0)" } ?? "")
        }
        """
    }

    private func exitOfferJSON(
        document: String = PaywallExitOfferTests.v1Document,
        eligible: String = "true",
        max: String = "1",
        period: String = "86400",
        offering: String = #""winback""#
    ) -> String {
        """
        {
          "type": "offering",
          "paywallIdentifier": "winback-paywall",
          "offeringIdentifier": \(offering),
          "maxPresentations": \(max),
          "perPeriodSeconds": \(period),
          "eligible": \(eligible),
          "paywall": {
            "identifier": "winback-paywall",
            "versionId": "v9",
            "versionNumber": 9,
            "publishedAt": "2026-10-01T00:00:00Z",
            "document": \(document)
          }
        }
        """
    }

    private func decode(_ json: String) throws -> PaywallResponse {
        try JSONDecoder().decode(PaywallResponse.self, from: Data(json.utf8))
    }

    private func exitOffer(
        eligible: Bool? = true,
        max: Int? = nil,
        period: Int? = nil,
        offering: String? = "winback",
        withPaywall: Bool = true
    ) throws -> PaywallExitOffer {
        let document = try JSONDecoder().decode(PaywallDocument.self, from: Data(Self.v1Document.utf8))
        return PaywallExitOffer(
            type: "offering",
            paywallIdentifier: "winback-paywall",
            offeringIdentifier: offering,
            maxPresentations: max,
            perPeriodSeconds: period,
            eligible: eligible,
            paywall: withPaywall
                ? PaywallExitOfferPaywall(identifier: "winback-paywall", versionId: "v9", versionNumber: 9, publishedAt: "", document: document)
                : nil)
    }

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    // MARK: Decoding

    func testDecodesAV1ExitOfferWithItsPaywall() throws {
        let response = try decode(responseJSON(exitOffer: exitOfferJSON()))
        let offer = try XCTUnwrap(response.exitOffer)
        XCTAssertEqual(offer.type, "offering")
        XCTAssertEqual(offer.paywallIdentifier, "winback-paywall")
        XCTAssertEqual(offer.offeringIdentifier, "winback")
        XCTAssertEqual(offer.maxPresentations, 1)
        XCTAssertEqual(offer.perPeriodSeconds, 86400)
        XCTAssertEqual(offer.eligible, true)
        XCTAssertEqual(offer.paywall?.versionNumber, 9)
        XCTAssertEqual(offer.paywall?.document?.products.first?.identifier, "com.app.yearly")
        XCTAssertNil(offer.paywall?.tree)
        XCTAssertEqual(offer.paywall?.asResponse?.identifier, "winback-paywall")
        XCTAssertNil(offer.paywall?.asResponse?.experiment, "the exit paywall is served without an experiment")
    }

    func testDecodesAV2TreeExitPaywall() throws {
        let response = try decode(responseJSON(exitOffer: exitOfferJSON(document: Self.v2Document)))
        let paywall = try XCTUnwrap(response.exitOffer?.paywall)
        XCTAssertNil(paywall.document)
        XCTAssertEqual(paywall.tree?.products.first?.identifier, "com.app.monthly")
        XCTAssertNil(paywall.asResponse, "a tree has no preset response")
    }

    func testAResponseWithoutAnExitOfferDecodesAsBefore() throws {
        let response = try decode(responseJSON(exitOffer: nil))
        XCTAssertNil(response.exitOffer)
        XCTAssertEqual(response.experiment?.variant, "B")
        let nulled = try decode(responseJSON(exitOffer: "null"))
        XCTAssertNil(nulled.exitOffer)
    }

    func testAnUnreadableExitOfferNeverBreaksThePaywall() throws {
        // No paywall identifier at all: the exit offer is dropped, the paywall still renders.
        let response = try decode(responseJSON(exitOffer: #"{ "type": "paywall", "eligible": true }"#))
        XCTAssertNil(response.exitOffer)
        XCTAssertEqual(response.document.products.count, 1)

        // A garbage exit document: the exit offer stays, without a paywall to show.
        let broken = try decode(responseJSON(exitOffer: exitOfferJSON(document: #"{ "version": 1, "layout": 42 }"#)))
        XCTAssertNotNil(broken.exitOffer)
        XCTAssertNil(broken.exitOffer?.paywall)
        XCTAssertFalse(PaywallExitOfferLogic.shouldPresent(broken.exitOffer, alreadyPresented: false, presentationTimes: [], now: now))

        // A string where a number belongs: tolerated as "no cap".
        let loose = try decode(responseJSON(exitOffer: exitOfferJSON(max: #""one""#, offering: "null")))
        XCTAssertNil(loose.exitOffer?.maxPresentations)
        XCTAssertNil(loose.exitOffer?.offeringIdentifier)
    }

    func testAnOfferingsPayloadCarriesTheExitOfferThrough() throws {
        let json = """
        { "currentOfferingId": "default", "offerings": [ { "identifier": "default", "displayName": "Default",
          "description": null, "isCurrent": true, "packages": [], "paywall": \(responseJSON(exitOffer: exitOfferJSON())) } ] }
        """
        let offerings = try JSONDecoder().decode(Offerings.self, from: Data(json.utf8))
        XCTAssertEqual(offerings.offerings.first?.paywall?.exitOffer?.paywallIdentifier, "winback-paywall")
    }

    func testTheExitOfferSurvivesTheCacheRoundTrip() throws {
        for document in [Self.v1Document, Self.v2Document] {
            let response = try decode(responseJSON(exitOffer: exitOfferJSON(document: document)))
            let again = try JSONDecoder().decode(PaywallResponse.self, from: JSONEncoder().encode(response))
            XCTAssertEqual(again, response)
        }
    }

    func testThePlacementDecisionCarriesTheOfferingAndTheExperimentCell() throws {
        let json = """
        { "present": true, "paywallId": "p1", "paywallIdentifier": "annual-discount", "campaignId": null,
          "ruleReason": "matched", "offeringIdentifier": "annual_discount", "experimentId": "e1",
          "experimentName": "Annual price", "variant": "treatment" }
        """
        let decision = try JSONDecoder().decode(CampaignDecision.self, from: Data(json.utf8))
        XCTAssertEqual(decision.offeringIdentifier, "annual_discount")
        XCTAssertEqual(decision.variant, "treatment")

        let old = #"{ "present": false, "paywallId": null, "paywallIdentifier": null, "campaignId": null, "ruleReason": "no_campaign" }"#
        let legacy = try JSONDecoder().decode(CampaignDecision.self, from: Data(old.utf8))
        XCTAssertNil(legacy.offeringIdentifier)
        XCTAssertNil(legacy.experimentId)
    }

    // MARK: Eligibility + cap

    func testNothingToShowWithoutARenderableExitOffer() throws {
        XCTAssertFalse(PaywallExitOfferLogic.shouldPresent(nil, alreadyPresented: false, presentationTimes: [], now: now))
        XCTAssertFalse(PaywallExitOfferLogic.shouldPresent(try exitOffer(withPaywall: false), alreadyPresented: false, presentationTimes: [], now: now))
    }

    func testShownOncePerPresentation() throws {
        let offer = try exitOffer()
        XCTAssertTrue(PaywallExitOfferLogic.shouldPresent(offer, alreadyPresented: false, presentationTimes: [], now: now))
        XCTAssertFalse(PaywallExitOfferLogic.shouldPresent(offer, alreadyPresented: true, presentationTimes: [], now: now))
    }

    func testTheServerCapWins() throws {
        XCTAssertFalse(PaywallExitOfferLogic.shouldPresent(try exitOffer(eligible: false), alreadyPresented: false, presentationTimes: [], now: now))
        XCTAssertTrue(PaywallExitOfferLogic.shouldPresent(try exitOffer(eligible: nil), alreadyPresented: false, presentationTimes: [], now: now),
                      "an older payload without `eligible` is eligible")
    }

    func testTheLocalCapCountsPresentationsInsideTheWindow() throws {
        let daily = try exitOffer(max: 1, period: 86_400)
        let hourAgo = now.addingTimeInterval(-3_600)
        let twoDaysAgo = now.addingTimeInterval(-2 * 86_400)
        XCTAssertFalse(PaywallExitOfferLogic.shouldPresent(daily, alreadyPresented: false, presentationTimes: [hourAgo], now: now))
        XCTAssertTrue(PaywallExitOfferLogic.shouldPresent(daily, alreadyPresented: false, presentationTimes: [twoDaysAgo], now: now))

        let twice = try exitOffer(max: 2, period: 86_400)
        XCTAssertTrue(PaywallExitOfferLogic.shouldPresent(twice, alreadyPresented: false, presentationTimes: [hourAgo], now: now))
        XCTAssertFalse(PaywallExitOfferLogic.shouldPresent(twice, alreadyPresented: false, presentationTimes: [hourAgo, now.addingTimeInterval(-60)], now: now))
    }

    func testAFutureTimestampStillCountsAndAHalfCapIsNoCap() throws {
        let daily = try exitOffer(max: 1, period: 86_400)
        XCTAssertFalse(PaywallExitOfferLogic.withinLocalCap(daily, presentationTimes: [now.addingTimeInterval(3_600)], now: now))
        XCTAssertTrue(PaywallExitOfferLogic.withinLocalCap(try exitOffer(max: 1, period: nil), presentationTimes: [now], now: now))
        XCTAssertTrue(PaywallExitOfferLogic.withinLocalCap(try exitOffer(max: nil, period: 60), presentationTimes: [now], now: now))
        XCTAssertFalse(PaywallExitOfferLogic.withinLocalCap(try exitOffer(max: 0, period: 60), presentationTimes: [], now: now))
    }

    // MARK: Telemetry sequence

    func testClosingTheSourceWithoutAnExitOfferRecordsOnlyItsDismissal() throws {
        let source = try decode(responseJSON(exitOffer: nil))
        XCTAssertEqual(PaywallExitOfferLogic.sourceCloseEvents(source: source, presentsExitOffer: false), [
            PaywallExposureEvent(identifier: "main", outcome: "dismissed", experimentId: "exp-1", variant: "B"),
        ])
    }

    func testTheFullExitOfferSequence() throws {
        let source = try decode(responseJSON(exitOffer: exitOfferJSON()))
        let offer = try XCTUnwrap(source.exitOffer)

        XCTAssertEqual(PaywallExitOfferLogic.sourceCloseEvents(source: source, presentsExitOffer: true), [
            PaywallExposureEvent(identifier: "main", outcome: "dismissed", experimentId: "exp-1", variant: "B"),
            PaywallExposureEvent(identifier: "main", outcome: "exit_offer_viewed", experimentId: "exp-1", variant: "B"),
            PaywallExposureEvent(identifier: "winback-paywall", outcome: "viewed"),
        ])
        XCTAssertEqual(PaywallExitOfferLogic.exitPurchaseEvents(source: source, exitOffer: offer), [
            PaywallExposureEvent(identifier: "winback-paywall", outcome: "purchased"),
            PaywallExposureEvent(identifier: "main", outcome: "exit_offer_purchased", experimentId: "exp-1", variant: "B"),
        ])
        XCTAssertEqual(PaywallExitOfferLogic.exitCloseEvents(source: source, exitOffer: offer), [
            PaywallExposureEvent(identifier: "winback-paywall", outcome: "dismissed"),
            PaywallExposureEvent(identifier: "main", outcome: "exit_offer_dismissed", experimentId: "exp-1", variant: "B"),
        ])
    }

    func testExitOfferOutcomesFitTheServerColumn() {
        for outcome in [PaywallExitOfferLogic.viewedOutcome, PaywallExitOfferLogic.purchasedOutcome, PaywallExitOfferLogic.dismissedOutcome] {
            XCTAssertLessThanOrEqual(outcome.count, 20, outcome)
        }
    }

    func testAnExitPurchaseBuysFromTheExitOffering() throws {
        XCTAssertEqual(PaywallExitOfferLogic.purchaseOffering(fromExitOffer: try exitOffer(), sourceOffering: "annual"), "winback")
        // The placement offering sells the source paywall's products, never the exit's.
        XCTAssertNil(PaywallExitOfferLogic.purchaseOffering(fromExitOffer: try exitOffer(offering: nil), sourceOffering: "annual"))
        XCTAssertEqual(PaywallExitOfferLogic.purchaseOffering(fromExitOffer: nil, sourceOffering: "annual"), "annual")
    }

    // MARK: Purchase lookup

    private func offerings() -> Offerings {
        func pkg(_ id: String, _ products: [(String, String)], order: Int = 0) -> RemoteOfferingPackage {
            RemoteOfferingPackage(identifier: id, displayName: id, description: nil, displayOrder: order,
                                  products: products.map { RemoteOfferingProduct(provider: $0.0, productId: $0.1) })
        }
        return Offerings(currentOfferingId: "default", offerings: [
            RemoteOffering(identifier: "promo", displayName: "Promo", description: nil, isCurrent: false,
                           packages: [pkg("$rc_annual", [("google", "yearly"), ("apple", "promo.yearly")])], paywall: nil),
            RemoteOffering(identifier: "default", displayName: "Default", description: nil, isCurrent: true,
                           packages: [pkg("$rc_annual", [("apple", "yearly")])], paywall: nil),
            RemoteOffering(identifier: "winback", displayName: "Winback", description: nil, isCurrent: false,
                           packages: [pkg("$rc_annual", [("apple", "yearly")]), pkg("$rc_monthly", [("apple", "winback.monthly")], order: 1)], paywall: nil),
        ])
    }

    func testThePreferredOfferingIsSearchedFirstThenCurrentThenAny() {
        let all = offerings()
        XCTAssertEqual(PaywallPurchaseLookup.find(productId: "yearly", in: all, preferring: "winback")?.offeringIdentifier, "winback")
        XCTAssertEqual(PaywallPurchaseLookup.find(productId: "yearly", in: all, preferring: nil)?.offeringIdentifier, "default")
        XCTAssertEqual(PaywallPurchaseLookup.find(productId: "yearly", in: all, preferring: "missing")?.offeringIdentifier, "default")
        XCTAssertEqual(PaywallPurchaseLookup.find(productId: "winback.monthly", in: all, preferring: nil)?.packageIdentifier, "$rc_monthly")
        XCTAssertEqual(PaywallPurchaseLookup.find(productId: "promo.yearly", in: all, preferring: "winback")?.offeringIdentifier, "promo")
    }

    func testTheLookupMatchesTheStoreProvider() {
        let all = offerings()
        XCTAssertEqual(PaywallPurchaseLookup.find(productId: "yearly", in: all, preferring: "promo", provider: "google")?.offeringIdentifier, "promo")
        XCTAssertEqual(PaywallPurchaseLookup.find(productId: "yearly", in: all, preferring: "promo")?.offeringIdentifier, "default",
                       "promo sells `yearly` on Google only")
        XCTAssertNil(PaywallPurchaseLookup.find(productId: "unknown", in: all, preferring: "winback"))
    }

    // MARK: Presentation history

    private func makeHistory() -> (PaywallExitOfferHistory, UserDefaults, String) {
        let suite = "bb-exit-offer-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        return (PaywallExitOfferHistory(defaults: defaults), defaults, suite)
    }

    func testTheHistoryRemembersPresentationsPerSourcePaywall() {
        let (history, defaults, suite) = makeHistory()
        defer { defaults.removePersistentDomain(forName: suite) }
        history.recordPresentation(for: "main", at: now.addingTimeInterval(-10))
        history.recordPresentation(for: "main", at: now)
        history.recordPresentation(for: "other", at: now)
        XCTAssertEqual(history.presentations(for: "main"), [now.addingTimeInterval(-10), now])
        XCTAssertEqual(history.presentations(for: "other").count, 1)

        // A fresh instance on the same store reads the same record (it survives relaunches).
        XCTAssertEqual(PaywallExitOfferHistory(defaults: defaults).presentations(for: "main").count, 2)

        history.reset("main")
        XCTAssertTrue(history.presentations(for: "main").isEmpty)
        XCTAssertEqual(history.presentations(for: "other").count, 1)
    }

    func testTheHistoryStaysBounded() {
        let (history, defaults, suite) = makeHistory()
        defer { defaults.removePersistentDomain(forName: suite) }
        history.recordPresentation(for: "main", at: now.addingTimeInterval(-400 * 86_400))
        for i in 0..<120 { history.recordPresentation(for: "main", at: now.addingTimeInterval(TimeInterval(i))) }
        let times = history.presentations(for: "main")
        XCTAssertEqual(times.count, 100)
        XCTAssertEqual(times.first, now.addingTimeInterval(20), "the oldest entries go first, the year-old one with them")
    }

    // MARK: Tree chrome

    func testAnExitTreeWithoutADismissNodeNeedsACloseButton() throws {
        let withoutClose = try JSONDecoder().decode(PaywallTree.self, from: Data(Self.v2Document.utf8))
        XCTAssertFalse(withoutClose.hasDismissAction)
        let withClose = try JSONDecoder().decode(PaywallTree.self, from: Data(Self.v2Document.replacingOccurrences(
            of: #"{ "type": "purchase" }"#, with: #"{ "type": "dismiss" }"#).utf8))
        XCTAssertTrue(withClose.hasDismissAction)
    }

    // MARK: Flow (one presentation)

    private var sourceDismissed: PaywallExposureEvent {
        PaywallExposureEvent(identifier: "main", outcome: "dismissed", experimentId: "exp-1", variant: "B")
    }
    private var sourcePurchased: PaywallExposureEvent {
        PaywallExposureEvent(identifier: "main", outcome: "purchased", experimentId: "exp-1", variant: "B")
    }

    // MARK: Sheet swipe-down

    func testASwipeIsBlockedOnlyWhileItWouldSkipTheExitOfferAndOnlyWhenTheAttemptIsDelivered() {
        XCTAssertTrue(PaywallSheetDismissPolicy.blocksSwipe(armed: true, pending: false, intercepting: true))
        XCTAssertTrue(PaywallSheetDismissPolicy.blocksSwipe(armed: false, pending: true, intercepting: true))
        // Nothing to protect: the swipe dismisses as before.
        XCTAssertFalse(PaywallSheetDismissPolicy.blocksSwipe(armed: false, pending: false, intercepting: true))
        // The attempt cannot reach the paywall (not a sheet, delegate not joined): never trap the user.
        XCTAssertFalse(PaywallSheetDismissPolicy.blocksSwipe(armed: true, pending: true, intercepting: false))
    }

    func testABlockedSwipeRunsTheCloseFlowShowingTheOfferThenEndingIt() throws {
        // The interceptor routes each blocked swipe to the same close as the close button.
        let source = try decode(responseJSON(exitOffer: exitOfferJSON()))
        let offer = try XCTUnwrap(source.exitOffer)
        var flow = PaywallExitOfferFlow()

        let firstSwipe = flow.close(source: source, fallbackIdentifier: "main", eligible: true)
        XCTAssertEqual(firstSwipe, .showExitOffer(PaywallExitOfferLogic.sourceCloseEvents(source: source, presentsExitOffer: true)))
        XCTAssertTrue(flow.showingExitOffer && !flow.exitPurchased && !flow.ended) // still pending: keep blocking
        let secondSwipe = flow.close(source: source, fallbackIdentifier: "main", eligible: true)
        XCTAssertEqual(secondSwipe, .dismiss(PaywallExitOfferLogic.exitCloseEvents(source: source, exitOffer: offer)))
        XCTAssertTrue(flow.ended) // nothing left to protect: the sheet may go
    }

    func testASwipeThatDismissedIsRecordedAsTheCloseItWas() throws {
        // An allowed swipe (e.g. the offer is outside its cap) records the source's dismissal. UIKit
        // reports a completed interactive dismissal once (programmatic ones are never reported), so
        // this runs once per swipe.
        let source = try decode(responseJSON(exitOffer: exitOfferJSON()))
        var flow = PaywallExitOfferFlow()
        XCTAssertEqual(flow.close(source: source, fallbackIdentifier: "main", eligible: false), .dismiss([sourceDismissed]))

        // A swipe after the exit offer was closed by its button records nothing more.
        let offer = try XCTUnwrap(source.exitOffer)
        var shown = PaywallExitOfferFlow()
        _ = shown.close(source: source, fallbackIdentifier: "main", eligible: true)
        XCTAssertEqual(shown.close(source: source, fallbackIdentifier: "main", eligible: true),
                       .dismiss(PaywallExitOfferLogic.exitCloseEvents(source: source, exitOffer: offer)))
        XCTAssertEqual(shown.close(source: source, fallbackIdentifier: "main", eligible: false), .ignore)
    }

    func testClosingTwiceAfterTheExitOfferFiresTheDismissalOnce() throws {
        let source = try decode(responseJSON(exitOffer: exitOfferJSON()))
        let offer = try XCTUnwrap(source.exitOffer)
        var flow = PaywallExitOfferFlow()

        XCTAssertTrue(flow.isArmed(eligible: true))
        XCTAssertEqual(flow.close(source: source, fallbackIdentifier: "main", eligible: true),
                       .showExitOffer(PaywallExitOfferLogic.sourceCloseEvents(source: source, presentsExitOffer: true)))
        XCTAssertTrue(flow.showingExitOffer)
        XCTAssertFalse(flow.isArmed(eligible: true))
        XCTAssertEqual(flow.close(source: source, fallbackIdentifier: "main", eligible: true),
                       .dismiss(PaywallExitOfferLogic.exitCloseEvents(source: source, exitOffer: offer)))
        // A second dismiss/back before the host unmounted: nothing recorded, onDismiss not called again.
        XCTAssertEqual(flow.close(source: source, fallbackIdentifier: "main", eligible: true), .ignore)
        XCTAssertTrue(flow.ended)
    }

    func testWithoutAnExitOfferClosesBehaveAsBefore() throws {
        let source = try decode(responseJSON(exitOffer: nil))
        var flow = PaywallExitOfferFlow()
        // No exit offer was ever shown, so nothing is latched: every close dismisses, as it always did.
        XCTAssertEqual(flow.close(source: source, fallbackIdentifier: "main", eligible: true), .dismiss([sourceDismissed]))
        XCTAssertEqual(flow.close(source: source, fallbackIdentifier: "main", eligible: true), .dismiss([sourceDismissed]))
        XCTAssertEqual(flow.close(source: nil, fallbackIdentifier: "pending", eligible: false),
                       .dismiss([PaywallExposureEvent(identifier: "pending", outcome: "dismissed")]))
        XCTAssertEqual(flow.close(source: nil, fallbackIdentifier: nil, eligible: false), .dismiss([]))
    }

    func testAnIneligibleExitOfferDismisses() throws {
        let source = try decode(responseJSON(exitOffer: exitOfferJSON()))
        var flow = PaywallExitOfferFlow()
        XCTAssertEqual(flow.close(source: source, fallbackIdentifier: "main", eligible: false), .dismiss([sourceDismissed]))
        XCTAssertFalse(flow.exitOfferPresented)
    }

    func testAnExitPurchaseIsRecordedOnlyWhenTheHostConfirmsIt() throws {
        let source = try decode(responseJSON(exitOffer: exitOfferJSON()))
        let offer = try XCTUnwrap(source.exitOffer)
        var flow = PaywallExitOfferFlow()
        _ = flow.close(source: source, fallbackIdentifier: "main", eligible: true)

        // Cancelled / failed store sheets record nothing and keep the exit offer on screen.
        XCTAssertEqual(flow.purchaseFinished(.cancelled, fromExitOffer: true, source: source, fallbackIdentifier: "main"), [])
        XCTAssertEqual(flow.purchaseFinished(.failed, fromExitOffer: true, source: source, fallbackIdentifier: "main"), [])
        XCTAssertTrue(flow.showingExitOffer)
        XCTAssertFalse(flow.exitPurchased)

        XCTAssertEqual(flow.purchaseFinished(.completed, fromExitOffer: true, source: source, fallbackIdentifier: "main"),
                       PaywallExitOfferLogic.exitPurchaseEvents(source: source, exitOffer: offer))
        // Reported twice (a retried callback): recorded once.
        XCTAssertEqual(flow.purchaseFinished(.completed, fromExitOffer: true, source: source, fallbackIdentifier: "main"), [])
        // Closing after the confirmed purchase leaves without an exit_offer_dismissed, once.
        XCTAssertEqual(flow.close(source: source, fallbackIdentifier: "main", eligible: true), .dismiss([]))
        XCTAssertEqual(flow.close(source: source, fallbackIdentifier: "main", eligible: true), .ignore)
    }

    // MARK: Closes during a pending purchase (Codex round 4)

    func testAnExitCloseDuringAPendingPurchaseWaitsAndASaleWins() throws {
        let source = try decode(responseJSON(exitOffer: exitOfferJSON()))
        let offer = try XCTUnwrap(source.exitOffer)
        var flow = PaywallExitOfferFlow()
        _ = flow.close(source: source, fallbackIdentifier: "main", eligible: true)
        XCTAssertTrue(flow.beginPurchase())
        XCTAssertFalse(flow.beginPurchase(), "one reported purchase at a time")

        // The close (button or blocked swipe) is held: nothing recorded, the exit offer stays.
        XCTAssertEqual(flow.close(source: source, fallbackIdentifier: "main", eligible: true), .ignore)
        XCTAssertTrue(flow.closeHeld)
        XCTAssertTrue(flow.showingExitOffer)

        // Paid: credited against the pinned exit offer, and the held close is dropped.
        XCTAssertEqual(flow.purchaseFinished(.completed, fromExitOffer: true, source: source, fallbackIdentifier: "main"),
                       PaywallExitOfferLogic.exitPurchaseEvents(source: source, exitOffer: offer))
        XCTAssertEqual(flow.settleHeldClose(after: .completed, source: source, fallbackIdentifier: "main", eligible: true), .none)
        XCTAssertFalse(flow.closeHeld)
        // A later close leaves without a dismissal.
        XCTAssertEqual(flow.close(source: source, fallbackIdentifier: "main", eligible: true), .dismiss([]))
    }

    func testAHeldCloseRunsWhenThePurchaseFails() throws {
        let source = try decode(responseJSON(exitOffer: exitOfferJSON()))
        let offer = try XCTUnwrap(source.exitOffer)

        // On the exit offer: the held close ends the flow with the exit offer's dismissal.
        var exit = PaywallExitOfferFlow()
        _ = exit.close(source: source, fallbackIdentifier: "main", eligible: true)
        _ = exit.beginPurchase()
        _ = exit.close(source: source, fallbackIdentifier: "main", eligible: true)
        XCTAssertEqual(exit.purchaseFinished(.failed, fromExitOffer: true, source: source, fallbackIdentifier: "main"), [])
        XCTAssertEqual(exit.settleHeldClose(after: .failed, source: source, fallbackIdentifier: "main", eligible: true),
                       .close(.dismiss(PaywallExitOfferLogic.exitCloseEvents(source: source, exitOffer: offer)), dismissHost: true))
        XCTAssertTrue(exit.ended)

        // On the source: a cancelled purchase then a held close can still show the exit offer.
        var src = PaywallExitOfferFlow()
        XCTAssertTrue(src.beginPurchase())
        XCTAssertEqual(src.close(source: source, fallbackIdentifier: "main", eligible: true), .ignore)
        _ = src.purchaseFinished(.cancelled, fromExitOffer: false, source: source, fallbackIdentifier: "main")
        guard case .close(.showExitOffer, dismissHost: true) = src.settleHeldClose(
            after: .cancelled, source: source, fallbackIdentifier: "main", eligible: true) else {
            return XCTFail("a cancelled purchase then the held close shows the exit offer")
        }
        XCTAssertTrue(src.showingExitOffer)

        // On the source after a sale: the held close is dropped and nothing is recorded as dismissed.
        var sold = PaywallExitOfferFlow()
        _ = sold.beginPurchase()
        _ = sold.close(source: source, fallbackIdentifier: "main", eligible: true)
        XCTAssertEqual(sold.purchaseFinished(.completed, fromExitOffer: false, source: source, fallbackIdentifier: "main").map(\.outcome),
                       ["purchased"])
        XCTAssertEqual(sold.settleHeldClose(after: .completed, source: source, fallbackIdentifier: "main", eligible: true), .none)
        XCTAssertFalse(sold.exitOfferPresented)
    }

    func testAConfirmedPurchaseLatchesThePresentationOnBothStages() throws {
        let source = try decode(responseJSON(exitOffer: exitOfferJSON()))

        // Source: the host confirmed and kept the view mounted — no second billing request starts.
        var src = PaywallExitOfferFlow()
        XCTAssertTrue(src.beginPurchase())
        _ = src.purchaseFinished(.completed, fromExitOffer: false, source: source, fallbackIdentifier: "main")
        XCTAssertTrue(src.purchaseCompleted)
        XCTAssertFalse(src.ended, "the presentation is still on screen")
        XCTAssertFalse(src.beginPurchase(), "a confirmed purchase latches the presentation")

        // Exit offer: same latch, and the first sale is the only one credited.
        var exit = PaywallExitOfferFlow()
        _ = exit.close(source: source, fallbackIdentifier: "main", eligible: true)
        XCTAssertTrue(exit.beginPurchase())
        XCTAssertFalse(exit.purchaseFinished(.completed, fromExitOffer: true, source: source, fallbackIdentifier: "main").isEmpty)
        XCTAssertFalse(exit.beginPurchase())

        // A cancelled or failed purchase leaves room for another attempt.
        var retry = PaywallExitOfferFlow()
        XCTAssertTrue(retry.beginPurchase())
        _ = retry.purchaseFinished(.failed, fromExitOffer: false, source: source, fallbackIdentifier: "main")
        XCTAssertFalse(retry.purchaseCompleted)
        XCTAssertTrue(retry.beginPurchase())
    }

    func testASwipeThatRemovedTheSheetDuringAPurchaseIsOnlyRecorded() throws {
        let source = try decode(responseJSON(exitOffer: exitOfferJSON()))
        let offer = try XCTUnwrap(source.exitOffer)
        var failed = PaywallExitOfferFlow()
        _ = failed.close(source: source, fallbackIdentifier: "main", eligible: true)
        _ = failed.beginPurchase()
        XCTAssertEqual(failed.close(source: source, fallbackIdentifier: "main", eligible: false, sheetAlreadyGone: true), .ignore)
        _ = failed.purchaseFinished(.cancelled, fromExitOffer: true, source: source, fallbackIdentifier: "main")
        XCTAssertEqual(failed.settleHeldClose(after: .cancelled, source: source, fallbackIdentifier: "main", eligible: true),
                       .close(.dismiss(PaywallExitOfferLogic.exitCloseEvents(source: source, exitOffer: offer)), dismissHost: false))

        // The sheet is gone and the purchase sold: the flow just ends.
        var sold = PaywallExitOfferFlow()
        _ = sold.close(source: source, fallbackIdentifier: "main", eligible: true)
        _ = sold.beginPurchase()
        _ = sold.close(source: source, fallbackIdentifier: "main", eligible: false, sheetAlreadyGone: true)
        XCTAssertFalse(sold.purchaseFinished(.completed, fromExitOffer: true, source: source, fallbackIdentifier: "main").isEmpty)
        XCTAssertEqual(sold.settleHeldClose(after: .completed, source: source, fallbackIdentifier: "main", eligible: true), .none)
        XCTAssertTrue(sold.ended)
        XCTAssertFalse(sold.beginPurchase(), "nothing starts once the flow ended")
    }

    func testACancelledExitPurchaseStillRecordsTheExitOffersDismissal() throws {
        let source = try decode(responseJSON(exitOffer: exitOfferJSON()))
        let offer = try XCTUnwrap(source.exitOffer)
        var flow = PaywallExitOfferFlow()
        _ = flow.close(source: source, fallbackIdentifier: "main", eligible: true)
        _ = flow.purchaseFinished(.cancelled, fromExitOffer: true, source: source, fallbackIdentifier: "main")
        XCTAssertEqual(flow.close(source: source, fallbackIdentifier: "main", eligible: true),
                       .dismiss(PaywallExitOfferLogic.exitCloseEvents(source: source, exitOffer: offer)))
    }

    func testALegacyHostsExitPurchaseRecordsNothingPurchaseRelated() throws {
        let source = try decode(responseJSON(exitOffer: exitOfferJSON()))
        let offer = try XCTUnwrap(source.exitOffer)
        var flow = PaywallExitOfferFlow()
        _ = flow.close(source: source, fallbackIdentifier: "main", eligible: true)
        // Without a confirmation, a cancelled sheet must not count as a recovered sale.
        XCTAssertEqual(flow.purchaseHandedOff(fromExitOffer: true, source: source, fallbackIdentifier: "main"), [])
        XCTAssertFalse(flow.exitPurchased)
        XCTAssertEqual(flow.close(source: source, fallbackIdentifier: "main", eligible: true),
                       .dismiss(PaywallExitOfferLogic.exitCloseEvents(source: source, exitOffer: offer)))
    }

    func testAConfirmedSourcePurchaseDisarmsTheExitOffer() throws {
        let source = try decode(responseJSON(exitOffer: exitOfferJSON()))
        var flow = PaywallExitOfferFlow()

        // A cancelled purchase leaves it armed: closing afterwards is a real leave.
        XCTAssertEqual(flow.purchaseFinished(.cancelled, fromExitOffer: false, source: source, fallbackIdentifier: "main"), [])
        XCTAssertTrue(flow.isArmed(eligible: true))

        XCTAssertEqual(flow.purchaseFinished(.completed, fromExitOffer: false, source: source, fallbackIdentifier: "main"), [sourcePurchased])
        XCTAssertFalse(flow.isArmed(eligible: true))
        XCTAssertEqual(flow.close(source: source, fallbackIdentifier: "main", eligible: true), .dismiss([sourceDismissed]))
        XCTAssertFalse(flow.exitOfferPresented)
    }

    func testALegacyHostsSourcePurchaseIsRecordedAtTheTapAndDisarms() throws {
        let source = try decode(responseJSON(exitOffer: exitOfferJSON()))
        var flow = PaywallExitOfferFlow()
        XCTAssertEqual(flow.purchaseHandedOff(fromExitOffer: false, source: source, fallbackIdentifier: "main"), [sourcePurchased])
        XCTAssertEqual(flow.close(source: source, fallbackIdentifier: "main", eligible: true), .dismiss([sourceDismissed]))
    }

    func testARestoreOnTheSourceDisarmsTheExitOffer() throws {
        let source = try decode(responseJSON(exitOffer: exitOfferJSON()))
        var flow = PaywallExitOfferFlow()
        flow.restoreSucceeded()
        XCTAssertFalse(flow.isArmed(eligible: true))
        XCTAssertEqual(flow.close(source: source, fallbackIdentifier: "main", eligible: true), .dismiss([sourceDismissed]))

        // A restore from the exit offer does not end its flow: its close is still recorded.
        var exitFlow = PaywallExitOfferFlow()
        _ = exitFlow.close(source: source, fallbackIdentifier: "main", eligible: true)
        exitFlow.restoreSucceeded()
        XCTAssertTrue(exitFlow.showingExitOffer)
        XCTAssertFalse(exitFlow.sourceEngaged)
    }

    func testTheExitFlowStaysPinnedToTheSourceThatPresentedIt() throws {
        let source = try decode(responseJSON(exitOffer: exitOfferJSON()))
        let offer = try XCTUnwrap(source.exitOffer)
        let refreshed = try decode(responseJSON(exitOffer: nil, experiment: false))
        var flow = PaywallExitOfferFlow()
        _ = flow.close(source: source, fallbackIdentifier: "main", eligible: true)
        // A background refresh changed the served version: the exit flow still reports against the
        // version (and experiment cell) that presented it.
        XCTAssertEqual(flow.purchaseFinished(.completed, fromExitOffer: true, source: refreshed, fallbackIdentifier: "main"),
                       PaywallExitOfferLogic.exitPurchaseEvents(source: source, exitOffer: offer))
        XCTAssertEqual(flow.activeExitOffer, offer)
    }

    func testThePurchaseOutcomeIsAValueHostsCanReturn() async {
        let handler: (PaywallPurchaseRequest) async -> PaywallPurchaseOutcome = { request in
            request.fromExitOffer ? .completed : .cancelled
        }
        let product = PaywallProduct(identifier: "com.app.yearly", label: "Yearly")
        let outcome = await handler(PaywallPurchaseRequest(product: product, offeringIdentifier: "winback", paywallIdentifier: "winback-paywall", fromExitOffer: true))
        XCTAssertEqual(outcome, .completed)
    }
}
