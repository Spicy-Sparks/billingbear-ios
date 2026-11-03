#if canImport(SwiftUI)
import SwiftUI

// MARK: - BillingBearPaywall
//
// Native SwiftUI paywall renderer. Ported from the React Native SDK's `Paywall.tsx`. Given either
// a paywall identifier (fetched from the dashboard) or an already-fetched PaywallDocument, it
// renders the document: every layout (vertical-features / horizontal-products / minimal / hero-image
// / comparison-table), theme colours/fonts/radii, light/dark, solid + image + gradient + video +
// lottie backgrounds, header/hero/logo, features (built-in SF Symbols icon mapping), the component
// catalog (urgency banner + live countdown, "how it works" timeline, tier tabs, free-trial switch),
// selectable product cards (badge/highlight/sublabel/trial), the comparison feature×plan matrix,
// CTA button, footer links, {{variable}} interpolation, locale translation lookup, product-
// visibility filtering, multi-page carousel + page dots, and entry animations. Fires
// recordExposure(viewed) on appear and purchased/dismissed appropriately.
//
// The reusable components live in PaywallComponents.swift; pure formatting/cell logic (countdown
// formatting, comparison-cell resolution, ISO date parsing) lives in PaywallTransforms so it is
// unit-testable without the view layer.

@available(iOS 15.0, macOS 12.0, *)
public struct BillingBearPaywall: View {

    // MARK: Inputs

    private let identifier: String?
    private let initialDocument: PaywallDocument?
    private let initialResponse: PaywallResponse?
    /// v2 free-form component tree. When set, the native tree renderer (PaywallTreeView) handles the
    /// whole paywall and the v1 preset path below is bypassed entirely. This is how a `version: 2`
    /// document flows through the same public entry without any signature change.
    private let initialTree: PaywallTree?

    private let variables: [String: String]?
    private let locale: String?
    private let userContext: PaywallUserContext?
    private let onPurchase: ((PaywallProduct) -> Void)?
    private let onDismiss: (() -> Void)?

    // Set through the modifiers below (`purchaseOffering`, `placementDecision`, `exitOffersEnabled`,
    // `onPurchaseRequest`) so every existing initializer keeps its exact signature.
    private(set) var purchaseOfferingIdentifier: String?
    /// The placement decision that presented this paywall, if any (`init(decision:)`).
    private(set) var placementPresentation: PaywallPlacementPresentation?
    private var handlesExitOffers = true
    private var onPurchaseRequest: ((PaywallPurchaseRequest) async -> PaywallPurchaseOutcome)?
    private var exitOfferHistory: PaywallExitOfferHistory = .shared

    // MARK: Init

    /// Render a paywall by identifier — fetched from the dashboard on appear.
    public init(
        identifier: String,
        variables: [String: String]? = nil,
        locale: String? = nil,
        userContext: PaywallUserContext? = nil,
        onPurchase: ((PaywallProduct) -> Void)? = nil,
        onDismiss: (() -> Void)? = nil
    ) {
        self.identifier = identifier
        self.initialDocument = nil
        self.initialResponse = nil
        self.initialTree = nil
        self.variables = variables
        self.locale = locale
        self.userContext = userContext
        self.onPurchase = onPurchase
        self.onDismiss = onDismiss
    }

    /// Render the paywall a placement decision presents (`Purchases.shared.register(_:)`); nil when
    /// the decision presents nothing. Purchases are looked up in the decision's `offeringIdentifier`
    /// first (an offering experiment's variant, else the placement's default offering; it reaches the
    /// host through `onPurchaseRequest(_:)`), and the view is attributed to the evaluation's
    /// presentation instead of being counted a second time.
    ///
    /// Each decision is a new presentation: when a new decision replaces the one on screen, give the
    /// view a new identity (`.id(decision.presentationId)`) so its exit-offer flow and view start over.
    ///
    /// ```swift
    /// let decision = try await Purchases.shared.register("onboarding_complete")
    /// if let paywall = BillingBearPaywall(decision: decision, onDismiss: { showPaywall = false }) {
    ///     paywall.onPurchaseRequest { request in await buy(request) }
    /// }
    /// ```
    public init?(
        decision: CampaignDecision,
        variables: [String: String]? = nil,
        locale: String? = nil,
        userContext: PaywallUserContext? = nil,
        onPurchase: ((PaywallProduct) -> Void)? = nil,
        onDismiss: (() -> Void)? = nil
    ) {
        guard let presentation = PaywallPlacementPresentation(decision: decision) else { return nil }
        self.init(
            identifier: presentation.paywallIdentifier,
            variables: variables,
            locale: locale,
            userContext: userContext,
            onPurchase: onPurchase,
            onDismiss: onDismiss
        )
        self.purchaseOfferingIdentifier = decision.offeringIdentifier
        self.placementPresentation = presentation
    }

    /// Render an already-fetched paywall response (carries experiment assignment for telemetry).
    public init(
        response: PaywallResponse,
        variables: [String: String]? = nil,
        locale: String? = nil,
        userContext: PaywallUserContext? = nil,
        onPurchase: ((PaywallProduct) -> Void)? = nil,
        onDismiss: (() -> Void)? = nil
    ) {
        self.identifier = response.identifier
        self.initialDocument = response.document
        self.initialResponse = response
        self.initialTree = nil
        self.variables = variables
        self.locale = locale
        self.userContext = userContext
        self.onPurchase = onPurchase
        self.onDismiss = onDismiss
    }

