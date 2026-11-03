import XCTest
@testable import BillingBear

// MARK: - Exit-offer telemetry on the wire, placement presentations, offering for a placement
//
// The exit-offer flow itself is covered by PaywallExitOfferTests (pure layer). These tests check
// what reaches the server: the exposure outcomes' wire values, the full exit-offer sequence as POST
// bodies, the placement decision's offering and presentation, and the offering a placement sells.

final class PlacementPresentationTests: XCTestCase {

    // MARK: Fixtures

    private static let document = """
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

    private static let sourceWithExitOffer = """
    {
      "identifier": "main",
      "versionId": "v3",
      "versionNumber": 3,
      "publishedAt": "2026-11-01T00:00:00Z",
      "document": \(document),
      "experiment": { "id": "exp-1", "name": "Price test", "variant": "B" },
      "exitOffer": {
        "type": "offering",
        "paywallIdentifier": "winback-paywall",
        "offeringIdentifier": "winback",
        "maxPresentations": null,
        "perPeriodSeconds": null,
        "eligible": true,
        "paywall": { "identifier": "winback-paywall", "versionId": "v9", "versionNumber": 9,
                     "publishedAt": "2026-10-01T00:00:00Z", "document": \(document) }
      }
    }
    """

    private func source() throws -> PaywallResponse {
        try JSONDecoder().decode(PaywallResponse.self, from: Data(Self.sourceWithExitOffer.utf8))
    }

    private func decision(
        present: Bool = true,
        paywall: String? = "annual-discount",
        offering: String? = "annual_discount",
        presentationId: String? = "pres-1"
    ) -> CampaignDecision {
        CampaignDecision(
            present: present, paywallId: paywall.map { "id-\($0)" }, paywallIdentifier: paywall, campaignId: nil,
            ruleReason: present ? "matched" : "no_match", offeringIdentifier: offering,
            experimentId: "oe-1", experimentName: "Annual price", variant: "treatment", presentationId: presentationId)
    }

    /// Exposure POSTs in the order they were sent: (paywall identifier, body).
    private func exposures(_ http: MockHTTPClient) -> [(String, [String: Any])] {
        http.requests.compactMap { request in
            guard request.method == "POST", request.path.hasSuffix("/exposures") else { return nil }
            let id = request.path
                .replacingOccurrences(of: "/v1/paywalls/by-identifier/", with: "")
                .replacingOccurrences(of: "/exposures", with: "")
            return (id, request.body ?? [:])
        }
    }

    // MARK: Wire values

    func testTheExposureOutcomesHaveTheServersWireValues() {
        XCTAssertEqual(PaywallExposureOutcome.allCases.map(\.rawValue), [
            "viewed", "dismissed", "purchased", "exit_offer_viewed", "exit_offer_purchased", "exit_offer_dismissed",
        ])
        for outcome in PaywallExposureOutcome.allCases {
            XCTAssertLessThanOrEqual(outcome.rawValue.count, 20, "paywall_exposures.outcome is varchar(20)")
        }
        XCTAssertEqual(PaywallExitOfferLogic.viewedOutcome, PaywallExposureOutcome.exitOfferViewed.rawValue)
        XCTAssertEqual(PaywallExitOfferLogic.purchasedOutcome, PaywallExposureOutcome.exitOfferPurchased.rawValue)
        XCTAssertEqual(PaywallExitOfferLogic.dismissedOutcome, PaywallExposureOutcome.exitOfferDismissed.rawValue)
    }

    func testEveryOutcomeTheExitFlowProducesCanBeSent() throws {
        let source = try source()
        let offer = try XCTUnwrap(source.exitOffer)
        let events = PaywallExitOfferLogic.sourceCloseEvents(source: source, presentsExitOffer: true)
            + PaywallExitOfferLogic.exitPurchaseEvents(source: source, exitOffer: offer)
            + PaywallExitOfferLogic.exitCloseEvents(source: source, exitOffer: offer)
        for event in events {
            XCTAssertNotNil(PaywallExposureOutcome(rawValue: event.outcome), "\(event.outcome) would be skipped")
        }
    }

    // MARK: The exit-offer sequence on the wire

    func testTheExitOfferSequenceReachesTheServerInOrder() async throws {
        let h = await Harness.make(observe: false) { request, count in
            request.path.hasSuffix("/exposures") ? .json(201, "{}") : Harness.defaultResponder()(request, count)
        }
        var flow = PaywallExitOfferFlow()
        let source = try source()

        // Close → the exit offer takes the source's place; buy from it (confirmed); close it.
        guard case .showExitOffer(let shown) = flow.close(source: source, fallbackIdentifier: "main", eligible: true) else {
            return XCTFail("the exit offer should be shown")
        }
        await PaywallExposureRecorder.record(shown, through: h.purchases)?.value
        XCTAssertTrue(flow.beginPurchase())
        let bought = flow.purchaseFinished(.completed, fromExitOffer: true, source: source, fallbackIdentifier: "main")
        await PaywallExposureRecorder.record(bought, through: h.purchases)?.value

        let sent = exposures(h.http)
        XCTAssertEqual(sent.map { $0.0 }, ["main", "main", "winback-paywall", "winback-paywall", "main"])
        XCTAssertEqual(sent.map { $0.1["outcome"] as? String }, [
            "dismissed", "exit_offer_viewed", "viewed", "purchased", "exit_offer_purchased",
        ])
        // The source's outcomes carry its own A/B cell; the exit paywall's carry none.
        for (id, body) in sent {
            XCTAssertEqual(body["appUserId"] as? String, "u1")
            XCTAssertEqual(body["experimentId"] as? String, id == "main" ? "exp-1" : nil)
            XCTAssertEqual(body["variant"] as? String, id == "main" ? "B" : nil)
            XCTAssertNil(body["presentationId"], "only a placement presentation's view names it")
        }
    }

    func testClosingTheExitOfferSendsItsDismissalAndTheSourcesExitOfferDismissed() async throws {
        let h = await Harness.make(observe: false) { request, count in
            request.path.hasSuffix("/exposures") ? .json(201, "{}") : Harness.defaultResponder()(request, count)
        }
        var flow = PaywallExitOfferFlow()
        let source = try source()
        _ = flow.close(source: source, fallbackIdentifier: "main", eligible: true)
        guard case .dismiss(let closed) = flow.close(source: source, fallbackIdentifier: "main", eligible: true) else {
            return XCTFail("closing the exit offer ends the flow")
        }
        await PaywallExposureRecorder.record(closed, through: h.purchases)?.value

        XCTAssertEqual(exposures(h.http).map { "\($0.0):\($0.1["outcome"] as? String ?? "")" }, [
            "winback-paywall:dismissed", "main:exit_offer_dismissed",
        ])
    }

    // MARK: Placement decision → paywall

    func testThePlacementDecisionCarriesItsPresentation() throws {
        let json = """
        { "present": true, "paywallId": "p1", "paywallIdentifier": "annual-discount", "campaignId": null,
          "ruleReason": "matched", "offeringIdentifier": "annual_discount", "presentationId": "9f0c" }
        """
        let decoded = try JSONDecoder().decode(CampaignDecision.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.presentationId, "9f0c")
        XCTAssertEqual(PaywallPlacementPresentation(decision: decoded),
                       PaywallPlacementPresentation(paywallIdentifier: "annual-discount", presentationId: "9f0c"))

        let old = #"{ "present": true, "paywallId": "p1", "paywallIdentifier": "annual-discount", "campaignId": null, "ruleReason": "matched" }"#
        let legacy = try JSONDecoder().decode(CampaignDecision.self, from: Data(old.utf8))
        XCTAssertNil(legacy.presentationId)
        XCTAssertNil(PaywallPlacementPresentation(decision: decision(present: false)), "nothing presented")
        XCTAssertNil(PaywallPlacementPresentation(decision: decision(paywall: nil)))
        XCTAssertNil(PaywallPlacementPresentation(decision: decision(paywall: "")))
    }

    @available(iOS 15.0, macOS 12.0, *)
    func testAPaywallBuiltFromTheDecisionSellsItsOfferingAndKnowsItsPresentation() throws {
        let paywall = try XCTUnwrap(BillingBearPaywall(decision: decision(), onDismiss: {}))
        XCTAssertEqual(paywall.purchaseOfferingIdentifier, "annual_discount",
                       "purchases are looked up in the decision's offering first and handed to onPurchaseRequest")
        XCTAssertEqual(paywall.placementPresentation,
                       PaywallPlacementPresentation(paywallIdentifier: "annual-discount", presentationId: "pres-1"))

        XCTAssertNil(BillingBearPaywall(decision: decision(present: false)), "a decision that presents nothing builds nothing")
        XCTAssertNil(BillingBearPaywall(decision: decision(paywall: nil)))
        XCTAssertNil(try XCTUnwrap(BillingBearPaywall(decision: decision(offering: nil))).purchaseOfferingIdentifier,
                     "an older server's decision has no offering: the usual lookup")
    }

    @available(iOS 15.0, macOS 12.0, *)
    func testTheDecisionModifierAppliesOnlyToThePaywallItPresented() {
        let tied = BillingBearPaywall(identifier: "annual-discount").placementDecision(decision())
        XCTAssertEqual(tied.purchaseOfferingIdentifier, "annual_discount")
        XCTAssertEqual(tied.placementPresentation?.presentationId, "pres-1")

        let other = BillingBearPaywall(identifier: "another").placementDecision(decision())
        XCTAssertNil(other.purchaseOfferingIdentifier)
        XCTAssertNil(other.placementPresentation)

        let skipped = BillingBearPaywall(identifier: "annual-discount").placementDecision(decision(present: false))
        XCTAssertNil(skipped.placementPresentation)
    }

    func testAPlacementPresentationsViewIsSentOnlyToCarryItsABCellAndNamesThePresentation() {
        let presentation = PaywallPlacementPresentation(paywallIdentifier: "annual-discount", presentationId: "pres-1")
        let cell = PaywallExperimentAssignment(id: "exp-9", name: "Copy test", variant: "B")

        XCTAssertNil(PaywallViewRecording.sourceViewEvent(identifier: "annual-discount", experiment: nil, presentation: presentation),
                     "the evaluation already recorded this presentation's view")
        XCTAssertEqual(
            PaywallViewRecording.sourceViewEvent(identifier: "annual-discount", experiment: cell, presentation: presentation),
            PaywallExposureEvent(identifier: "annual-discount", outcome: "viewed", experimentId: "exp-9", variant: "B", presentationId: "pres-1"))
        XCTAssertEqual(
            PaywallViewRecording.sourceViewEvent(identifier: "annual-discount", experiment: nil, presentation: nil),
            PaywallExposureEvent(identifier: "annual-discount", outcome: "viewed"), "shown directly: recorded as always")
        XCTAssertEqual(
            PaywallViewRecording.sourceViewEvent(identifier: "other", experiment: cell, presentation: presentation),
            PaywallExposureEvent(identifier: "other", outcome: "viewed", experimentId: "exp-9", variant: "B"),
            "another paywall than the decision presented is not that presentation")
    }

    func testTheViewOfAPresentationIsSentWithItsId() async throws {
        let h = await Harness.make(observe: false) { request, count in
            request.path.hasSuffix("/exposures") ? .json(201, "{}") : Harness.defaultResponder()(request, count)
        }
        let event = try XCTUnwrap(PaywallViewRecording.sourceViewEvent(
            identifier: "annual-discount",
            experiment: PaywallExperimentAssignment(id: "exp-9", name: "Copy test", variant: "B"),
            presentation: PaywallPlacementPresentation(paywallIdentifier: "annual-discount", presentationId: "pres-1")))
        await PaywallExposureRecorder.record([event], through: h.purchases)?.value
        await h.purchases.recordExposure(identifier: "annual-discount", outcome: .dismissed)

        let sent = exposures(h.http)
        XCTAssertEqual(sent.count, 2)
        XCTAssertEqual(sent[0].1["outcome"] as? String, "viewed")
        XCTAssertEqual(sent[0].1["presentationId"] as? String, "pres-1")
        XCTAssertEqual(sent[0].1["experimentId"] as? String, "exp-9")
        XCTAssertNil(sent[1].1["presentationId"], "omitted, never sent as null")
    }

    // MARK: Offering for a placement

    private static let offeringsJSON = """
    { "currentOfferingId": "default", "offerings": [
      { "identifier": "default", "displayName": "Default", "description": null, "isCurrent": true, "packages": [], "paywall": null },
      { "identifier": "annual_discount", "displayName": "Annual discount", "description": null, "isCurrent": false, "packages": [], "paywall": null }
    ] }
    """

    private func placementHarness(_ decisionJSON: String) async -> Harness {
        await Harness.make(observe: false) { request, count in
            if request.method == "POST" && request.path == "/v1/placements/paywall_gate/evaluate" { return .json(200, decisionJSON) }
            if request.path.hasPrefix("/v1/subscribers/u1/offerings") { return .json(200, Self.offeringsJSON) }
            return Harness.defaultResponder()(request, count)
        }
    }

    func testThePlacementsOfferingIsTheExperimentVariantsOffering() async throws {
        let h = await placementHarness(#"{"present":true,"paywallId":null,"paywallIdentifier":"p","campaignId":null,"ruleReason":"matched","offeringIdentifier":"annual_discount"}"#)
        let offering = try await h.purchases.currentOffering(forPlacement: "paywall_gate")
        XCTAssertEqual(offering?.identifier, "annual_discount")
        XCTAssertEqual(h.http.requests("POST", "/v1/placements/paywall_gate/evaluate").first?.body?["appUserId"] as? String, "u1")
    }

    func testWithoutAnOfferingAPresentingPlacementSellsTheCurrentOffering() async throws {
        let h = await placementHarness(#"{"present":true,"paywallId":null,"paywallIdentifier":"p","campaignId":null,"ruleReason":"matched"}"#)
        let offering = try await h.purchases.currentOffering(forPlacement: "paywall_gate")
        XCTAssertEqual(offering?.identifier, "default")
    }

    func testAPlacementWithNothingToShowHasNoOffering() async throws {
        let h = await placementHarness(#"{"present":false,"paywallId":null,"paywallIdentifier":null,"campaignId":null,"ruleReason":"holdout"}"#)
        let offering = try await h.purchases.currentOffering(forPlacement: "paywall_gate")
        XCTAssertNil(offering)
        XCTAssertTrue(h.http.requests.filter { $0.path.contains("/offerings") }.isEmpty, "nothing to look up")
    }

    func testAHeldOutCustomerStillGetsThePlacementsOffering() async throws {
        // Not presenting a paywall (holdout) does not change which offering the placement sells.
        let h = await placementHarness(#"{"present":false,"paywallId":null,"paywallIdentifier":null,"campaignId":null,"ruleReason":"holdout","offeringIdentifier":"annual_discount"}"#)
        let offering = try await h.purchases.currentOffering(forPlacement: "paywall_gate")
        XCTAssertEqual(offering?.identifier, "annual_discount")
    }
}
