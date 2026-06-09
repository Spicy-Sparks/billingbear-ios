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

    public var body: some View {
        Group {
            if let tree = initialTree {
                treeContent(tree)
            } else if let response = model.response ?? initialResponse {
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
            if let identifier {
                Task { await Purchases.shared.recordExposure(identifier: identifier, outcome: .purchased) }
            }
            onPurchase?(product)
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
    private func content(for base: PaywallDocument, experiment: PaywallExperimentAssignment?) -> some View {
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

                footer(doc: doc, theme: theme, isMultiPage: isMultiPage, isLastPage: isLastPage, pageCount: pages.count)
            }

            if showCloseButton(doc) {
                Button(action: dismiss) {
                    Image(systemName: "xmark")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(Color.css(theme.textColor, fallback: .white).opacity(0.7))
                        .padding(10)
                }
                .padding(.top, 8)
                .padding(.trailing, 8)
                .accessibilityLabel("Close")
            }
        }
        .onAppear {
            armSelection(doc)
            withAnimation(.easeOut(duration: 0.32)) { appeared = true }
            recordViewed(experiment)
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
        pageCount: Int
    ) -> some View {
        let primary = Color.css(theme.primaryColor, fallback: .accentColor)
        let ctaTextColor = Color.css(theme.ctaTextColor, fallback: .white)
        let textColor = Color.css(theme.textColor, fallback: .white)
        let shape = doc.cta.shape ?? "rounded"
        let radius: CGFloat = shape == "pill" ? 999 : shape == "square" ? 4 : CGFloat(theme.buttonBorderRadius ?? 18)
        let ctaDisabled = isLastPage && selectedProductId == nil

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

            Button(action: { handleCta(doc: doc, isMultiPage: isMultiPage, isLastPage: isLastPage, pageCount: pageCount) }) {
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

    private func handleCta(doc: PaywallDocument, isMultiPage: Bool, isLastPage: Bool, pageCount: Int) {
        if isMultiPage && !isLastPage {
            withAnimation { currentPage = min(currentPage + 1, pageCount - 1) }
            appeared = false
            DispatchQueue.main.async { withAnimation(.easeOut(duration: 0.32)) { appeared = true } }
            return
        }
        guard let selectedId = selectedProductId,
              let product = doc.products.first(where: { $0.identifier == selectedId }) else { return }
        if let identifier {
            Task { await Purchases.shared.recordExposure(identifier: identifier, outcome: .purchased) }
        }
        onPurchase?(product)
    }

    @MainActor
    private func handleRestore() async {
        model.busy = true
        defer { model.busy = false }
        _ = try? await Purchases.shared.restore()
    }

    private func recordViewed(_ experiment: PaywallExperimentAssignment?) {
        guard let identifier else { return }
        Task {
            await Purchases.shared.recordExposure(
                identifier: identifier,
                outcome: .viewed,
                experimentId: experiment?.id,
                variant: experiment?.variant
            )
        }
    }

    private func dismiss() {
        if let identifier {
            Task { await Purchases.shared.recordExposure(identifier: identifier, outcome: .dismissed) }
        }
        onDismiss?()
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