    /// Render a raw document (no telemetry identifier).
    public init(
        document: PaywallDocument,
        variables: [String: String]? = nil,
        locale: String? = nil,
        userContext: PaywallUserContext? = nil,
        onPurchase: ((PaywallProduct) -> Void)? = nil,
        onDismiss: (() -> Void)? = nil
    ) {
        self.identifier = nil
        self.initialDocument = document
        self.initialResponse = nil
        self.initialTree = nil
        self.variables = variables
        self.locale = locale
        self.userContext = userContext
        self.onPurchase = onPurchase
        self.onDismiss = onDismiss
    }

    /// Render a v2 free-form component tree directly (native tree renderer). Used by the
    /// version-detecting `init(documentJson:)` and available to callers that already hold a decoded
    /// `PaywallTree`.
    public init(
        tree: PaywallTree,
        variables: [String: String]? = nil,
        locale: String? = nil,
        userContext: PaywallUserContext? = nil,
        onPurchase: ((PaywallProduct) -> Void)? = nil,
        onDismiss: (() -> Void)? = nil
    ) {
        self.identifier = nil
        self.initialDocument = nil
        self.initialResponse = nil
        self.initialTree = tree
        self.variables = variables
        self.locale = locale
        self.userContext = userContext
        self.onPurchase = onPurchase
        self.onDismiss = onDismiss
    }

    /// VERSION-DETECTING entry. Decodes a raw paywall JSON string (a bare document/tree OR a
    /// wrapping `PaywallResponse`) and routes it: `version: 2` → the native tree renderer, anything
    /// else → the existing v1 preset renderer. Returns nil only when the JSON is unusable, so the
    /// caller can fall back (to an identifier fetch / empty view). This is the single plug-and-play
    /// hook the RN bridge uses, keeping every existing signature unchanged.
    public init?(
        documentJson json: String,
        variables: [String: String]? = nil,
        locale: String? = nil,
        userContext: PaywallUserContext? = nil,
        onPurchase: ((PaywallProduct) -> Void)? = nil,
        onDismiss: (() -> Void)? = nil
    ) {
        guard !json.isEmpty, let data = json.data(using: .utf8) else { return nil }
        let decoder = JSONDecoder()

        switch PaywallDocumentVersion.detect(from: data) {
        case .v2:
            // The v2 tree may arrive bare or inside a `{ "document": { … } }` envelope. Try the
            // bare tree first; if that fails, unwrap the envelope's `document` and decode that.
            if let tree = try? decoder.decode(PaywallTree.self, from: data) {
                self.init(tree: tree, variables: variables, locale: locale, userContext: userContext, onPurchase: onPurchase, onDismiss: onDismiss)
                return
            }
            if let wrapper = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let docObj = wrapper["document"],
               let docData = try? JSONSerialization.data(withJSONObject: docObj),
               let tree = try? decoder.decode(PaywallTree.self, from: docData) {
                self.init(tree: tree, variables: variables, locale: locale, userContext: userContext, onPurchase: onPurchase, onDismiss: onDismiss)
                return
            }
            return nil
        case .v1:
            // v1: prefer the response envelope (carries the experiment assignment for telemetry),
            // else a bare document — exactly the prior RN-bridge decode order.
            if let response = try? decoder.decode(PaywallResponse.self, from: data) {
                self.init(response: response, variables: variables, locale: locale, userContext: userContext, onPurchase: onPurchase, onDismiss: onDismiss)
                // This is the React Native bridge's entry: the JS layer runs the exit-offer flow
                // (and its telemetry) itself by swapping `documentJson`, so the native view must not
                // run it a second time.
                self.handlesExitOffers = false
                return
            }
            if let document = try? decoder.decode(PaywallDocument.self, from: data) {
                self.init(document: document, variables: variables, locale: locale, userContext: userContext, onPurchase: onPurchase, onDismiss: onDismiss)
                return
            }
            return nil
        }
    }

    // MARK: State

    @Environment(\.colorScheme) private var colorScheme
    @StateObject private var model = PaywallModel()
    @State private var selectedProductId: String?
    @State private var selectedTabId: String?
    @State private var currentPage: Int = 0
    @State private var appeared = false
    /// This presentation's exit-offer flow: whether the offer is on screen, was shown, was disarmed
    /// by a purchase or restore, was bought from, or ended (see PaywallExitOfferFlow).
    @State private var flow = PaywallExitOfferFlow()
    /// The hosting sheet's swipe-down attempts reach this paywall (see PaywallSheetDismissInterceptor);
    /// only then is a swipe blocked and routed through the close flow.
    @State private var interceptsSheetSwipe = false

    // MARK: Modifiers

    /// The offering the paywall's products should be bought from first — pass the placement
    /// decision's `offeringIdentifier` (an offering experiment's variant or the placement default).
    /// Reaches the host through `onPurchaseRequest(_:)`.
    public func purchaseOffering(_ offeringIdentifier: String?) -> BillingBearPaywall {
        var copy = self
        copy.purchaseOfferingIdentifier = offeringIdentifier
        return copy
    }

    /// Tie a paywall you build yourself (for example from a response you fetched with
    /// `getPaywall(decision.paywallIdentifier)`) to the placement decision that presents it, as
    /// `init(decision:)` does: purchases use the decision's offering first, and the view is
    /// attributed to the evaluation's presentation. Ignored when the decision presents nothing or
    /// another paywall.
    public func placementDecision(_ decision: CampaignDecision) -> BillingBearPaywall {
        guard let presentation = PaywallPlacementPresentation(decision: decision),
              presentation.paywallIdentifier == identifier else { return self }
        var copy = self
        copy.purchaseOfferingIdentifier = decision.offeringIdentifier
        copy.placementPresentation = presentation
        return copy
    }

    /// Turn the dashboard-configured exit offer on or off for this view (on by default). With it on,
    /// a user close without buying shows the exit offer in place, once, within its frequency cap.
    /// Presented as a sheet, a swipe-down then goes through the same close: it shows the offer in
    /// place, and on the offer it performs the final close.
    public func exitOffersEnabled(_ enabled: Bool) -> BillingBearPaywall {
        var copy = self
        copy.handlesExitOffers = enabled
        return copy
    }

    /// Receive purchases with their context (which offering to buy from first, which paywall is on
    /// screen, whether it is an exit offer) and report how they ended. When set it replaces
    /// `onPurchase`. Only a `.completed` outcome is recorded as a conversion, disarms the source
    /// paywall's exit offer, or ends an exit-offer flow; after `.cancelled` / `.failed` the paywall
    /// stays as it was, so a customer who backs out of the store sheet can still close it. The CTA is
    /// busy while the handler runs.
    public func onPurchaseRequest(
        _ handler: @escaping (PaywallPurchaseRequest) async -> PaywallPurchaseOutcome
    ) -> BillingBearPaywall {
        var copy = self
        copy.onPurchaseRequest = handler
        return copy
    }

    /// Use another record of exit-offer presentations (tests, a per-account store).
    func exitOfferHistory(_ history: PaywallExitOfferHistory) -> BillingBearPaywall {
        var copy = self
        copy.exitOfferHistory = history
        return copy
    }

    private var currentResponse: PaywallResponse? { model.response ?? initialResponse }

    /// Whether the exit offer of `source` may be presented now, before the flow's own state: exit
    /// offers on, a host close handler, a renderable offer within the server's and the device's cap.
    private func exitOfferEligible(_ source: PaywallResponse?, now: Date = Date()) -> Bool {
        guard handlesExitOffers, onDismiss != nil, let source, source.exitOffer != nil else { return false }
        return PaywallExitOfferLogic.shouldPresent(
            source.exitOffer,
            alreadyPresented: flow.exitOfferPresented,
            presentationTimes: exitOfferHistory.presentations(for: source.identifier),
            now: now)
    }

    /// True while a user close would show the exit offer — used to keep the sheet from being swiped
    /// away, which would skip the offer.
    private var exitOfferArmed: Bool {
        flow.isArmed(eligible: exitOfferEligible(currentResponse))
    }

    /// The exit offer is on screen and not yet bought from or closed: a swipe would skip its close.
    private var exitOfferPending: Bool {
        flow.showingExitOffer && !flow.exitPurchased && !flow.ended
    }

    public var body: some View {
        Group {
            if let tree = initialTree {
                treeContent(tree)
            } else if flow.showingExitOffer, let exitOffer = flow.activeExitOffer, let exitPaywall = exitOffer.paywall {
                exitOfferContent(exitOffer, exitPaywall)
            } else if let response = currentResponse {
                content(for: response.document, experiment: response.experiment)
            } else if let doc = initialDocument {
                content(for: doc, experiment: nil)
            } else if model.error != nil {
                errorView
            } else {
                loadingView
            }
        }
        .onAppear {
            // INSTANT PRESENT: seed synchronously from the persistent cache (zero network) so the
            // paywall paints on the first frame when a cached copy exists. The `.task` below then
            // revalidates / does a live fetch on a miss. The synchronous read is the speed win.
            if model.response == nil, initialDocument == nil, initialTree == nil, let identifier {
                model.seedFromCache(identifier: identifier)
            }
        }
        .task {
            if initialDocument == nil, initialTree == nil, let identifier {
                await model.loadOrRevalidate(identifier: identifier)
            }
        }
        .background(sheetDismissInterceptor)
        .interactiveDismissDisabled(PaywallSheetDismissPolicy.blocksSwipe(
            armed: exitOfferArmed, pending: exitOfferPending, intercepting: interceptsSheetSwipe))
    }

    /// Joins the hosting sheet's dismissal (iOS) while this paywall has an exit offer to protect:
    /// a blocked swipe runs the same close as the close button; a swipe that dismissed is recorded.
    @ViewBuilder
    private var sheetDismissInterceptor: some View {
        #if os(iOS)
        PaywallSheetDismissInterceptor(
            active: handlesExitOffers && onDismiss != nil && currentResponse?.exitOffer != nil,
            onInstalled: { interceptsSheetSwipe = $0 },
            onAttempt: { dismiss() },
            onSwipeDismissed: { recordSwipeDismissal() })
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
        #else
        EmptyView()
        #endif
    }

    /// The sheet was swiped away (the swipe was allowed: nothing left to protect). Record the close it
    /// was, without asking the host to dismiss again — the sheet is already gone.
    private func recordSwipeDismissal() {
        // While a purchase is pending the close is held by the flow and settled with the outcome.
        switch flow.close(source: currentResponse, fallbackIdentifier: identifier, eligible: false, sheetAlreadyGone: true) {
        case .dismiss(let events):
            PaywallExposureRecorder.record(events)
        case .showExitOffer, .ignore:
            break
        }
    }

    // MARK: Exit offer

    /// The exit paywall in place of the source: a v1 document through the preset renderer, a v2
    /// tree through the tree renderer. It is always closable (an exit paywall whose design hides
    /// the close control still gets one), and never presents an exit offer of its own.
    @ViewBuilder
    private func exitOfferContent(_ exitOffer: PaywallExitOffer, _ exitPaywall: PaywallExitOfferPaywall) -> some View {
        if let tree = exitPaywall.tree {
            ZStack(alignment: .topTrailing) {
                PaywallTreeView(
                    tree: tree,
                    variables: variables,
                    locale: locale,
                    userContext: userContext,
                    isSubscribed: nil,
                    onAction: { action, product in handleExitTreeAction(action, product: product) }
                )
                if !tree.hasDismissAction {
                    closeButton(color: Color.css(tree.theme.textColor, fallback: .white))
                }
            }
        } else if let document = exitPaywall.document {
            content(for: document, experiment: nil, isExitOffer: true)
        }
    }

    private func handleExitTreeAction(_ action: PaywallAction, product: PaywallProduct?) {
        switch action {
        case .purchase:
            guard let product else { return }
            purchase(product, isExitOffer: true)
        case .restore:
            Task { await handleRestore() }
        case .dismiss:
            dismiss()
        case .url(let urlString):
            open(urlString)
        case .event, .selectProduct, .nextPage, .prevPage, .goToPage, .unknown:
            break
        }
    }

    private func closeButton(color: Color) -> some View {
        Button(action: dismiss) {
            Image(systemName: "xmark")
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(color.opacity(0.7))
                .padding(10)
        }
        .padding(.top, 8)
        .padding(.trailing, 8)
        .accessibilityLabel("Close")
    }

    // MARK: v2 — native tree renderer

    @ViewBuilder
    private func treeContent(_ tree: PaywallTree) -> some View {
        // NO host-added close button for v2 trees: the tree owns its chrome (templates include their
        // own absolute close "✕" node), exactly like the web renderer. Auto-adding one here produced a
        // SECOND, stray X. The tree's close node dismisses via handleTreeAction(.dismiss).
        PaywallTreeView(
            tree: tree,
            variables: variables,
            locale: locale,
            userContext: userContext,
            isSubscribed: nil,
            onAction: { action, product in handleTreeAction(action, product: product) }
        )
        .onAppear { recordViewed(initialResponse?.experiment) }
    }

    /// Bridge the tree's resolved actions to the existing purchase/restore/dismiss/url flow + exposure
    /// telemetry — the same outcomes the v1 path fires, so callers see no behavioural difference.
    private func handleTreeAction(_ action: PaywallAction, product: PaywallProduct?) {
        switch action {
        case .purchase:
            guard let product else { return }
            // The same path as the v1 CTA: `onPurchaseRequest` hosts get the request and confirm it,
            // legacy `onPurchase` hosts get the product with the `purchased` exposure at the tap.
            purchase(product, isExitOffer: false)
        case .restore:
            Task { await handleRestore() }
        case .dismiss:
            dismiss()
        case .url(let urlString):
            open(urlString)
        case .event:
            // Custom analytics placement — no built-in sink; hosts hook this via their own SDK.
            break
        case .selectProduct, .nextPage, .prevPage, .goToPage, .unknown:
            // Resolved inside PaywallTreeView; nothing to do here.
            break
        }
    }

    // MARK: Resolved document

    /// Apply translations → dark-theme override; project the active page; filter products.
    private func resolved(_ base: PaywallDocument) -> PaywallDocument {
        var doc = PaywallTransforms.applyTranslation(base, locale: locale ?? Locale.current.identifier)
        if colorScheme == .dark, let dark = doc.darkTheme {
            doc.theme = doc.theme.merging(dark)
        }
        let pages = doc.pages ?? []
        if !pages.isEmpty {
            let idx = min(currentPage, pages.count - 1)
            doc = PaywallTransforms.pageToDocument(doc, pages[idx])
        }
        if let ctx = userContext {
            doc.products = doc.products.filter { PaywallTransforms.isProductVisible($0, ctx) }
        }
        return doc
    }

    @ViewBuilder
    private func content(for base: PaywallDocument, experiment: PaywallExperimentAssignment?, isExitOffer: Bool = false) -> some View {
        let pages = base.pages ?? []
        let isMultiPage = !pages.isEmpty
        let doc = resolved(base)
        let theme = doc.theme
        let bg = Color.css(theme.background, fallback: .black)
        let isLastPage = !isMultiPage || currentPage >= pages.count - 1

        ZStack(alignment: .topTrailing) {
            bg.ignoresSafeArea()
            backgroundLayer(theme)

            VStack(spacing: 0) {
                ScrollView(showsIndicators: false) {
                    PaywallBodyView(
                        document: doc,
                        theme: theme,
                        selectedProductId: $selectedProductId,
                        selectedTabId: $selectedTabId,
                        variables: variables,
                        appeared: appeared
                    )
                    .padding(.bottom, 24)
                    .padding(.top, 40)
                }

                footer(doc: doc, theme: theme, isMultiPage: isMultiPage, isLastPage: isLastPage, pageCount: pages.count, isExitOffer: isExitOffer)
            }

            // An exit offer is always closable, whatever its design says about the close control.
            if showCloseButton(doc) || (isExitOffer && onDismiss != nil) {
                closeButton(color: Color.css(theme.textColor, fallback: .white))
            }
        }
        .onAppear {
            armSelection(doc)
            withAnimation(.easeOut(duration: 0.32)) { appeared = true }
            // The exit paywall's `viewed` is recorded when it takes the source's place.
            if !isExitOffer { recordViewed(experiment) }
        }
    }

    // MARK: Background

    @ViewBuilder
    private func backgroundLayer(_ theme: PaywallTheme) -> some View {
        // Solid + image handled inline; gradient / video / lottie via paywallBackground
        // (SwiftUI/AVKit built-ins + bundled lottie-ios — no manual deps).
        let solid = Color.css(theme.background, fallback: .black)
        if theme.backgroundType == .image, let img = theme.backgroundImage {
            ZStack {
                RemoteImage(url: img.url, contentMode: img.size == "contain" ? .fit : .fill)
                    .opacity(img.opacity ?? 1)
                    .ignoresSafeArea()
                if let overlay = img.overlay, let c = Color(css: overlay) {
                    c.ignoresSafeArea()
                }
            }
        } else {
            paywallBackground(theme, solid: solid)
        }
    }

    // MARK: Footer (CTA + microtext + page dots + links)

    @ViewBuilder
    private func footer(
        doc: PaywallDocument,
        theme: PaywallTheme,
        isMultiPage: Bool,
        isLastPage: Bool,
        pageCount: Int,
        isExitOffer: Bool = false
    ) -> some View {
        let primary = Color.css(theme.primaryColor, fallback: .accentColor)
        let ctaTextColor = Color.css(theme.ctaTextColor, fallback: .white)
        let textColor = Color.css(theme.textColor, fallback: .white)
        let shape = doc.cta.shape ?? "rounded"
        let radius: CGFloat = shape == "pill" ? 999 : shape == "square" ? 4 : CGFloat(theme.buttonBorderRadius ?? 18)
        // After a confirmed purchase the CTA stays inert: the purchase latch refuses a second one.
        let ctaDisabled = (isLastPage && selectedProductId == nil) || flow.purchaseCompleted

        VStack(spacing: 8) {
            if isMultiPage {
                HStack(spacing: 6) {
                    ForEach(0..<pageCount, id: \.self) { i in
                        Capsule()
                            .fill(i == currentPage ? primary : textColor.opacity(0.3))
                            .frame(width: i == currentPage ? 18 : 6, height: 6)
                    }
                }
                .padding(.bottom, 6)
            }

            Button(action: { handleCta(doc: doc, isMultiPage: isMultiPage, isLastPage: isLastPage, pageCount: pageCount, isExitOffer: isExitOffer) }) {
                Text(model.busy ? "Please wait…" : PaywallTransforms.interpolate(doc.cta.text, variables))
                    .font(.system(size: 16, weight: .bold))
                    .foregroundColor(ctaTextColor)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(primary)
                    .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            }
            .disabled(model.busy || ctaDisabled)
            .opacity(model.busy || ctaDisabled ? 0.6 : 1)

            if let micro = doc.cta.microtext {
                Text(PaywallTransforms.interpolate(micro, variables))
                    .font(.system(size: 11))
                    .foregroundColor(textColor.opacity(0.55))
                    .multilineTextAlignment(.center)
            }

            if showFooterLinks(doc, isMultiPage: isMultiPage, isLastPage: isLastPage) {
                footerLinks(doc.footer, textColor: textColor)
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 12)
        .padding(.bottom, 28)
    }

    @ViewBuilder
    private func footerLinks(_ footer: PaywallFooter, textColor: Color) -> some View {
        HStack(spacing: 6) {
            if let restore = footer.restoreText {
                linkButton(restore, color: textColor) { Task { await handleRestore() } }
            }
            if footer.termsUrl != nil { separator(textColor) }
            if let terms = footer.termsUrl {
                linkButton("Terms", color: textColor) { open(terms) }
            }
            if footer.privacyUrl != nil { separator(textColor) }
            if let privacy = footer.privacyUrl {
                linkButton("Privacy", color: textColor) { open(privacy) }
            }
        }
        .padding(.top, 4)
    }

    private func linkButton(_ label: String, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label).font(.system(size: 11)).foregroundColor(color.opacity(0.55))
        }
    }

    private func separator(_ color: Color) -> some View {
        Text("·").font(.system(size: 11)).foregroundColor(color.opacity(0.4))
    }

    // MARK: Loading / error

    private var loadingView: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            ProgressView().tint(.white)
        }
    }

    private var errorView: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 12) {
                Text("Couldn’t load this offer.").foregroundColor(.white)
                Button("Close", action: dismiss).foregroundColor(.gray)
            }
        }
    }

    // MARK: Behaviour

    private func showCloseButton(_ doc: PaywallDocument) -> Bool {
        onDismiss != nil && doc.visibility?.closeButton != false
    }

    private func showFooterLinks(_ doc: PaywallDocument, isMultiPage: Bool, isLastPage: Bool) -> Bool {
        let allowed = doc.visibility?.footer != false
        return isMultiPage ? (isLastPage && allowed) : allowed
    }

    private func armSelection(_ doc: PaywallDocument) {
        if selectedTabId == nil, let tabs = doc.tabs, !tabs.tabs.isEmpty {
            selectedTabId = tabs.defaultTabId ?? tabs.tabs.first?.id
        }
        guard selectedProductId == nil else { return }
        // A free-trial toggle (when present) owns the initial selection — it sets the bound id on
        // appear from its own default. Otherwise pre-select the highlighted (or first) product.
        if doc.trialToggle != nil { return }
        let def = doc.products.first(where: { $0.highlight == true }) ?? doc.products.first
        selectedProductId = def?.identifier
    }

    private func handleCta(doc: PaywallDocument, isMultiPage: Bool, isLastPage: Bool, pageCount: Int, isExitOffer: Bool = false) {
        if isMultiPage && !isLastPage {
            withAnimation { currentPage = min(currentPage + 1, pageCount - 1) }
            appeared = false
            DispatchQueue.main.async { withAnimation(.easeOut(duration: 0.32)) { appeared = true } }
            return
        }
        guard let selectedId = selectedProductId,
              let product = doc.products.first(where: { $0.identifier == selectedId }) else { return }
        purchase(product, isExitOffer: isExitOffer)
    }

    /// Hand the product to the host and record what the purchase means for the exposures and the
    /// exit-offer flow. With `onPurchaseRequest` the outcome is awaited: only a completed purchase is
    /// recorded (the source's `purchased` with its experiment cell; for an exit offer the exit
    /// paywall's `purchased` and the source's `exit_offer_purchased`). A legacy `onPurchase` host
    /// cannot confirm, so a source purchase is recorded at the tap as before and an exit-offer
    /// purchase records nothing purchase-related.
    private func purchase(_ product: PaywallProduct, isExitOffer: Bool) {
        let fromExitOffer = isExitOffer && flow.showingExitOffer
        let exitOffer = fromExitOffer ? flow.activeExitOffer : nil
        let shownIdentifier = exitOffer.map { $0.paywall?.identifier ?? $0.paywallIdentifier } ?? identifier
        let offering = PaywallExitOfferLogic.purchaseOffering(fromExitOffer: exitOffer, sourceOffering: purchaseOfferingIdentifier)
        let source = currentResponse
        guard let onPurchaseRequest else {
            PaywallExposureRecorder.record(flow.purchaseHandedOff(
                fromExitOffer: fromExitOffer, source: source, fallbackIdentifier: identifier))
            onPurchase?(product)
            return
        }
        // The purchase latch: one reported purchase at a time, none after a confirmed one or after
        // the flow ended — checked before the host's billing handler is ever called.
        guard flow.beginPurchase() else { return }
        let request = PaywallPurchaseRequest(
            product: product, offeringIdentifier: offering,
            paywallIdentifier: shownIdentifier, fromExitOffer: fromExitOffer)
        model.busy = true
        Task { @MainActor in
            let outcome = await onPurchaseRequest(request)
            model.busy = false
            PaywallExposureRecorder.record(flow.purchaseFinished(
                outcome, fromExitOffer: fromExitOffer, source: source, fallbackIdentifier: identifier))
            // A close made while the purchase was pending: dropped when it sold, run now otherwise.
            let now = Date()
            let current = currentResponse
            if case .close(let action, let dismissHost) = flow.settleHeldClose(
                after: outcome, source: current, fallbackIdentifier: identifier,
                eligible: exitOfferEligible(current, now: now)) {
                apply(action, source: current, now: now, dismissHost: dismissHost)
            }
        }
    }

    /// Restore; a successful restore on the source paywall disarms its exit offer.
    @MainActor
    private func handleRestore() async {
        model.busy = true
        defer { model.busy = false }
        if (try? await Purchases.shared.restore()) != nil {
            flow.restoreSucceeded()
        }
    }

    /// The source paywall's `viewed` (see `PaywallViewRecording`: a placement presentation's view
    /// was recorded by the evaluation and is only re-sent, folded into it, to carry an A/B cell).
    private func recordViewed(_ experiment: PaywallExperimentAssignment?) {
        guard let identifier,
              let event = PaywallViewRecording.sourceViewEvent(
                identifier: identifier, experiment: experiment, presentation: placementPresentation)
        else { return }
        PaywallExposureRecorder.record([event])
    }

    /// A user close, run through the flow: on the source it records the dismissal and either
    /// dismisses or shows the exit offer in place; on the exit offer it ends the flow (its telemetry
    /// once). After the flow ended, further closes do nothing, so `onDismiss` fires once.
    private func dismiss() {
        let now = Date()
        let source = currentResponse
        let eligible = exitOfferEligible(source, now: now)
        // While a reported purchase is pending the flow holds the close (`.ignore`) and the purchase
        // settles it with its outcome.
        apply(flow.close(source: source, fallbackIdentifier: identifier, eligible: eligible),
              source: source, now: now, dismissHost: true)
    }

    /// Carries out a close decided by the flow. `dismissHost` is false for a close whose sheet is
    /// already gone (it is only recorded).
    private func apply(_ action: PaywallExitOfferFlow.CloseAction, source: PaywallResponse?, now: Date, dismissHost: Bool) {
        switch action {
        case .ignore:
            return
        case .dismiss(let events):
            PaywallExposureRecorder.record(events)
            if dismissHost { onDismiss?() }
        case .showExitOffer(let events):
            PaywallExposureRecorder.record(events)
            if let source { exitOfferHistory.recordPresentation(for: source.identifier, at: now) }
            // The exit paywall starts fresh: its own default selection, first page, entry animation.
            selectedProductId = nil
            selectedTabId = nil
            currentPage = 0
            appeared = false
            #if canImport(UIKit)
            // VoiceOver: the screen content was replaced, move focus to the new paywall.
            DispatchQueue.main.async { UIAccessibility.post(notification: .screenChanged, argument: nil) }
            #endif
        }
    }

    private func open(_ urlString: String) {
        #if canImport(UIKit)
        if let url = URL(string: urlString) { UIApplication.shared.open(url) }
        #endif
    }
}

// MARK: - Body

@available(iOS 15.0, macOS 12.0, *)
private struct PaywallBodyView: View {
    let document: PaywallDocument
    let theme: PaywallTheme
    @Binding var selectedProductId: String?
    @Binding var selectedTabId: String?
    let variables: [String: String]?
    let appeared: Bool

    private func t(_ s: String?) -> String? {
        guard let s else { return nil }
        return PaywallTransforms.interpolate(s, variables)
    }

    private var textColor: Color { Color.css(theme.textColor, fallback: .white) }
    private var primary: Color { Color.css(theme.primaryColor, fallback: .accentColor) }
    private var style: PaywallComponentStyle { PaywallComponentStyle(theme: theme, variables: variables) }

    /// Products after the active tier tab filters the set (no tabs → all products).
    private var visibleProducts: [PaywallProduct] {
        guard let tabs = document.tabs,
              let tabId = selectedTabId,
              let tab = tabs.tabs.first(where: { $0.id == tabId }),
              let ids = tab.productIds, !ids.isEmpty else { return document.products }
        let order = Dictionary(uniqueKeysWithValues: ids.enumerated().map { ($1, $0) })
        return document.products
            .filter { order[$0.identifier] != nil }
            .sorted { (order[$0.identifier] ?? 0) < (order[$1.identifier] ?? 0) }
    }

    var body: some View {
        let isMinimal = document.layout == .minimal
        let isHero = document.layout == .heroImage
        let isComparison = document.layout == .comparisonTable
        let horizontal = document.layout == .horizontalProducts
        let showFeatures = !isMinimal && !isComparison && document.visibility?.features != false
        let showProducts = document.visibility?.products != false
        let showSubtitle = document.visibility?.subtitle != false
        let leading = document.header.align == "left"
        let cardRadius = CGFloat(theme.cardBorderRadius ?? 20)

        VStack(alignment: leading ? .leading : .center, spacing: 0) {
            if isHero, let hero = document.header.heroImageUrl {
                RemoteImage(url: hero, contentMode: .fill)
                    .frame(height: CGFloat(document.header.heroImageHeight ?? 240))
                    .clipped()
                    .padding(.bottom, 16)
            }

            VStack(alignment: leading ? .leading : .center, spacing: 0) {
                if let urgency = document.urgency, document.visibility?.socialProof != false {
                    UrgencyBannerView(urgency: urgency, style: style)
                        .padding(.bottom, 20)
                }

                header(isHero: isHero, leading: leading, showSubtitle: showSubtitle)

                if showFeatures, !document.features.isEmpty {
                    featureList(leading: leading)
                        .padding(.top, 28)
                }

                if let timeline = document.timeline, !timeline.steps.isEmpty {
                    TimelineView(timeline: timeline, style: style)
                        .padding(.top, 28)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                if isComparison {
                    ComparisonTableView(
                        products: document.products,
                        features: document.features,
                        style: style,
                        cardRadius: cardRadius
                    )
                    .padding(.top, 28)
                } else if showProducts, !document.products.isEmpty {
                    if let tabs = document.tabs, tabs.tabs.count > 1 {
                        PaywallTabsView(tabs: tabs.tabs, style: style, selectedTabId: $selectedTabId)
                            .padding(.top, 28)
                    }

                    if let toggle = document.trialToggle {
                        FreeTrialToggleView(
                            config: toggle,
                            products: visibleProducts,
                            style: style,
                            cardRadius: cardRadius,
                            selectedProductId: $selectedProductId
                        )
                        .padding(.top, 16)
                    }

                    productList(horizontal: horizontal)
                        .padding(.top, document.trialToggle != nil ? 12 : 28)
                }
            }
            .padding(.horizontal, 24)
        }
        .opacity(appeared ? 1 : 0)
        .offset(y: appeared ? 0 : 16)
        .onChange(of: selectedTabId) { _ in
            // When switching tier, keep the selection inside the visible set: re-arm to the
            // highlighted (or first) product of the new tab if the current one is now hidden.
            let visible = visibleProducts
            if document.trialToggle == nil,
               !(selectedProductId.map { id in visible.contains { $0.identifier == id } } ?? false) {
                selectedProductId = (visible.first(where: { $0.highlight == true }) ?? visible.first)?.identifier
            }
        }
    }

    @ViewBuilder
    private func header(isHero: Bool, leading: Bool, showSubtitle: Bool) -> some View {
        let titleSize = CGFloat(theme.titleSize ?? (document.layout == .minimal ? 22 : 28))
        let subtitleSize = CGFloat(theme.subtitleSize ?? 14)

        VStack(alignment: leading ? .leading : .center, spacing: 8) {
            if !isHero, let logo = document.header.logoUrl {
                RemoteImage(url: logo, contentMode: .fit)
                    .frame(width: 56, height: 56)
                    .padding(.bottom, 4)
            }
            Text(t(document.header.title) ?? "")
                .font(themedFont(size: titleSize, weight: .heavy))
                .foregroundColor(textColor)
                .multilineTextAlignment(leading ? .leading : .center)
                .frame(maxWidth: .infinity, alignment: leading ? .leading : .center)

            if showSubtitle, let subtitle = t(document.header.subtitle) {
                Text(subtitle)
                    .font(themedFont(size: subtitleSize, weight: .regular))
                    .foregroundColor(textColor.opacity(0.7))
                    .multilineTextAlignment(leading ? .leading : .center)
                    .frame(maxWidth: .infinity, alignment: leading ? .leading : .center)
            }
        }
    }

    @ViewBuilder
    private func featureList(leading: Bool) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(Array(document.features.enumerated()), id: \.offset) { _, feature in
                HStack(spacing: 12) {
                    ZStack {
                        Circle().fill(primary.opacity(0.15)).frame(width: 30, height: 30)
                        Image(systemName: PaywallIcon.symbol(for: feature.icon))
                            .font(.system(size: 14, weight: .bold))
                            .foregroundColor(primary)
                    }
                    Text(t(feature.text) ?? "")
                        .font(themedFont(size: CGFloat(theme.bodySize ?? 15), weight: .regular))
                        .foregroundColor(textColor)
                    Spacer(minLength: 0)
                }
            }
        }
    }

    @ViewBuilder
    private func productList(horizontal: Bool) -> some View {
        let cardRadius = CGFloat(theme.cardBorderRadius ?? 20)
        if horizontal {
            HStack(spacing: 8) {
                ForEach(visibleProducts, id: \.identifier) { product in
                    productCard(product, radius: cardRadius, compact: true)
                }
            }
        } else {
            VStack(spacing: 8) {
                ForEach(visibleProducts, id: \.identifier) { product in
                    productCard(product, radius: cardRadius, compact: false)
                }
            }
        }
    }

    @ViewBuilder
    private func productCard(_ product: PaywallProduct, radius: CGFloat, compact: Bool) -> some View {
        let selected = selectedProductId == product.identifier
        let cardBg = Color.css(theme.cardBackground, fallback: Color(white: 0.09))
        let bg = selected ? primary.opacity(0.12) : cardBg
        let border = selected ? primary : Color.clear

        Button {
            selectedProductId = product.identifier
        } label: {
            VStack(alignment: compact ? .center : .leading, spacing: 2) {
                if let badge = t(product.badge) {
                    Text(badge.uppercased())
                        .font(.system(size: 9, weight: .black))
                        .foregroundColor(Color.css(theme.ctaTextColor, fallback: .white))
                        .padding(.horizontal, 8).padding(.vertical, 2)
                        .background(primary)
                        .clipShape(Capsule())
                        .padding(.bottom, 4)
                }
                Text(t(product.label) ?? "")
                    .font(themedFont(size: compact ? 13 : 16, weight: .bold))
                    .foregroundColor(textColor)
                    .multilineTextAlignment(compact ? .center : .leading)
                if let sub = t(product.sublabel) {
                    Text(sub)
                        .font(themedFont(size: compact ? 11 : 13, weight: .regular))
                        .foregroundColor(textColor.opacity(0.6))
                        .multilineTextAlignment(compact ? .center : .leading)
                }
                if let trial = product.trialDays, trial > 0 {
                    Text("\(trial)-day free trial")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(primary)
                        .padding(.top, 2)
                }
            }
            .frame(maxWidth: .infinity, alignment: compact ? .center : .leading)
            .padding(compact ? 14 : 16)
            .background(bg)
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).stroke(border, lineWidth: 1.5))
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private func themedFont(size: CGFloat, weight: Font.Weight) -> Font {
        if let family = theme.fontFamily, !family.isEmpty {
            return .custom(family, size: size)
        }
        return .system(size: size, weight: weight)
    }
}

// MARK: - Fetch model

@available(iOS 15.0, macOS 12.0, *)
@MainActor
private final class PaywallModel: ObservableObject {
    @Published var response: PaywallResponse?
    @Published var error: Error?
    @Published var busy = false

    /// Synchronous instant-present seed: render the cached copy immediately, no await. A miss leaves
    /// `response` nil so the loading view shows until `loadOrRevalidate` fills it.
    func seedFromCache(identifier: String) {
        guard response == nil else { return }
        if let cached = Purchases.shared.cachedPaywall(identifier) {
            response = cached
        }
    }

    /// Stale-while-revalidate load. Uses the SDK's cached present path: a fresh/stale cache entry is
    /// applied instantly and revalidated in the background; a miss does a live fetch. Only surfaces an
    /// error when there is nothing at all to show (no cache AND the network failed), so a flaky
    /// network never replaces a perfectly good cached paywall with an error screen.
    func loadOrRevalidate(identifier: String) async {
        let result = await Purchases.shared.getPaywallCached(identifier)
        switch result.source {
        case .freshCache, .staleCache, .network:
            if let r = result.response {
                response = r
                error = nil
            } else {
                markUnavailable()
            }
        case .unavailable:
            // Keep any cached copy we already seeded; only error when truly empty.
            if response == nil { markUnavailable() }
        }
    }

    private func markUnavailable() {
        if response == nil {
            error = PurchasesError("Paywall not available", code: .validationError, statusCode: 404)
        }
    }
}
#endif
